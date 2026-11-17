import DisplayHandoverAgentCore
import Foundation

let usage = """
    Usage: display-handover-agent <command>

      status            Show the agent state and the current readings
      pause [minutes]   Stop the switch to HDMI and automatic disconnects (until resume, or for the given minutes).
                        A display the agent disconnected is still reconnected.
      resume            Resume, and clear the circuit breaker, a manual override and the reconnect backoff
      reconnect         Reconnect the primary display now and keep it until the HDMI source turns off
      monitor           Print readings as they change, without acting (diagnostics)
      register          Register with the Hue Sync Box (needs a press of its button)
      run               Run the agent (started by the LaunchAgent)
    """

func fail(_ message: String) -> Int32 {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    return 1
}

func clock(_ seconds: Double) -> String {
    Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .standard)
}

func updateControl(_ change: (inout Control) -> Void) -> Bool {
    var control = Control.load()
    change(&control)
    return (try? control.save()) != nil
}

@MainActor
func execute(_ arguments: [String]) async -> Int32 {
    let command = arguments.first ?? "help"
    if command == "help" || command == "--help" {
        print(usage)
        return 0
    }
    if ["pause", "resume"].contains(command) {
        let argument = command == "pause" ? arguments.dropFirst().first : nil
        let minutes = argument.flatMap { Int($0) }
        if let argument, (minutes ?? 0) < 1 {
            return fail("pause takes a whole number of minutes, 1 or more, not \"\(argument)\".")
        }
        let saved = updateControl {
            $0.paused = command == "pause"
            $0.pausedUntil = minutes.map { Date().timeIntervalSince1970 + Double($0) * 60 }
            if command == "resume" { $0.resetRequest = Date().timeIntervalSince1970 }
        }
        guard saved else { return fail("Cannot write \(Paths.control.path).") }
        print(command == "resume" ? "Resumed." : minutes.map { "Paused for \($0) minutes." } ?? "Paused until `display-handover-agent resume`.")
        return 0
    }

    let config: Config
    do {
        config = try Config.load()
    } catch {
        return fail("Cannot use \(Paths.config.path): \(error)")
    }

    switch command {
    case "run":
        guard AgentLock.acquire() else { return fail("Another agent is already running.") }
        await Agent(config: config).run()
        return 0
    case "monitor":
        await Monitor(config: config).run()
        return 0
    case "status":
        await printStatus(config)
        return 0
    case "reconnect":
        return await requestReconnect(config)
    case "register":
        return await register(config)
    default:
        return fail(usage)
    }
}

@MainActor
func printStatus(_ config: Config) async {
    let state = (try? AgentState.load()) ?? AgentState()
    let control = Control.load()
    let now = Date().timeIntervalSince1970
    let running = AgentLock.isHeld
    var mode = "automatic"
    if control.isPaused(at: now) { mode = control.pausedUntil.map { "switching and disconnects paused until \(clock($0))" } ?? "switching and disconnects paused until resume" }
    if let until = state.policy.breakerUntil, until > now { mode = "circuit breaker open until \(clock(until))" }
    let displays = DisplaySnapshot.current(primaryUUID: config.primary.uuid)
    print("Agent:            \(running ? "running" : "not running"), \(mode)")
    print("Displays:         \(displays.summary)")
    let owned = !displays.primaryOnline && state.policy.ownsDisconnect
    print("Primary:          \(config.primary.name) \(displays.primaryOnline ? "online" : "offline")"
        + (owned ? ", disconnected by the agent" : "")
        + (owned && !running ? ", which is not running (display-handover-agent reconnect brings it back)" : "")
        + (state.policy.manualOverride ? ", manual override until the HDMI source turns off" : ""))
    if running, let updated = state.updated {
        // While the agent runs, show its own readings instead of sending DDC commands beside it
        let age = "\(Int(now - updated)) s ago"
        print("Agent sees:       source \(state.source ?? "?"), \(state.syncBox ?? "no Sync Box reading") (\(age))")
        print("Monitor input:    \(state.lastInput ?? "not read yet") (last DDC read by the agent)")
        print("Last activity:    \(state.activity ?? "none")")
    }
    let client = SyncBoxClient(uniqueId: config.syncBox.uniqueId, ipAddress: config.syncBox.ipAddress)
    if let token = await Keychain.token(account: client.keychainAccount) {
        do {
            let status = try await client.status(token: token)
            print("Sync Box now:     \(status.signal.rawValue), \(status.summary) (checked from this terminal)")
        } catch {
            print("Sync Box now:     unknown, \(error) (checked from this terminal)")
        }
    } else {
        print("Sync Box now:     unknown, \(SyncBoxError.noToken)")
    }
    if !running {
        if displays.primaryOnline, BetterDisplay.isRunning {
            let (_, reading) = await BetterDisplay(uuid: config.primary.uuid).readInput()
            print("Monitor input:    \(reading)")
        } else {
            print("Monitor input:    not readable while the primary display is offline")
        }
    }
}

@MainActor
func requestReconnect(_ config: Config) async -> Int32 {
    guard AgentLock.isHeld else {
        let done = await BetterDisplay(uuid: config.primary.uuid).setConnected(true)
        guard done else { return fail("Reconnect failed. Use BetterDisplay > Tools > Displays And Virtual Screens > Connect All Displays.") }
        print("Reconnected \(config.primary.name). The agent is not running.")
        return 0
    }
    let request = Date().timeIntervalSince1970
    guard updateControl({ $0.reconnectRequest = request }) else { return fail("Cannot write \(Paths.control.path).") }
    print("Asked the agent to reconnect \(config.primary.name)...")
    let deadline = Date().addingTimeInterval(75)
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(500))
        let state = (try? AgentState.load()) ?? AgentState()
        guard state.handledReconnectRequest == request, let done = state.manualReconnectSucceeded else { continue }
        if done {
            print("Done. It stays connected until the HDMI source turns off.")
            return 0
        }
        let retry = state.policy.ownsDisconnect ? "The agent retries when the HDMI source turns off. " : ""
        return fail("The reconnect failed. \(retry)"
            + "Use BetterDisplay > Tools > Displays And Virtual Screens > Connect All Displays to bring it back now.")
    }
    return fail("The agent did not answer within 75 s. Check ~/Library/Logs/display-handover-agent.log.")
}

@MainActor
func register(_ config: Config) async -> Int32 {
    let client = SyncBoxClient(uniqueId: config.syncBox.uniqueId, ipAddress: config.syncBox.ipAddress)
    print("Press and hold the button on the Sync Box until its light blinks green (about 3 seconds).")
    let deadline = Date().addingTimeInterval(120)
    var lastError = ""
    while Date() < deadline {
        do {
            let instance = Host.current().localizedName ?? "Mac"
            if let registration = try await client.register(appName: "display-handover-agent", instanceName: instance) {
                guard await Keychain.store(token: registration.token, account: client.keychainAccount) else {
                    return fail("Registered, but the token could not be stored in the keychain.")
                }
                _ = updateControl { $0.tokenReloadRequest = Date().timeIntervalSince1970 }
                print("Registered (registration \(registration.id)). The token is in the login keychain.")
                return 0
            }
        } catch {
            if error.description != lastError { print("Sync Box: \(error)") }
            lastError = error.description
        }
        try? await Task.sleep(for: .seconds(1))
    }
    return fail("No button press within 2 minutes.")
}

setvbuf(stdout, nil, _IOLBF, 0)
try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
let arguments = Array(CommandLine.arguments.dropFirst())
Task { @MainActor in exit(await execute(arguments)) }
// IOKit power notifications and distributed notifications arrive through the main run loop
RunLoop.main.run()
