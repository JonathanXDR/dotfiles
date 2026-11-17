import DisplayHandoverAgentCore
import Foundation

/// Sends no DDC commands, so it can run beside the agent
@MainActor
final class Monitor {
    private let config: Config
    private let syncBox: SyncBoxClient
    private let power = PowerMonitor()
    private var last: [String: String] = [:]

    init(config: Config) {
        self.config = config
        syncBox = SyncBoxClient(uniqueId: config.syncBox.uniqueId, ipAddress: config.syncBox.ipAddress)
    }

    func run() async {
        power.start()
        for event in ["launched", "terminated"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("pro.betterdisplay.BetterDisplay.\(event)"), object: nil, queue: .main
            ) { _ in Log.info("BetterDisplay \(event)") }
        }
        let token = await Keychain.token(account: syncBox.keychainAccount)
        if token == nil { Log.error(SyncBoxError.noToken.description) }
        while true {
            show("displays", DisplaySnapshot.current(primaryUUID: config.primary.uuid).summary)
            if let token {
                do {
                    let status = try await syncBox.status(token: token)
                    show("syncbox", "\(status.signal.rawValue): \(status.summary)")
                } catch {
                    show("syncbox", "unreachable: \(error)")
                }
            }
            try? await Task.sleep(for: .seconds(2))  // The agent's poll rate, so the Sync Box sees the same load
        }
    }

    private func show(_ key: String, _ value: String) {
        guard last[key] != value else { return }
        last[key] = value
        Log.info("\(key): \(value)")
    }
}
