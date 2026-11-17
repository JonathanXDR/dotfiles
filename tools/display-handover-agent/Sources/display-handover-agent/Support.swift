import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.jonathan-russ.display-handover-agent", category: "agent")

    static func info(_ message: String) {
        write(message)
        // The unified log does not persist info-level messages
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        write("error: " + message)
        logger.error("\(message, privacy: .public)")
    }

    private static func write(_ message: String) {
        let style = Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day().dateSeparator(.dash).dateTimeSeparator(.space)
            .time(includingFractionalSeconds: false).timeSeparator(.colon)
        try? FileHandle.standardError.write(contentsOf: Data("\(Date().formatted(style)) \(message)\n".utf8))
    }
}

enum Keychain {
    private static let service = "com.jonathan-russ.display-handover-agent"
    // Passed explicitly because the dotfiles keychain comes first in the search list and is still locked at login
    private static let login = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Keychains/login.keychain-db").path

    static func token(account: String) async -> String? {
        // `/usr/bin/security` is on the item's access list, so a re-signed agent never triggers a keychain prompt
        guard let result = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w", login]),
              result.status == 0, !result.output.isEmpty
        else { return nil }
        return result.output
    }

    static func store(token: String, account: String) async -> Bool {
        // `security -i` runs every line it reads, so whitespace or quotes in a token would inject arguments or commands
        guard token.range(of: #"^[A-Za-z0-9+/=._-]{1,512}$"#, options: .regularExpression) != nil else { return false }
        let command = "add-generic-password -U -s \(service) -a \(account) -l display-handover-agent-syncbox -T /usr/bin/security -w \(token) \"\(login)\"\n"
        // Passing the token on standard input keeps it out of the process list
        _ = await Shell.run("/usr/bin/security", ["-i"], input: command)
        return await self.token(account: account) == token
    }
}

enum Notifier {
    static func post(_ message: String) async {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = await Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"Display handover agent\""], timeout: 5)
    }
}

enum AgentLock {
    /// Holds the lock until the process exits
    static func acquire() -> Bool {
        let descriptor = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    static var isHeld: Bool {
        let descriptor = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
}
