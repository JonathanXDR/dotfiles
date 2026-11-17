/// Durations are in seconds
public struct PolicySettings: Sendable, Equatable {
    /// Consecutive DDC reads of HDMI before a disconnect
    public var hdmiConfirmations = 2
    public var switchToHDMI = true
    /// Consecutive polls with an active source before the switch to HDMI
    public var activeConfirmations = 2
    /// The policy switches to HDMI only within this time after the session's first active poll
    public var switchWindow: Double = 30
    /// Sync Box polls without an active source before the source counts as off. That reconnects an
    /// owned display, ends a manual override and arms the switch to HDMI.
    public var inactiveConfirmations = 3
    /// While the selected input reads `plugged`, the source counts as off only after this long. Input
    /// changes and source restarts read `plugged` for 2 to 11 s (measured).
    public var pluggedOffAfter: Double = 20
    public var inputReadInterval: Double = 2
    public var inputReadBackoffAfter: Double = 30
    public var inputReadBackoffInterval: Double = 15
    /// Minimum time from a disconnect or any reconnect to the next switch or disconnect
    public var disconnectCooldown: Double = 15
    /// At most this many takeovers (switches to HDMI or disconnects) within `breakerWindow`. A switch and
    /// its follow-up disconnect count as one. The breaker refuses the next takeover, so it always leaves
    /// the display connected and on its current input.
    public var breakerLimit = 4
    public var breakerWindow: Double = 600
    public var breakerPause: Double = 1800
    /// Reconnects an owned display when no poll confirmed an active source for this long, as when the
    /// Sync Box is unreachable. `nil` disables this fail-safe.
    public var unknownReconnectAfter: Double? = 120
    /// One delay per consecutive failed reconnect. The last one repeats.
    public var reconnectRetryDelays: [Double] = [30, 60, 120, 300, 900]
    /// When the display goes offline within this time after an unconfirmed disconnect attempt, the agent
    /// counts the disconnect as its own. Also the window in which a disconnect follows up a switch to HDMI.
    public var pendingDisconnectWindow: Double = 60
    public var staleGap: Double = 30

    public init() {}
}

/// State that must survive an agent restart, so its times are wall-clock seconds
public struct PolicyState: Codable, Equatable, Sendable {
    public var ownsDisconnect = false
    public var pendingDisconnectAt: Double?
    public var manualOverride = false
    /// Times of recent takeovers, switches to HDMI included. Renaming it breaks decoding of saved state.
    public var disconnectTimes: [Double] = []
    public var breakerUntil: Double?
    public var reconnectFailures = 0
    public var nextReconnectAt: Double?
    public var switchedAt: Double?

    public init() {}
}

public enum InputReading: Equatable, Sendable {
    case notRead
    case failed
    case value(MonitorInput)
}

public struct Observation: Equatable, Sendable {
    public var primaryOnline: Bool
    /// Only awake displays count
    public var otherDisplayOnline: Bool
    public var source: SourceSignal
    public var selectedInputPlugged: Bool
    public var input: InputReading
    /// `false` also blocks DDC reads and the switch to HDMI, never the reconnect of an owned display
    public var disconnectAllowed: Bool

    public init(
        primaryOnline: Bool, otherDisplayOnline: Bool, source: SourceSignal, selectedInputPlugged: Bool = false,
        input: InputReading = .notRead, disconnectAllowed: Bool = true
    ) {
        self.primaryOnline = primaryOnline
        self.otherDisplayOnline = otherDisplayOnline
        self.source = source
        self.selectedInputPlugged = selectedInputPlugged
        self.input = input
        self.disconnectAllowed = disconnectAllowed
    }
}

public enum Decision: Equatable, Sendable {
    case wait(String)
    /// Read the primary display's input over DDC and step again with it
    case readInput
    case switchToHDMI(String)
    case disconnect(String)
    case reconnect(String)
}

public struct Policy: Sendable {
    public var settings: PolicySettings
    public var state: PolicyState

