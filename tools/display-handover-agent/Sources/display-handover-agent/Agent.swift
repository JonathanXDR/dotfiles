import AppKit
import DisplayHandoverAgentCore
import Foundation

@MainActor
final class Agent {
    private static let interval: Duration = .seconds(2)
    /// Lets macOS and BetterDisplay restore the displays first (BetterDisplay's wake delay defaults to 1.5 s)
    private static let wakeSettle: Double = 10
    /// A DDC read during a display transaction can stall WindowServer
    private static let displaySettle: Double = 5
    /// BetterDisplay reconnects every display when it starts
    private static let launchSettle: Double = 8
    /// The U2725QE reports the new input within 3 s of the switch (measured)
    private static let inputSwitchSettle: Double = 3
    private static let keychainRetryDelays: [Double] = [60, 300, 900, 1800]

    private let config: Config
    private let betterDisplay: BetterDisplay
    private let syncBox: SyncBoxClient
    private let power = PowerMonitor()
    private var policy: Policy
    private var state: AgentState
    private var savedState: AgentState?
    private var lastSave: Double = 0
    private var quietUntil: Double = 0
    private var token: String?
    private var tokenFailures = 0
    private var tokenRetryAt: Double = 0
    private var handledTokenReloadRequest: Double?
    private var connectAllTriedAt: Double?
    private var betterDisplayWasRunning = true
    private var othersWereAsleep = false
    private var lastDisplayIDs: Set<CGDirectDisplayID>?
    /// A count, because the stop's reconnect can overlap an action still running after the 20 s wait
    private var actionsInFlight = 0 {
        didSet { power.holdsSleep = actionsInFlight > 0 }
    }
    private var stopping = false
    private var logged: [String: String] = [:]
    private var notifiedReconnectFailure = false
    private var notifiedDisconnectFailure = false
    private var notifiedSwitchFailure = false
    /// A DDC write gets no reply from the monitor, so the agent judges the switch by the first input
    /// reading after it, not by the exit status of the BetterDisplay command.
    private var switchCheck: (sentAt: Double, commandSucceeded: Bool)?
    private var notifiedRejectedToken = false
    private var loggedSaveFailure = false
    private var terminationSource: DispatchSourceSignal?
    private var termination: Task<Void, Never>?

    init(config: Config) {
        self.config = config
        betterDisplay = BetterDisplay(uuid: config.primary.uuid)
        syncBox = SyncBoxClient(uniqueId: config.syncBox.uniqueId, ipAddress: config.syncBox.ipAddress)
        do {
            state = try AgentState.load()
        } catch {
            state = AgentState()
            Log.error("could not read \(Paths.state.path), starting without it: \(error). The agent no longer "
                + "reconnects a display it disconnected earlier. Run display-handover-agent reconnect if one is off the desktop.")
        }
        policy = Policy(settings: config.policySettings, state: state.policy)
    }

    private var name: String { config.primary.name }
    private var now: Double { Date().timeIntervalSince1970 }
    private func displays() -> DisplaySnapshot { DisplaySnapshot.current(primaryUUID: config.primary.uuid) }

