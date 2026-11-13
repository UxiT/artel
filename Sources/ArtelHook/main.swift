// artel-hook: Claude Code hook handler for sessions started by Artel.
//
// Reads the hook JSON from stdin, reduces it to a HookEvent, appends it to the session's
// event log and pings the app over its unix socket. Always exits 0 and prints nothing,
// so it can never block or alter the agent.
import ArtelCore
import Foundation

// Sessions started by Aide (Artel's old name) carry AIDE_* variables and may end up calling this binary.
func value(_ key: String, legacy: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return (env[key] ?? env[legacy]).flatMap { $0.isEmpty ? nil : $0 }
}
guard let sessionID = value(ArtelEnv.sessionID, legacy: LegacyAide.sessionIDEnv) else { exit(0) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = HookEvent.fromRawHookInput(input, artelSessionID: sessionID) else { exit(0) }

let eventsDir = value(ArtelEnv.eventsDir, legacy: LegacyAide.eventsDirEnv).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.eventsDir
try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
try? EventLog.append(event, dir: eventsDir)

if let payload = try? JSONEncoder.artel.encode(event) {
    // The session's env may carry a socket path from an older app run; fall back to the current default.
    let candidates = [value(ArtelEnv.socket, legacy: LegacyAide.socketEnv), AppPaths.socket.path].compactMap { $0 }
    for path in candidates where HookSocket.send(payload, to: path) { break }
}
exit(0)