    private var lastStep: Double?
    private var lastAction: Double?
    private var hdmiStreak = 0
    private var activeSince: Double?
    private var lastInputRead: Double?
    private var overrideInactiveCount = 0
    /// Polls without an active source while offline and owned
    private var inactiveCount = 0
    private var lastActiveAt: Double?
    private var withoutOtherDisplay = 0
    /// The policy arms it only after seeing the source off, so a source that was already on stays with the owner
    private var switchArmed = false
    private var armedSessionStart: Double?
    private var offStreak = 0
    private var offSince: Double?
    /// A streak because the box can read `unplugged` for a single poll during an input change (measured)
    private var unpluggedStreak = 0
    private var activeStreak = 0
    private var lastKnownSourceAt: Double?

    public init(settings: PolicySettings = PolicySettings(), state: PolicyState = PolicyState()) {
        self.settings = settings
        self.state = state
    }

    public mutating func step(now: Double, _ observation: Observation) -> Decision {
        if let last = lastStep, now - last > settings.staleGap { restartConfirmations() }
        lastStep = now
        if let pending = state.pendingDisconnectAt, now - pending >= settings.pendingDisconnectWindow {
            state.pendingDisconnectAt = nil
        }
        trackSession(now: now, observation)
        return observation.primaryOnline ? stepWhileOnline(now: now, observation) : stepWhileOffline(now: now, observation)
    }

    private mutating func stepWhileOnline(now: Double, _ observation: Observation) -> Decision {
        inactiveCount = 0
        lastActiveAt = nil
        withoutOtherDisplay = 0
        if state.ownsDisconnect {
            // The owner, a BetterDisplay restart or macOS reconnected it, unless a pending attempt has not
            // landed yet. That attempt keeps its marker in case it still lands late.
            if state.pendingDisconnectAt == nil { lastAction = now }
            state.ownsDisconnect = false
            state.reconnectFailures = 0
            state.nextReconnectAt = nil
        }

        switch observation.source {
        case .inactive:
            hdmiStreak = 0
            activeSince = nil
            if state.manualOverride {
                overrideInactiveCount += 1
                if sourceOff(after: overrideInactiveCount, now: now) {
                    state.manualOverride = false
                    overrideInactiveCount = 0
                }
            }
            return .wait("no HDMI source active")
        case .unknown:
            hdmiStreak = 0
            activeSince = nil
            return .wait("Sync Box state unknown")
        case .active:
            overrideInactiveCount = 0
        }

        if state.manualOverride { return .wait("manual override until the HDMI source turns off") }
        guard observation.disconnectAllowed else {
            hdmiStreak = 0
            return .wait("paused")
        }
        if let until = state.breakerUntil {
            if now < until { return .wait("circuit breaker open after repeated takeovers") }
            state.breakerUntil = nil
        }
        let since = activeSince ?? now
        activeSince = since

        switch observation.input {
        case .notRead:
            let backoff = hdmiStreak == 0 && now - since >= settings.inputReadBackoffAfter
            let interval = backoff ? settings.inputReadBackoffInterval : settings.inputReadInterval
            if let last = lastInputRead, now - last < interval { return .wait("waiting for the next input read") }
            return .readInput
        case .failed:
            lastInputRead = now
            hdmiStreak = 0
            return .wait("input read failed")
        case .value(let input):
            lastInputRead = now
            guard input == .hdmi else {
                hdmiStreak = 0
                guard input == .thunderbolt, switchArmed else {
                    if input == .thunderbolt, isFollowUp(now: now) { return .wait("monitor shows Thunderbolt after the switch") }
                    return .wait("monitor shows \(input)")
                }
                guard activeStreak >= settings.activeConfirmations else { return .wait("HDMI source active, confirming") }
                guard observation.otherDisplayOnline else { return .wait("no other display online") }
                if let last = lastAction, now - last < settings.disconnectCooldown { return .wait("cooldown after the last action") }
                guard admitTakeover(now: now) else {
                    disarm()
                    return .wait("circuit breaker opened")
                }
                return .switchToHDMI("HDMI source turned on while the monitor shows the Mac")
            }
            // Once HDMI showed in this session, whoever selected it, a later Thunderbolt is the owner's choice
            disarm()
            hdmiStreak += 1
            guard hdmiStreak >= settings.hdmiConfirmations else { return .wait("monitor shows HDMI, confirming") }
            guard observation.otherDisplayOnline else { return .wait("no other display online") }
            // The switch to HDMI already passed the cooldown and the breaker for this takeover
            if !isFollowUp(now: now) {
                if let last = lastAction, now - last < settings.disconnectCooldown { return .wait("cooldown after the last action") }
                guard admitTakeover(now: now) else {
                    hdmiStreak = 0
                    return .wait("circuit breaker opened")
                }
            }
            return .disconnect("HDMI source active and monitor shows HDMI")
        }
    }