    func run() async {
        power.start()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("pro.betterdisplay.BetterDisplay.launched"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.settle(Self.launchSettle, because: "BetterDisplay started") }
        }
        installTerminationHandler()
        Log.info("started: primary \(name)" + (policy.state.ownsDisconnect ? ", primary disconnected by this agent" : ""))
        while !stopping {
            await tick()
            try? await Task.sleep(for: Self.interval)
        }
        // The caller exits the process on return, so the SIGTERM reconnect must finish first
        await termination?.value
    }

    private func tick() async {
        let control = Control.load()
        await handle(control)
        let paused = control.isPaused(at: now)
        note("paused", paused ? describePause(control) : "no")
        if let reason = skipReason() {
            state.activity = reason
            saveState()
            return
        }

        let (source, inputPlugged) = await readSource()
        if source == .inactive, switchCheck != nil {
            switchCheck = nil
            Log.info("source off before the switch to HDMI could be checked")
        }
        // After the Sync Box request, so the snapshot includes display changes during it
        let snapshot = displays()
        noteDisplayChanges(snapshot)
        let settling = isQuiet
        note("primary", snapshot.primaryOnline ? "online" : "offline")
        state.primaryOnline = snapshot.primaryOnline

        var observation = Observation(
            primaryOnline: snapshot.primaryOnline, otherDisplayOnline: snapshot.otherDisplayOnline,
            source: source, selectedInputPlugged: inputPlugged, disconnectAllowed: !paused && !settling)
        let breakerBefore = policy.state.breakerUntil
        var decision = policy.step(now: now, observation)
        if decision == .readInput, !stopping {
            let (input, reading) = await betterDisplay.readInput()
            state.lastInput = reading
            note("input", reading)
            observation.input = input.map(InputReading.value) ?? .failed
            decision = policy.step(now: now, observation)
            if let input { await checkSwitch(input) }
        }
        if let check = switchCheck, now - check.sentAt > 30 {
            switchCheck = nil
            Log.info("no input reading within 30 s after the switch to HDMI, not checked")
        }
        if let until = policy.state.breakerUntil, until != breakerBefore {
            let message = "Automatic switching and disconnects are paused until \(clock(until)) after \(policy.settings.breakerLimit) "
                + "takeovers (switches to HDMI or disconnects) within \(Int(policy.settings.breakerWindow / 60)) minutes. "
                + "Run display-handover-agent resume to re-enable them."
            Log.info(message)
            await Notifier.post(message)
        }
        await carryOut(decision, snapshot: snapshot)
        if settling, !paused, case .wait = decision { state.activity = "waiting for the displays to settle" }
        saveState()
    }

    private func skipReason() -> String? {
        if power.sleeping { return "system asleep" }
        if let wake = power.lastWake, now - wake.timeIntervalSince1970 < Self.wakeSettle { return "settling after wake" }
        let running = BetterDisplay.isRunning
        if running, !betterDisplayWasRunning { settle(Self.launchSettle, because: "BetterDisplay running again") }
        if !running, betterDisplayWasRunning { Log.info("BetterDisplay not running, waiting for it") }
        betterDisplayWasRunning = running
        if !running { return "BetterDisplay not running" }
        // DDC fails during display sleep, and nobody looks at the desktop then
        let othersAsleep = displays().othersAsleep
        if othersWereAsleep, !othersAsleep { settle(Self.displaySettle, because: "displays woke up") }
        othersWereAsleep = othersAsleep
        if othersAsleep { return "displays asleep" }
        return nil
    }

    private func readSource() async -> (signal: SourceSignal, selectedInputPlugged: Bool) {
        // Away from the desk the policy has nothing to decide, so the agent sends no request or address lookup for the box on other networks
        guard displays().primaryOnline || policy.state.ownsDisconnect || policy.state.pendingDisconnectAt != nil else {
            return (record(.unknown, "not polled while \(name) is offline"), false)
        }
        if token == nil, now >= tokenRetryAt {
            token = await Keychain.token(account: syncBox.keychainAccount)
            if token == nil {
                tokenFailures += 1
                tokenRetryAt = now + Self.keychainRetryDelays[min(tokenFailures, Self.keychainRetryDelays.count) - 1]
                if tokenFailures == 1 { Log.error("no Sync Box token readable (missing, or the keychain is locked). Run display-handover-agent register.") }
            } else {
                tokenFailures = 0
            }
        }
        guard let token else { return (record(.unknown, "no access token"), false) }
        do {
            let status = try await syncBox.status(token: token)
            notifiedRejectedToken = false
            return (record(status.signal, status.summary), status.selectedInputPlugged)
        } catch {
            if case .rejectedToken = error {
                self.token = nil
                tokenRetryAt = now + 60
                if !notifiedRejectedToken {
                    notifiedRejectedToken = true
                    await Notifier.post("The Sync Box rejected the access token. Run display-handover-agent register.")
                }
            }
            return (record(.unknown, "unreachable: \(error)"), false)
        }
    }

    private func record(_ signal: SourceSignal, _ summary: String) -> SourceSignal {
        state.source = signal.rawValue
        state.syncBox = summary
        note("source", signal.rawValue)
        note("syncbox", summary)
        return signal
    }

    private func carryOut(_ decision: Decision, snapshot: DisplaySnapshot) async {
        guard !stopping else { return }
        switch decision {
        case .wait(let reason):
            state.activity = reason
        case .readInput:
            state.activity = "input read pending"
        case .switchToHDMI(let reason):
            guard actionStillSafe() else {
                state.activity = "switch to HDMI postponed: conditions changed since the decision"
                return
            }
            Log.info("switching \(name) to HDMI: \(reason)")
            policy.willSwitchToHDMI(now: now)
            saveState(force: true)
            actionsInFlight += 1
            let done = await betterDisplay.switchToHDMI()
            actionsInFlight -= 1
            policy.didSwitchToHDMI(succeeded: done, now: now)
            settle(Self.inputSwitchSettle, because: nil)
            switchCheck = (now, done)
            state.activity = done ? "switched to HDMI: \(reason)" : "switch to HDMI reported a failure, checking the input"
            if !done { Log.error("BetterDisplay reported a failure for the switch to HDMI, the next input reading decides") }
        case .disconnect(let reason):
            guard actionStillSafe() else {
                state.activity = "disconnect postponed: conditions changed since the decision"
                return
            }
            Log.info("disconnecting \(name): \(reason)")
            state.primaryWasMain = snapshot.primaryIsMain
            policy.willDisconnect(now: now)
            saveState(force: true)
            actionsInFlight += 1
            let done = await betterDisplay.setConnected(false) ? await waitForPrimary(online: false) : false
            actionsInFlight -= 1
            policy.didDisconnect(succeeded: done, now: now)
            settle(Self.displaySettle, because: nil)
            state.activity = done ? "disconnected: \(reason)" : "disconnect not confirmed"
            if done {
                notifiedDisconnectFailure = false
                Log.info("disconnected \(name)")
            } else {
                Log.error("disconnect not confirmed within 8 s, \(name) is still online")
                if !notifiedDisconnectFailure {
                    notifiedDisconnectFailure = true
                    await Notifier.post("Could not take the \(name) off the desktop. See ~/Library/Logs/display-handover-agent.log.")
                }
            }
        case .reconnect(let reason):
            // A reconnect spanning the sleep would miss its confirmation, so a later tick decides again. A
            // disconnect that landed after a manual reconnect then follows the normal reconnect rules instead.
            guard !power.sleeping else {
                state.activity = "reconnect postponed: system going to sleep"
                return
            }
            let done = await reconnect(reason: reason)
            policy.didReconnect(succeeded: done, now: now)
            if !done, let next = policy.state.nextReconnectAt { Log.info("next reconnect attempt at \(clock(next))") }
        }
    }

    private func actionStillSafe() -> Bool {
        let fresh = displays()
        noteDisplayChanges(fresh)
        return !isQuiet && fresh.otherDisplayOnline && !fresh.othersAsleep && !Control.load().isPaused(at: now)
    }

    /// Repeats the sleep and wake checks of `skipReason()`, for events that arrive while a tick awaits a reply
    private var isQuiet: Bool {
        now < quietUntil || power.sleeping || power.lastWake.map { now - $0.timeIntervalSince1970 < Self.wakeSettle } ?? false
    }

    private func checkSwitch(_ input: MonitorInput) async {
        guard let check = switchCheck else { return }
        switchCheck = nil
        if input == .hdmi {
            notifiedSwitchFailure = false
            if !check.commandSucceeded { Log.info("the switch to HDMI took effect after all") }
            return
        }
        Log.error("\(name) shows \(input) after the switch to HDMI, no retry until the source turns off and on again")
        if !notifiedSwitchFailure {
            notifiedSwitchFailure = true
            await Notifier.post("The \(name) did not switch to HDMI. Select HDMI on the monitor, the agent then takes it off the desktop.")
        }
    }

    private func handle(_ control: Control) async {
        if let request = control.tokenReloadRequest, request != handledTokenReloadRequest {
            handledTokenReloadRequest = request
            token = nil
            tokenFailures = 0
            tokenRetryAt = 0
        }
        if let request = control.resetRequest, request != state.handledResetRequest {
            state.handledResetRequest = request
            policy.reset()
            Log.info("resumed: circuit breaker, manual override and reconnect backoff cleared")
            saveState(force: true)
        }
        if let request = control.reconnectRequest, request != state.handledReconnectRequest {
            state.handledReconnectRequest = request
            notifiedReconnectFailure = false
            let wasOnline = displays().primaryOnline
            let done: Bool
            if wasOnline {
                done = true
            } else if BetterDisplay.isRunning {
                done = await reconnect(reason: "requested by the owner")
            } else {
                Log.error("manual reconnect requested, but BetterDisplay is not running")
                done = false
            }
            policy.didReconnectManually(succeeded: done, primaryWasOnline: wasOnline, now: now)
            state.manualReconnectSucceeded = done
            Log.info(done
                ? "manual override: no automatic disconnect until the HDMI source turns off"
                : "manual reconnect failed" + (policy.state.ownsDisconnect ? ", the agent retries when the HDMI source turns off" : ""))
            saveState(force: true)
        }
    }

    private func reconnect(reason: String, allowConnectAll: Bool = true) async -> Bool {
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        Log.info("reconnecting \(name): \(reason)")
        var done = await betterDisplay.setConnected(true) ? await waitForPrimary(online: true) : false
        if !done, allowConnectAll, connectAllTriedAt.map({ now - $0 >= 3600 }) ?? true {
            connectAllTriedAt = now
            Log.error("reconnect by UUID failed, trying Connect All Displays (reconnects every display BetterDisplay knows)")
            done = await BetterDisplay.connectAllDisplays() ? await waitForPrimary(online: true) : false
        }
        settle(Self.displaySettle, because: nil)
        guard done else {
            Log.error("could not reconnect \(name)")
            state.activity = "reconnect failed"
            if !notifiedReconnectFailure {
                notifiedReconnectFailure = true
                await Notifier.post("Could not reconnect the \(name). Use BetterDisplay > Tools > Displays And Virtual Screens > Connect All Displays.")
            }
            return false
        }
        notifiedReconnectFailure = false
        Log.info("reconnected \(name)")
        state.activity = "reconnected: \(reason)"
        if state.primaryWasMain { await restoreMain() }
        return true
    }

    /// A fallback, because macOS normally restores the main display from its stored arrangement
    private func restoreMain() async {
        try? await Task.sleep(for: .seconds(2))
        guard !displays().primaryIsMain else { return }
        let done = await betterDisplay.makeMain()
        Log.info(done ? "made \(name) the main display again" : "could not make \(name) the main display")
    }

    private func waitForPrimary(online: Bool, timeout: Double = 8) async -> Bool {
        let deadline = now + timeout
        while now < deadline {
            if displays().primaryOnline == online { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // One last look, because the deadline can pass during a forced sleep
        return displays().primaryOnline == online
    }

    private func settle(_ seconds: Double, because reason: String?) {
        if let reason, now >= quietUntil { Log.info("\(reason), waiting \(Int(seconds)) s") }
        quietUntil = max(quietUntil, now + seconds)
    }

    /// The CoreGraphics reconfiguration callback never fired in this agent (none in more than 40 display
    /// changes, cause unknown), so this compares the online displays between looks. It misses a change
    /// that reverts before the next look.
    private func noteDisplayChanges(_ snapshot: DisplaySnapshot) {
        let ids = Set(snapshot.entries.map(\.id))
        defer { lastDisplayIDs = ids }
        guard let last = lastDisplayIDs, last != ids else { return }
        settle(Self.displaySettle, because: "displays changed")
    }

    private func describePause(_ control: Control) -> String {
        control.pausedUntil.map { "paused until \(clock($0))" } ?? "paused until resume"
    }

    private func clock(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }

    private func note(_ key: String, _ value: String) {
        guard logged[key] != value else { return }
        logged[key] = value
        Log.info("\(key): \(value)")
    }

    /// Saves every 10 s even without changes, so the age of `updated` in `status` exposes a hung loop
    private func saveState(force: Bool = false) {
        state.policy = policy.state
        let durableChanged = savedState?.durable != state.durable
        guard force || durableChanged || now - lastSave >= 10 else { return }
        state.updated = now
        do {
            try state.save()
            savedState = state
            lastSave = now
            loggedSaveFailure = false
        } catch {
            if !loggedSaveFailure { Log.error("could not save state: \(error)") }
            loggedSaveFailure = true
        }
    }

    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard self.termination == nil else { return }
                self.stopping = true
                self.termination = Task { await self.terminate() }
            }
        }
        source.resume()
        terminationSource = source
    }

    /// Runs beside a tick that may be waiting on a BetterDisplay command
    private func terminate() async {
        Log.info("stopping")
        // launchd sends SIGKILL at most 60 s after SIGTERM (its ExitTimeOut cap), and the reconnect
        // below can take about 30 s (command timeout, confirmation, main display check).
        let deadline = now + 20
        while actionsInFlight > 0, now < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        if policy.state.ownsDisconnect || policy.state.pendingDisconnectAt != nil, BetterDisplay.isRunning {
            let done = await reconnect(reason: "agent stopping", allowConnectAll: false)
            policy.didReconnect(succeeded: done, now: now)
        }
        saveState(force: true)
    }
}
