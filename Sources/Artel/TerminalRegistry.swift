import ArtelCore
import AppKit
import SwiftTerm
import SwiftUI

/// Terminal view attached (as a tmux client) to one session.
final class SessionTerminalView: LocalProcessTerminalView {
    let sessionID: String
    var onFocus: (() -> Void)?

    init(sessionID: String) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        font = AppFonts.shared.settings.terminal.nsFont(monospaced: true)
        optionAsMetaKey = true
        nativeBackgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        // Drops over a session card are tasks for the card, not text for the terminal.
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicking into the terminal makes its session the focused one (becomeFirstResponder isn't overridable).
    func installFocusTracking() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    @objc private func clicked() { onFocus?() }

    /// Shift+Return inserts a line break in the agent's prompt instead of submitting it.
    /// SwiftTerm sends a plain CR for it; both Claude Code and Kimi Code treat Ctrl+J (LF) as "newline".
    /// `keyDown` isn't overridable outside SwiftTerm, so this is called from a local key monitor.
    func handleShiftReturn(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 36 || event.keyCode == 76, mods == .shift else { return false }
        send(txt: "\n")
        return true
    }
}

/// Keeps one terminal view per session alive across SwiftUI re-renders (grid ↔ expanded, tab switches),
/// so the tmux client isn't restarted every time the layout changes.
@MainActor
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    weak var model: AppModel?
    private var views: [String: SessionTerminalView] = [:]
    private var keyMonitor: Any?

    override init() {
        super.init()
        // Local monitors run on the main thread; the closure inherits the main-actor isolation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let tv = event.window?.firstResponder as? SessionTerminalView,
                  tv.handleShiftReturn(event) else { return event }
            return nil
        }
    }

    /// Applies the terminal font setting to every live terminal.
    func applyFont() {
        let font = AppFonts.shared.settings.terminal.nsFont(monospaced: true)
        for v in views.values where v.font != font { v.font = font }
    }

    func view(for record: SessionRecord, tmux: Tmux, environment: [String: String]) -> SessionTerminalView {
        if let v = views[record.id] { return v }
        let v = SessionTerminalView(sessionID: record.id)
        v.processDelegate = self
        v.onFocus = { [weak self] in self?.model?.focusedSessionID = record.id }
        v.installFocusTracking()
        var env = environment
        env["TERM"] = "xterm-256color"
        v.startProcess(executable: tmux.executable, args: tmux.attachArgs(record.tmuxName),
                       environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: record.cwd)
        views[record.id] = v
        return v
    }

    func existing(_ id: String) -> SessionTerminalView? { views[id] }

    /// Drops the view and its tmux client (the agent keeps running in tmux).
    func discard(_ id: String) {
        guard let v = views.removeValue(forKey: id) else { return }
        v.processDelegate = nil
        v.terminate()
        v.removeFromSuperview()
    }

    func focus(_ id: String) {
        guard let v = views[id], let window = v.window else { return }
        window.makeFirstResponder(v)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let id = (source as? SessionTerminalView)?.sessionID else { return }
        Task { @MainActor in
            guard let v = self.views[id], v === source else { return }
            self.views.removeValue(forKey: id)
            self.model?.attachEnded(id)
        }
    }
}

/// Hosts a session's persistent terminal view inside SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let record: SessionRecord
    /// Changes when the terminal must be recreated; makes SwiftUI call `updateNSView`.
    let epoch: Int
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tmux = model.tmuxForTerminals else { return }
        let tv = model.terminals.view(for: record, tmux: tmux, environment: model.loginEnvironment)
        if tv.superview !== container {
            tv.removeFromSuperview()
            tv.frame = container.bounds
            tv.autoresizingMask = [.width, .height]
            container.addSubview(tv)
            if model.focusedSessionID == record.id {
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Detach only; the registry keeps the view for the next container.
        for sub in container.subviews { sub.removeFromSuperview() }
    }
}

/// A plain shell command in a terminal (installers).
struct CommandTerminal: NSViewRepresentable {
    let command: String
    let environment: [String: String]
    let onExit: (Int32?) -> Void

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let cb = onExit
            DispatchQueue.main.async { cb(exitCode) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        v.font = AppFonts.shared.settings.terminal.nsFont(monospaced: true)
        v.processDelegate = context.coordinator
        var env = environment
        env["TERM"] = "xterm-256color"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        v.startProcess(executable: shell, args: ["-l", "-c", command], environment: env.map { "\($0.key)=\($0.value)" })
        return v
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