    private mutating func trackSession(now: Double, _ observation: Observation) {
        switch observation.source {
        case .inactive:
            offStreak += 1
            if offSince == nil { offSince = now }
            unpluggedStreak = observation.selectedInputPlugged ? 0 : unpluggedStreak + 1
            activeStreak = 0
            lastKnownSourceAt = now
            if sourceOff(after: offStreak, now: now) {
                switchArmed = settings.switchToHDMI
                armedSessionStart = nil
            }
        case .active:
            lastKnownSourceAt = now
            // A tick with an input read steps twice, so count the poll on its first step only
            if observation.input == .notRead {
                offStreak = 0
                offSince = nil
                unpluggedStreak = 0
                activeStreak += 1
            }
            guard switchArmed else { return }
            let start = armedSessionStart ?? now
            armedSessionStart = start
            if now - start > settings.switchWindow { disarm() }
        case .unknown:
            activeStreak = 0
            // A long unknown stretch may hide a source turning on, so arming again needs a full source-off count
            if let last = lastKnownSourceAt, now - last > settings.staleGap {
                disarm()
                offStreak = 0
                offSince = nil
                unpluggedStreak = 0
            }
        }
    }

    private mutating func disarm() {
        switchArmed = false
        armedSessionStart = nil
    }

    private func sourceOff(after polls: Int, now: Double) -> Bool {
        guard polls >= settings.inactiveConfirmations else { return false }
        return unpluggedStreak >= settings.inactiveConfirmations || now - (offSince ?? now) >= settings.pluggedOffAfter
    }

    private func isFollowUp(now: Double) -> Bool {
        state.switchedAt.map { now - $0 < settings.pendingDisconnectWindow } ?? false
    }

    /// Opens the circuit breaker instead when the window already holds the limit of takeovers
    private mutating func admitTakeover(now: Double) -> Bool {
        state.disconnectTimes = state.disconnectTimes.filter { now - $0 < settings.breakerWindow }
        guard state.disconnectTimes.count >= settings.breakerLimit else { return true }
        state.breakerUntil = now + settings.breakerPause
        state.disconnectTimes = []
        return false
    }

    private mutating func stepWhileOffline(now: Double, _ observation: Observation) -> Decision {
        hdmiStreak = 0
        activeSince = nil
        overrideInactiveCount = 0
        var landedAfterManualReconnect = false
        if !state.ownsDisconnect, state.pendingDisconnectAt != nil {
            state.ownsDisconnect = true  // The pending attempt landed late
            landedAfterManualReconnect = state.manualOverride
        }
        state.pendingDisconnectAt = nil
        guard state.ownsDisconnect else { return .wait("primary display offline, not disconnected by this agent") }
        if landedAfterManualReconnect { return .reconnect("disconnect landed after a manual reconnect") }

        let lastActive = lastActiveAt ?? now
        lastActiveAt = lastActive
        withoutOtherDisplay = observation.otherDisplayOnline ? 0 : withoutOtherDisplay + 1

        var reason: String?
        switch observation.source {
        case .active:
            inactiveCount = 0
            lastActiveAt = now
        case .inactive:
            inactiveCount += 1
            if sourceOff(after: inactiveCount, now: now) { reason = "HDMI source off" }
        case .unknown:
            if let limit = settings.unknownReconnectAfter, now - lastActive >= limit {
                reason = "no active HDMI source confirmed for \(Int(limit)) s"
            }
        }
        if withoutOtherDisplay >= 2 { reason = "no other display online" }
        guard let reason else {
            switch observation.source {
            case .active: return .wait("HDMI source active")
            case .inactive:
                let plugged = observation.selectedInputPlugged && inactiveCount >= settings.inactiveConfirmations
                return .wait(plugged ? "input still plugged, confirming the source is off" : "HDMI source off, confirming")
            case .unknown: return .wait("Sync Box state unknown")
            }
        }
        if let next = state.nextReconnectAt, now < next { return .wait("waiting to retry the reconnect") }
        return .reconnect(reason)
    }

