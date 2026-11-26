import ArtelCore
import AppKit
import Observation

/// Polls subscription limits using the coding agents' existing logins (read-only).
@MainActor
@Observable
final class UsageMonitor {
    enum Status: Equatable {
        case idle
        case loading
        case ok
        case noCredentials
        case needsLogin
        case error(String)
    }

    struct ProviderState: Equatable {
        let id: String
        let title: String
        let compactTitle: String
        let systemImage: String
        var windows: [LimitWindow] = []
        var plan: String?
        var status = Status.idle
        var updatedAt: Date?

        /// The windows shown in the compact status-bar segment.
        var headline: [LimitWindow] {
            windows.filter { $0.id == "session" || $0.id == "weekly" }
        }
    }

    static let agentIDs = [ClaudeCodeAgent.id, KimiCodeAgent.id]

    private(set) var states: [String: ProviderState] = [
        ClaudeCodeAgent.id: ProviderState(id: ClaudeCodeAgent.id, title: "Claude", compactTitle: "Claude",
                                          systemImage: "sparkles"),
        KimiCodeAgent.id: ProviderState(id: KimiCodeAgent.id, title: "Kimi", compactTitle: "Kimi",
                                        systemImage: "moon.stars"),
    ]

    var settings = LimitSettings()
    /// Agents enabled in the app settings; limits of disabled agents are neither fetched nor shown.
    var enabledAgents: Set<String> = Set(UsageMonitor.agentIDs)
    var environment: [String: String] = [:]
    var onAlert: ((String, LimitWindow) -> Void)?

    private var loops: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    private var retryAfter: [String: TimeInterval] = [:]
    private var claudeCredentials: ClaudeCredentials?
    private var kimiCredentials: KimiCredentials?
    private var kimiConfiguration: KimiConfiguration?
    private var planFetchedAt: Date?
    private var alerted: Set<String> = []
    /// Missing logins are retried only by an explicit refresh or when the agent is shown again.
    private var credentialsUnavailable: Set<String> = []

    /// Agents whose limits can be shown at all (enabled in the app settings).
    var availableAgentIDs: [String] { Self.agentIDs.filter { enabledAgents.contains($0) } }

    func isShown(_ agentID: String) -> Bool {
        enabledAgents.contains(agentID) && settings.shows(agentID)
    }

    var visibleStates: [ProviderState] {
        Self.agentIDs.filter(isShown).compactMap { states[$0] }
    }

    func state(for agentID: String) -> ProviderState {
        states[agentID] ?? ProviderState(id: agentID, title: agentID, compactTitle: agentID, systemImage: "gauge")
    }

    func start() {
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
        for id in Self.agentIDs {
            guard settings.enabled, isShown(id) else {
                states[id]?.status = .idle
                if !settings.enabled {
                    states[id]?.windows = []
                    states[id]?.plan = nil
                    states[id]?.updatedAt = nil
                }
                continue
            }
            credentialsUnavailable.remove(id)
            loops[id] = Task { [weak self] in
                guard let self else { return }
                await self.poll(id)
            }
        }
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops.removeAll()
    }

    func refreshNow() {
        for id in Self.agentIDs where settings.enabled && isShown(id) {
            credentialsUnavailable.remove(id)
            Task { await refresh(id) }
        }
    }

