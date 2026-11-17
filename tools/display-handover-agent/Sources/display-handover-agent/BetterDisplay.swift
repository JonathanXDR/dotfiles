import AppKit
import DisplayHandoverAgentCore

/// BetterDisplay's CLI gives up after about 15 s, so the 20 s timeouts here let it report its own outcome
struct BetterDisplay {
    static let executable = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    static let bundleIdentifier = "pro.betterdisplay.BetterDisplay"

    let uuid: String
    private var selector: String { "-UUID=\(uuid)" }

    /// The LaunchServices lookup can briefly find nothing when another app launches, quits or comes to
    /// the front (4 misses in 6 minutes, measured), so the agent keeps using the pid it last found while
    /// that process exists
    @MainActor private static var knownPID: pid_t?

    @MainActor static var isRunning: Bool {
        if let pid = knownPID, kill(pid, 0) == 0 { return true }
        // An app without a pid reports -1, and kill(-1, 0) succeeds for any process the agent may signal
        knownPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier > 0 }?.processIdentifier
        return knownPID != nil
    }

    func readInput() async -> (input: MonitorInput?, reading: String) {
        guard let result = await Shell.run(Self.executable, ["get", selector, "-ddc", "-vcp=inputSelect"], timeout: 20),
              result.status == 0, let raw = Int(result.output)
        else { return (nil, "read failed") }
        let input = MonitorInput(vcp60: raw)
        return (input, "\(input?.description ?? "unrecognized") (\(raw))")
    }

    /// Writes VCP 0x60 = 0x11 (HDMI 1), the only DDC write this tool sends. A DDC power-off would also
    /// switch off the monitor's USB hub, which carries the audio interface.
    func switchToHDMI() async -> Bool {
        await succeeds(["set", selector, "-ddc", "-vcp=inputSelect", "-value=17"])
    }

    func setConnected(_ connected: Bool) async -> Bool {
        await succeeds(["set", selector, "-connected=" + (connected ? "on" : "off")])
    }

    func makeMain() async -> Bool {
        await succeeds(["set", selector, "-main=on"])
    }

    /// Reconnects every display BetterDisplay knows, including ones it no longer lists
    static func connectAllDisplays() async -> Bool {
        await Shell.run(executable, ["perform", "-connectAllDisplays"], timeout: 20)?.status == 0
    }

    private func succeeds(_ arguments: [String]) async -> Bool {
        await Shell.run(Self.executable, arguments, timeout: 20)?.status == 0
    }
}
