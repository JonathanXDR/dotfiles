import DisplayHandoverAgentCore
import Foundation

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/display-handover-agent", directoryHint: .isDirectory)
    static let config = support.appending(path: "config.json")
    static let state = support.appending(path: "state.json")
    static let control = support.appending(path: "control.json")
    static let lock = support.appending(path: "agent.lock")
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
}

/// Read only, because chezmoi renders the file from iCloud Drive
struct Config: Decodable {
    struct Display: Decodable {
        var name: String
        /// UUID that macOS and BetterDisplay use for the display (`betterdisplaycli get -identifiers`)
        var uuid: String
    }

    struct SyncBox: Decodable {
        var uniqueId: String
        var ipAddress: String
    }

    var primary: Display
    var syncBox: SyncBox
    /// Seconds without a confirmed active source before the agent reconnects the display anyway.
    /// Absent means 120. 0 disables it.
    var unknownReconnectAfter: Double?
    /// Absent means true
    var switchToHDMI: Bool?

    static func load() throws -> Config {
        var config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: Paths.config))
        config.syncBox.ipAddress = config.syncBox.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: config.primary.uuid) != nil else {
            throw ConfigError(description: "primary.uuid \"\(config.primary.uuid)\" is not a UUID")
        }
        guard config.syncBox.uniqueId.range(of: "^[0-9A-F]{12}$", options: .regularExpression) != nil else {
            throw ConfigError(description: "syncBox.uniqueId \"\(config.syncBox.uniqueId)\" is not a 12-digit hex ID")
        }
        var address = in_addr()
        guard inet_pton(AF_INET, config.syncBox.ipAddress, &address) == 1 else {
            throw ConfigError(description: "syncBox.ipAddress \"\(config.syncBox.ipAddress)\" is not an IPv4 address")
        }
        return config
    }

    var policySettings: PolicySettings {
        var settings = PolicySettings()
        if let seconds = unknownReconnectAfter { settings.unknownReconnectAfter = seconds > 0 ? seconds : nil }
        if let switchToHDMI { settings.switchToHDMI = switchToHDMI }
        return settings
    }
}

struct Control: Codable {
    var paused = false
    var pausedUntil: Double?
    var reconnectRequest: Double?
    var resetRequest: Double?
    var tokenReloadRequest: Double?

    static func load() -> Control {
        (try? JSONDecoder().decode(Control.self, from: Data(contentsOf: Paths.control))) ?? Control()
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Paths.control, options: .atomic)
    }

    func isPaused(at now: Double) -> Bool {
        guard paused else { return false }
        return pausedUntil.map { now < $0 } ?? true
    }
}

struct AgentState: Codable {
    var policy = PolicyState()
    var primaryWasMain = false
    var handledReconnectRequest: Double?
    var manualReconnectSucceeded: Bool?
    var handledResetRequest: Double?

    var updated: Double?
    var source: String?
    var syncBox: String?
    var primaryOnline: Bool?
    var lastInput: String?
    var activity: String?

    static func load() throws -> AgentState {
        guard FileManager.default.fileExists(atPath: Paths.state.path) else { return AgentState() }
        return try JSONDecoder().decode(AgentState.self, from: Data(contentsOf: Paths.state))
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.state, options: .atomic)
    }

    /// The part the agent must save as soon as it changes
    struct Durable: Equatable {
        var policy: PolicyState
        var primaryWasMain: Bool
        var handledReconnectRequest: Double?
        var manualReconnectSucceeded: Bool?
        var handledResetRequest: Double?
    }

    var durable: Durable {
        Durable(
            policy: policy, primaryWasMain: primaryWasMain, handledReconnectRequest: handledReconnectRequest,
            manualReconnectSucceeded: manualReconnectSucceeded, handledResetRequest: handledResetRequest)
    }
}