    private func poll(_ agentID: String) async {
        while !Task.isCancelled {
            await refresh(agentID)
            let failures = failures[agentID] ?? 0
            let wait = failures > 0
                ? Backoff.delay(failures: failures, retryAfter: retryAfter[agentID])
                : TimeInterval(max(1, settings.intervalMinutes) * 60)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func refresh(_ agentID: String) async {
        guard settings.enabled, isShown(agentID) else { return }
        if credentialsUnavailable.contains(agentID),
           (agentID == ClaudeCodeAgent.id ? claudeCredentials == nil : kimiCredentials == nil) { return }
        if state(for: agentID).status != .ok { states[agentID]?.status = .loading }
        switch agentID {
        case KimiCodeAgent.id:
            await refreshKimi()
        default:
            await refreshClaude()
        }
    }

    private func refreshClaude() async {
        let id = ClaudeCodeAgent.id
        if claudeCredentials == nil { claudeCredentials = await readClaudeCredentials() }
        guard var creds = claudeCredentials else {
            states[id]?.status = .noCredentials
            credentialsUnavailable.insert(id)
            return
        }
        var result = await fetch(ClaudeUsage.request(ClaudeUsage.usageURL, token: creds.accessToken))
        if case .unauthorized = result {
            // Claude Code may have refreshed its token since we read it.
            if let fresh = await readClaudeCredentials(), fresh.accessToken != creds.accessToken {
                creds = fresh
                claudeCredentials = fresh
                result = await fetch(ClaudeUsage.request(ClaudeUsage.usageURL, token: creds.accessToken))
            }
        }
        switch result {
        case .ok(let data):
            do {
                states[id]?.windows = try ClaudeUsage.parseUsage(data)
                recordSuccess(id)
                if planFetchedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                    planFetchedAt = Date()
                    if case .ok(let p) = await fetch(ClaudeUsage.request(ClaudeUsage.profileURL, token: creds.accessToken)) {
                        states[id]?.plan = ClaudeUsage.parsePlan(p) ?? ClaudeUsage.planName(creds.subscriptionType)
                    } else {
                        states[id]?.plan = ClaudeUsage.planName(creds.subscriptionType)
                    }
                }
            } catch {
                recordFailure(id, message: "Unexpected response from the limits API", retryAfter: nil)
            }
        case .unauthorized:
            claudeCredentials = nil
            states[id]?.status = .needsLogin
            credentialsUnavailable.insert(id)
        case .failed(let message, let after):
            recordFailure(id, message: message, retryAfter: after)
        }
    }

    private func refreshKimi() async {
        let id = KimiCodeAgent.id
        if kimiCredentials == nil {
            let login = await readKimiCredentials()
            kimiCredentials = login?.0
            kimiConfiguration = login?.1
        }
        guard var creds = kimiCredentials, let configuration = kimiConfiguration else {
            states[id]?.status = .noCredentials
            credentialsUnavailable.insert(id)
            return
        }
        let url = KimiUsage.usageURL(baseURL: configuration.baseURL)
        var result = await fetch(KimiUsage.request(url, token: creds.accessToken))
        if case .unauthorized = result {
            if let fresh = await readKimiCredentials(), fresh.0.accessToken != creds.accessToken {
                creds = fresh.0
                kimiCredentials = fresh.0
                kimiConfiguration = fresh.1
                let freshURL = KimiUsage.usageURL(baseURL: fresh.1.baseURL)
                result = await fetch(KimiUsage.request(freshURL, token: creds.accessToken))
            }
        }
        switch result {
        case .ok(let data):
            do {
                states[id]?.windows = try KimiUsage.parseUsage(data)
                recordSuccess(id)
            } catch {
                recordFailure(id, message: "Unexpected response from the limits API", retryAfter: nil)
            }
        case .unauthorized:
            kimiCredentials = nil
            states[id]?.status = .needsLogin
            credentialsUnavailable.insert(id)
        case .failed(let message, let after):
            recordFailure(id, message: message, retryAfter: after)
        }
    }

    private func recordSuccess(_ agentID: String) {
        states[agentID]?.status = .ok
        states[agentID]?.updatedAt = Date()
        failures[agentID] = 0
        retryAfter[agentID] = nil
        checkAlerts(agentID)
    }

    private func recordFailure(_ agentID: String, message: String, retryAfter: TimeInterval?) {
        // Keep the last known numbers on screen.
        states[agentID]?.status = .error(message)
        failures[agentID] = (failures[agentID] ?? 0) + 1
        self.retryAfter[agentID] = retryAfter
    }

    private enum FetchResult {
        case ok(Data)
        case unauthorized
        case failed(String, retryAfter: TimeInterval?)
    }

    private func fetch(_ request: URLRequest) async -> FetchResult {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .ok(data)
            case 401, 403: return .unauthorized
            default:
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .failed(code == 429 ? "Too many requests (429)" : "HTTP \(code)", retryAfter: after)
            }
        } catch {
            return .failed("Network: \(error.localizedDescription)", retryAfter: nil)
        }
    }

    private func readClaudeCredentials() async -> ClaudeCredentials? {
        let env = environment
        return await Task.detached { ClaudeUsage.readCredentials(environment: env) }.value
    }

    private func readKimiCredentials() async -> (KimiCredentials, KimiConfiguration)? {
        let env = environment
        return await Task.detached { KimiUsage.readCredentials(environment: env) }.value
    }

    private func checkAlerts(_ agentID: String) {
        guard settings.alerts, isShown(agentID) else { return }
        let prefix = "\(agentID):"
        let ownAlerted = Set(alerted.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
        let windows = state(for: agentID).windows
        for w in LimitAlerts.due(windows, thresholdRemaining: Double(settings.thresholdRemaining), alreadyAlerted: ownAlerted) {
            alerted.insert(LimitAlerts.key(w, agentID: agentID))
            onAlert?(agentID, w)
        }
    }
}