    /// Call right before sending the switch to HDMI. Each source session gets one attempt, whatever the
    /// outcome. If the monitor shows the Mac again afterwards, the owner chose it.
    public mutating func willSwitchToHDMI(now: Double) {
        disarm()
        state.disconnectTimes.append(now)
        state.switchedAt = now
    }

    /// The follow-up disconnect needs no cooldown after the switch, so `lastAction` stays unchanged.
    /// The read backoff restarts, so the agent confirms a switch late in the window at the normal pace.
    public mutating func didSwitchToHDMI(succeeded: Bool, now: Double) {
        hdmiStreak = 0
        activeSince = now
    }

    /// Call right before sending the disconnect command, and persist the state, so the agent still owns a
    /// disconnect that lands late or while it stops.
    public mutating func willDisconnect(now: Double) {
        state.ownsDisconnect = true
        state.pendingDisconnectAt = now
        if !isFollowUp(now: now) { state.disconnectTimes.append(now) }
        state.switchedAt = nil
        disarm()
    }

    public mutating func didDisconnect(succeeded: Bool, now: Double) {
        lastAction = now
        hdmiStreak = 0
        if succeeded { state.pendingDisconnectAt = nil }
    }

    public mutating func didReconnect(succeeded: Bool, now: Double) {
        lastAction = now
        inactiveCount = 0
        lastActiveAt = nil
        withoutOtherDisplay = 0
        if succeeded {
            state.ownsDisconnect = false
            state.pendingDisconnectAt = nil
            state.reconnectFailures = 0
            state.nextReconnectAt = nil
        } else {
            state.reconnectFailures += 1
            let delays = settings.reconnectRetryDelays
            if !delays.isEmpty {
                state.nextReconnectAt = now + delays[min(state.reconnectFailures, delays.count) - 1]
            }
        }
    }

    /// A failed reconnect keeps the agent responsible for a display it disconnected, including a pending
    /// attempt that landed before the request, so the source-off path retries it. With `primaryWasOnline`,
    /// a pending attempt has not landed yet, so it stays pending and `stepWhileOffline` reconnects the display
    /// if it lands.
    public mutating func didReconnectManually(succeeded: Bool, primaryWasOnline: Bool, now: Double) {
        lastAction = now
        state.manualOverride = true
        hdmiStreak = 0
        overrideInactiveCount = 0
        if succeeded {
            state.ownsDisconnect = false
            if !primaryWasOnline { state.pendingDisconnectAt = nil }
            state.reconnectFailures = 0
            state.nextReconnectAt = nil
        } else if !primaryWasOnline, state.pendingDisconnectAt != nil {
            state.ownsDisconnect = true
            state.pendingDisconnectAt = nil
        }
    }

    public mutating func reset() {
        state.breakerUntil = nil
        state.disconnectTimes = []
        state.manualOverride = false
        state.reconnectFailures = 0
        state.nextReconnectAt = nil
    }

    private mutating func restartConfirmations() {
        hdmiStreak = 0
        activeSince = nil
        activeStreak = 0
        offStreak = 0
        offSince = nil
        lastKnownSourceAt = nil
        disarm()
        overrideInactiveCount = 0
        inactiveCount = 0
        lastActiveAt = nil
        withoutOtherDisplay = 0
    }
}
