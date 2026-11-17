import Testing
@testable import DisplayHandoverAgentCore

private let online = Observation(primaryOnline: true, otherDisplayOnline: true, source: .active)
private let onlineInactive = Observation(primaryOnline: true, otherDisplayOnline: true, source: .inactive)
private let offlineActive = Observation(primaryOnline: false, otherDisplayOnline: true, source: .active)
private let offlineInactive = Observation(primaryOnline: false, otherDisplayOnline: true, source: .inactive)
private let offlineUnknown = Observation(primaryOnline: false, otherDisplayOnline: true, source: .unknown)
private let disconnectReason = Decision.disconnect("HDMI source active and monitor shows HDMI")

private func tick(_ policy: inout Policy, at now: Double, _ observation: Observation, input: InputReading = .value(.hdmi)) -> Decision {
    let first = policy.step(now: now, observation)
    guard first == .readInput else { return first }
    var withInput = observation
    withInput.input = input
    return policy.step(now: now, withInput)
}

private func disconnect(_ policy: inout Policy, at now: inout Double) {
    _ = tick(&policy, at: now, online)
    now += 2
    #expect(tick(&policy, at: now, online) == disconnectReason)
    policy.willDisconnect(now: now)
    policy.didDisconnect(succeeded: true, now: now)
}

private func disconnected(at now: inout Double) -> Policy {
    var policy = Policy()
    disconnect(&policy, at: &now)
    return policy
}

@Suite struct DisconnectTests {
    @Test func disconnectsAfterTwoHDMIReadsWhileSourceActive() {
        var policy = Policy()
        #expect(tick(&policy, at: 0, online) == .wait("monitor shows HDMI, confirming"))
        #expect(tick(&policy, at: 2, online) == disconnectReason)
    }

    @Test func neverReadsInputWithoutActiveSource() {
        var policy = Policy()
        for source in [SourceSignal.inactive, .unknown] {
            let observation = Observation(primaryOnline: true, otherDisplayOnline: true, source: source)
            if case .wait = policy.step(now: 0, observation) {} else { Issue.record("expected wait for \(source)") }
        }
    }

    @Test func keepsDisplayWhenNoOtherDisplayIsOnline() {
        var policy = Policy()
        let alone = Observation(primaryOnline: true, otherDisplayOnline: false, source: .active)
        _ = tick(&policy, at: 0, alone)
        #expect(tick(&policy, at: 2, alone) == .wait("no other display online"))
    }

    @Test func failedOrOtherReadsResetTheConfirmation() {
        for interruption in [InputReading.failed, .value(.thunderbolt)] {
            var policy = Policy()
            _ = tick(&policy, at: 0, online)
            _ = tick(&policy, at: 2, online, input: interruption)
            #expect(tick(&policy, at: 4, online) == .wait("monitor shows HDMI, confirming"))
        }
    }

    @Test func pacesInputReadsAndBacksOff() {
        var policy = Policy()
        #expect(policy.step(now: 0, online) == .readInput)
        _ = tick(&policy, at: 0, online, input: .value(.thunderbolt))
        #expect(policy.step(now: 1, online) == .wait("waiting for the next input read"))
        #expect(policy.step(now: 2, online) == .readInput)
        // After 30 s with the monitor on another input, reads slow to every 15 s
        for t in stride(from: 2.0, through: 30, by: 2) { _ = tick(&policy, at: t, online, input: .value(.thunderbolt)) }
        #expect(policy.step(now: 40, online) == .wait("waiting for the next input read"))
        #expect(policy.step(now: 45, online) == .readInput)
    }

    @Test func pauseBlocksDisconnectsWithoutReadingInput() {
        var policy = Policy()
        let paused = Observation(primaryOnline: true, otherDisplayOnline: true, source: .active, disconnectAllowed: false)
        for t in stride(from: 0.0, through: 10, by: 2) {
            #expect(policy.step(now: t, paused) == .wait("paused"))
        }
    }

    @Test func longGapRestartsTheConfirmation() {
        var policy = Policy()
        _ = tick(&policy, at: 0, online)
        #expect(tick(&policy, at: 10_800, online) == .wait("monitor shows HDMI, confirming"))
    }

    @Test func waitsForCooldownAfterAReconnect() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for _ in 0..<3 { now += 2; _ = policy.step(now: now, offlineInactive) }
        policy.didReconnect(succeeded: true, now: now)
        _ = tick(&policy, at: now + 2, online)
        #expect(tick(&policy, at: now + 4, online) == .wait("cooldown after the last action"))
        _ = tick(&policy, at: now + 16, online)
        #expect(tick(&policy, at: now + 18, online) == disconnectReason)
    }

    @Test func externalReconnectStartsTheCooldown() {
        var now = 0.0
        var policy = disconnected(at: &now)
        now += 120
        _ = policy.step(now: now, onlineInactive)
        _ = tick(&policy, at: now + 2, online)
        #expect(tick(&policy, at: now + 4, online) == .wait("cooldown after the last action"))
        _ = tick(&policy, at: now + 14, online)
        #expect(tick(&policy, at: now + 16, online) == disconnectReason)
    }
}

@Suite struct ReconnectTests {
    @Test func reconnectsAfterThreeInactivePolls() {
        var now = 0.0
        var policy = disconnected(at: &now)
        #expect(policy.step(now: now + 2, offlineInactive) == .wait("HDMI source off, confirming"))
        #expect(policy.step(now: now + 4, offlineInactive) == .wait("HDMI source off, confirming"))
        #expect(policy.step(now: now + 6, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func activeSourceInterruptsTheConfirmation() {
        var now = 0.0
        var policy = disconnected(at: &now)
        _ = policy.step(now: now + 2, offlineInactive)
        _ = policy.step(now: now + 4, offlineInactive)
        _ = policy.step(now: now + 6, offlineActive)
        #expect(policy.step(now: now + 8, offlineInactive) == .wait("HDMI source off, confirming"))
    }

    @Test func unknownPollsDoNotResetTheConfirmation() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let pattern = [offlineInactive, offlineUnknown, offlineInactive, offlineUnknown]
        for (i, observation) in pattern.enumerated() { _ = policy.step(now: now + Double(i + 1) * 2, observation) }
        #expect(policy.step(now: now + 10, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func leavesDisplaysItDidNotDisconnectAlone() {
        var policy = Policy()
        for t in stride(from: 0.0, through: 20, by: 2) {
            #expect(policy.step(now: t, offlineInactive) == .wait("primary display offline, not disconnected by this agent"))
        }
    }

    @Test func reconnectsWhenNoActiveSourceIsConfirmedFor120Seconds() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for t in stride(from: now + 2, through: now + 120, by: 2) { _ = policy.step(now: t, offlineUnknown) }
        #expect(policy.step(now: now + 121, offlineUnknown) == .wait("Sync Box state unknown"))
        #expect(policy.step(now: now + 123, offlineUnknown) == .reconnect("no active HDMI source confirmed for 120 s"))
    }

    @Test func unknownFailSafeCanBeDisabled() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.settings.unknownReconnectAfter = nil
        for t in stride(from: now + 2, through: now + 600, by: 2) {
            #expect(policy.step(now: t, offlineUnknown) == .wait("Sync Box state unknown"))
        }
    }

    @Test func reconnectsWhenNoOtherDisplayRemains() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let alone = Observation(primaryOnline: false, otherDisplayOnline: false, source: .active)
        #expect(policy.step(now: now + 2, alone) == .wait("HDMI source active"))
        #expect(policy.step(now: now + 4, alone) == .reconnect("no other display online"))
    }

    @Test func pauseStillReconnectsAnOwnedDisplay() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let paused = Observation(primaryOnline: false, otherDisplayOnline: true, source: .inactive, disconnectAllowed: false)
        _ = policy.step(now: now + 2, paused)
        _ = policy.step(now: now + 4, paused)
        #expect(policy.step(now: now + 6, paused) == .reconnect("HDMI source off"))
    }

    @Test func externalReconnectHandsControlBack() {
        var now = 0.0
        var policy = disconnected(at: &now)
        #expect(policy.state.ownsDisconnect)
        _ = policy.step(now: now + 2, onlineInactive)
        #expect(!policy.state.ownsDisconnect)
        #expect(policy.step(now: now + 4, offlineInactive) == .wait("primary display offline, not disconnected by this agent"))
    }

    @Test func failedReconnectKeepsResponsibilityAndBacksOff() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for _ in 0..<3 { now += 2; _ = policy.step(now: now, offlineInactive) }
        policy.didReconnect(succeeded: false, now: now)
        #expect(policy.state.ownsDisconnect)
        for t in stride(from: now + 2, through: now + 28, by: 2) {
            if case .reconnect = policy.step(now: t, offlineInactive) { Issue.record("retried before the backoff at \(t)") }
        }
        #expect(policy.step(now: now + 30, offlineInactive) == .reconnect("HDMI source off"))
        policy.didReconnect(succeeded: false, now: now + 30)
        #expect(policy.state.nextReconnectAt == now + 90)
    }

    @Test func lateDisconnectIsAdopted() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        #expect(tick(&policy, at: now, online) == disconnectReason)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now)
        _ = policy.step(now: now + 7, online)
        _ = policy.step(now: now + 9, offlineInactive)
        _ = policy.step(now: now + 11, offlineInactive)
        #expect(policy.step(now: now + 13, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func expiredDisconnectAttemptIsNotAdopted() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        _ = tick(&policy, at: now, online)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now)
        for t in stride(from: now + 7, through: now + 61, by: 2) { _ = policy.step(now: t, onlineInactive) }
        #expect(policy.step(now: now + 63, offlineInactive) == .wait("primary display offline, not disconnected by this agent"))
    }
}

@Suite struct OverrideAndBreakerTests {
    @Test func manualReconnectHoldsUntilTheSourceStaysOff() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 1)
        for t in stride(from: now + 20, through: now + 60, by: 2) {
            #expect(policy.step(now: t, online) == .wait("manual override until the HDMI source turns off"))
        }
        for t in [now + 62, now + 64, now + 66] { _ = policy.step(now: t, onlineInactive) }
        #expect(!policy.state.manualOverride)
        #expect(policy.step(now: now + 68, online) == .readInput)
    }

    @Test func oneInactivePollKeepsTheOverride() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 1)
        _ = policy.step(now: now + 20, onlineInactive)
        #expect(policy.state.manualOverride)
        #expect(policy.step(now: now + 22, online) == .wait("manual override until the HDMI source turns off"))
    }

    @Test func failedManualReconnectKeepsResponsibility() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.didReconnectManually(succeeded: false, primaryWasOnline: false, now: now + 1)
        #expect(policy.state.ownsDisconnect)
        _ = policy.step(now: now + 3, offlineInactive)
        _ = policy.step(now: now + 5, offlineInactive)
        #expect(policy.step(now: now + 7, offlineInactive) == .reconnect("HDMI source off"))
    }

    /// The display may be unplugged or switched off, so owning it would mean retrying the reconnect wherever the Mac goes
    @Test func aFailedManualReconnectOfAForeignDisconnectLeavesItToTheOwner() {
        var policy = Policy()
        _ = policy.step(now: 0, offlineInactive)
        policy.didReconnectManually(succeeded: false, primaryWasOnline: false, now: 20)
        #expect(!policy.state.ownsDisconnect)
        for t in stride(from: 22.0, through: 300, by: 2) {
            #expect(policy.step(now: t, offlineUnknown) == .wait("primary display offline, not disconnected by this agent"))
        }
    }

    @Test func aDisconnectLandingAfterAManualReconnectIsReconnectedAndTheOverrideHolds() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        _ = tick(&policy, at: now, online)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now + 8)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: true, now: now + 10)
        _ = policy.step(now: now + 10, onlinePaused)
        #expect(policy.step(now: now + 14, offlineActive) == .reconnect("disconnect landed after a manual reconnect"))
        policy.didReconnect(succeeded: true, now: now + 15)
        for t in stride(from: now + 18, through: now + 80, by: 2) {
            #expect(tick(&policy, at: t, online) == .wait("manual override until the HDMI source turns off"))
        }
        #expect(!policy.state.ownsDisconnect)
        #expect(policy.state.pendingDisconnectAt == nil)
    }

    @Test func aManualReconnectThatUndidALandedAttemptEndsIt() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        _ = tick(&policy, at: now, online)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now + 8)
        _ = policy.step(now: now + 10, onlinePaused)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 12)
        #expect(policy.state.pendingDisconnectAt == nil)
        #expect(policy.step(now: now + 40, offlineInactive) == .wait("primary display offline, not disconnected by this agent"))
    }

    @Test func aFailedManualReconnectAfterALandedAttemptKeepsTheAgentResponsible() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        _ = tick(&policy, at: now, online)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now + 8)
        _ = policy.step(now: now + 10, onlinePaused)
        policy.didReconnectManually(succeeded: false, primaryWasOnline: false, now: now + 12)
        #expect(policy.state.ownsDisconnect)
        #expect(policy.state.pendingDisconnectAt == nil)
        #expect(policy.step(now: now + 14, offlineActive) == .wait("HDMI source active"))
        _ = policy.step(now: now + 16, offlineInactive)
        _ = policy.step(now: now + 18, offlineInactive)
        #expect(policy.step(now: now + 20, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func aFailedReconnectOfALateLandingFallsBackToTheSourceOffPath() {
        var policy = Policy()
        var now = 0.0
        _ = tick(&policy, at: now, online)
        now += 2
        _ = tick(&policy, at: now, online)
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: false, now: now + 8)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: true, now: now + 10)
        #expect(policy.step(now: now + 14, offlineActive) == .reconnect("disconnect landed after a manual reconnect"))
        policy.didReconnect(succeeded: false, now: now + 22)
        #expect(policy.state.ownsDisconnect)
        for t in stride(from: now + 24, through: now + 60, by: 2) {
            if case .reconnect = policy.step(now: t, offlineActive) { Issue.record("reconnected while the source is on, at \(t)") }
        }
        _ = policy.step(now: now + 62, offlineInactive)
        _ = policy.step(now: now + 64, offlineInactive)
        #expect(policy.step(now: now + 66, offlineInactive) == .reconnect("HDMI source off"))
    }

    /// The agent cannot tell a session that continued through display sleep from a new one
    @Test func theOverrideHoldsThroughADisplaySleepInTheSameSession() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for t in stride(from: now + 2, through: now + 30, by: 2) { _ = policy.step(now: t, offlineActive) }
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 31)
        for t in stride(from: now + 33, through: now + 60, by: 2) {
            #expect(tick(&policy, at: t, online) == .wait("manual override until the HDMI source turns off"))
        }
        for t in stride(from: now + 660, through: now + 700, by: 2) {
            #expect(tick(&policy, at: t, online) == .wait("manual override until the HDMI source turns off"))
        }
    }

    @Test func theOverrideHoldsAcrossARestart() {
        var policy = Policy()
        policy.didReconnectManually(succeeded: true, primaryWasOnline: true, now: 1)
        var restarted = Policy(state: policy.state)
        for t in stride(from: 20.0, through: 60, by: 2) {
            #expect(tick(&restarted, at: t, online) == .wait("manual override until the HDMI source turns off"))
        }
    }

    @Test func breakerRefusesTheDisconnectAfterTheLimitAndLeavesTheDisplayConnected() {
        var policy = Policy()
        var now = 0.0
        for _ in 0..<4 {
            disconnect(&policy, at: &now)
            now += 1
            _ = policy.step(now: now, online)
            now += 16
        }
        #expect(policy.state.breakerUntil == nil)
        _ = tick(&policy, at: now, online)
        #expect(tick(&policy, at: now + 2, online) == .wait("circuit breaker opened"))
        #expect(policy.state.breakerUntil == now + 2 + 1800)
        #expect(!policy.state.ownsDisconnect)
        #expect(policy.step(now: now + 4, online) == .wait("circuit breaker open after repeated takeovers"))
        #expect(policy.step(now: now + 1802, online) == .readInput)
    }

    @Test func openBreakerNeverBlocksAnOwnedReconnect() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.state.breakerUntil = now + 1800
        _ = policy.step(now: now + 2, offlineInactive)
        _ = policy.step(now: now + 4, offlineInactive)
        #expect(policy.step(now: now + 6, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func resetClearsBreakerOverrideAndBackoff() {
        var policy = Policy()
        policy.state.breakerUntil = 1_000
        policy.state.manualOverride = true
        policy.state.reconnectFailures = 3
        policy.state.nextReconnectAt = 1_000
        policy.reset()
        #expect(policy.state == PolicyState())
        #expect(policy.step(now: 0, online) == .readInput)
    }
}

private let switchReason = Decision.switchToHDMI("HDMI source turned on while the monitor shows the Mac")
private let thunderbolt = InputReading.value(.thunderbolt)
private let onlineUnknown = Observation(primaryOnline: true, otherDisplayOnline: true, source: .unknown)
private let onlineAlone = Observation(primaryOnline: true, otherDisplayOnline: false, source: .active)
private let onlinePaused = Observation(primaryOnline: true, otherDisplayOnline: true, source: .active, disconnectAllowed: false)

private func sourceTurnsOn(_ policy: inout Policy, at now: inout Double, _ observation: Observation = online) -> Decision {
    var off = observation
    off.source = .inactive
    for _ in 0..<3 { _ = policy.step(now: now, off); now += 2 }
    _ = tick(&policy, at: now, observation, input: thunderbolt)
    now += 2
    return tick(&policy, at: now, observation, input: thunderbolt)
}

private func switchToHDMI(_ policy: inout Policy, at now: inout Double, succeeded: Bool = true) {
    #expect(sourceTurnsOn(&policy, at: &now) == switchReason)
    policy.willSwitchToHDMI(now: now)
    policy.didSwitchToHDMI(succeeded: succeeded, now: now)
}

private func takeoverCycle(_ policy: inout Policy, at now: inout Double) {
    switchToHDMI(&policy, at: &now)
    now += 2
    #expect(policy.step(now: now, onlinePaused) == .wait("paused"))  // The agent's quiet period after the switch
    now += 2
    _ = tick(&policy, at: now, online)
    now += 2
    #expect(tick(&policy, at: now, online) == disconnectReason)
    policy.willDisconnect(now: now)
    policy.didDisconnect(succeeded: true, now: now)
    for _ in 0..<3 { now += 2; _ = policy.step(now: now, offlineInactive) }
    policy.didReconnect(succeeded: true, now: now)
}

private func expectNoSwitch(_ policy: inout Policy, from start: Double, to end: Double, _ observation: Observation = online) {
    for now in stride(from: start, through: end, by: 2) {
        let decision = tick(&policy, at: now, observation, input: thunderbolt)
        if case .wait = decision {} else { Issue.record("expected no action at \(now), got \(decision)") }
    }
}

@Suite struct SwitchToHDMITests {
    @Test func switchesWhenASourceTurnsOnAndThenDisconnects() {
        var policy = Policy()
        var now = 0.0
        takeoverCycle(&policy, at: &now)
        #expect(policy.state.disconnectTimes.count == 1)  // The switch and its disconnect count as one takeover
        #expect(policy.state.switchedAt == nil)
    }

    @Test func aSwitchCountsAsATakeoverAtOnce() {
        var policy = Policy()
        var now = 0.0
        switchToHDMI(&policy, at: &now)
        #expect(policy.state.disconnectTimes == [now])
        #expect(policy.state.switchedAt == now)
    }

    @Test func armsOnlyAfterThreePollsWithoutASource() {
        var policy = Policy()
        _ = policy.step(now: 0, onlineInactive)
        _ = policy.step(now: 2, onlineInactive)
        expectNoSwitch(&policy, from: 4, to: 6)
        for now in [8.0, 10, 12] { _ = policy.step(now: now, onlineInactive) }
        #expect(tick(&policy, at: 14, online, input: thunderbolt) == .wait("HDMI source active, confirming"))
        #expect(tick(&policy, at: 16, online, input: thunderbolt) == switchReason)
    }

    @Test func leavesASourceThatWasAlreadyOnToTheOwner() {
        var policy = Policy()
        for now in stride(from: 0.0, through: 8, by: 2) {
            #expect(tick(&policy, at: now, online, input: thunderbolt) == .wait("monitor shows Thunderbolt"))
        }
    }

    @Test func switchesOncePerSourceSession() {
        var policy = Policy()
        var now = 0.0
        switchToHDMI(&policy, at: &now)
        for _ in 0..<3 {
            now += 3
            #expect(tick(&policy, at: now, online, input: thunderbolt) == .wait("monitor shows Thunderbolt after the switch"))
        }
        now += 2
        _ = policy.step(now: now, onlineInactive)
        expectNoSwitch(&policy, from: now + 2, to: now + 12)
        now += 14
        #expect(sourceTurnsOn(&policy, at: &now) == switchReason)
    }

    @Test func doesNotRetryAFailedSwitch() {
        var policy = Policy()
        var now = 0.0
        switchToHDMI(&policy, at: &now, succeeded: false)
        #expect(tick(&policy, at: now + 3, online, input: thunderbolt) == .wait("monitor shows Thunderbolt after the switch"))
        expectNoSwitch(&policy, from: now + 5, to: now + 45)
    }

    @Test func anUnknownPollDoesNotArmTheSwitch() {
        var policy = Policy()
        _ = tick(&policy, at: 0, online, input: thunderbolt)
        _ = policy.step(now: 2, onlineUnknown)
        expectNoSwitch(&policy, from: 4, to: 10)
    }

    @Test func oneUnknownPollInsideAnArmedSessionIsTolerated() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        #expect(tick(&policy, at: 6, online, input: thunderbolt) == .wait("HDMI source active, confirming"))
        _ = policy.step(now: 8, onlineUnknown)
        #expect(tick(&policy, at: 10, online, input: thunderbolt) == .wait("HDMI source active, confirming"))
        #expect(tick(&policy, at: 12, online, input: thunderbolt) == switchReason)
    }

    @Test func aLongUnknownStretchDisarmsTheSwitch() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        for now in stride(from: 6.0, through: 40, by: 2) { _ = policy.step(now: now, onlineUnknown) }
        expectNoSwitch(&policy, from: 42, to: 50)
    }

    @Test func oneSourceOffPollAfterALongUnknownStretchDoesNotArm() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        for now in stride(from: 6.0, through: 40, by: 2) { _ = policy.step(now: now, onlineUnknown) }
        _ = policy.step(now: 42, onlineInactive)
        expectNoSwitch(&policy, from: 44, to: 52)
    }

    @Test func aLongGapDisarmsTheSwitch() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        expectNoSwitch(&policy, from: 100, to: 106)
    }

    @Test func anHDMIReadingEndsTheArm() {
        // The owner selects HDMI before the agent switches, then goes back to the Mac
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        _ = tick(&policy, at: 6, online)
        #expect(tick(&policy, at: 8, online) == disconnectReason)
        policy.willDisconnect(now: 8)
        policy.didDisconnect(succeeded: true, now: 8)
        for now in stride(from: 10.0, through: 20, by: 2) { _ = policy.step(now: now, offlineActive) }
        expectNoSwitch(&policy, from: 22, to: 60)
    }

    @Test func anHDMIReadingEndsTheArmWithoutADisconnect() {
        // After selecting HDMI, the owner turns the other display on and goes back to the Mac within the switch window
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        #expect(tick(&policy, at: 6, onlineAlone) == .wait("monitor shows HDMI, confirming"))
        #expect(tick(&policy, at: 8, onlineAlone) == .wait("no other display online"))
        expectNoSwitch(&policy, from: 10, to: 30)
    }

    @Test func aRefusedSwitchStaysRefusedWhenTheBreakerClosesSoon() {
        var settings = PolicySettings()
        settings.breakerPause = 10
        var policy = Policy(settings: settings)
        var now = 0.0
        for _ in 0..<4 {
            switchToHDMI(&policy, at: &now)
            now += 3
            _ = tick(&policy, at: now, online, input: thunderbolt)
            now += 2
        }
        #expect(sourceTurnsOn(&policy, at: &now) == .wait("circuit breaker opened"))
        expectNoSwitch(&policy, from: now + 2, to: now + 20)  // The breaker closes within the switch window
    }

    @Test func aSwitchHeldBackLongerThanTheWindowIsDropped() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        for now in stride(from: 6.0, through: 40, by: 2) { _ = policy.step(now: now, onlinePaused) }
        expectNoSwitch(&policy, from: 42, to: 50)

        policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        for now in stride(from: 6.0, through: 16, by: 2) { _ = policy.step(now: now, onlinePaused) }
        #expect(tick(&policy, at: 18, online, input: thunderbolt) == switchReason)
    }

    @Test func respectsTheSettingAPauseAMissingDisplayAndAManualOverride() {
        var off = PolicySettings()
        off.switchToHDMI = false
        var policy = Policy(settings: off)
        var now = 0.0
        #expect(sourceTurnsOn(&policy, at: &now) == .wait("monitor shows Thunderbolt"))

        policy = Policy()
        now = 0
        #expect(sourceTurnsOn(&policy, at: &now, onlineAlone) == .wait("no other display online"))

        policy = Policy()
        now = 0
        #expect(sourceTurnsOn(&policy, at: &now, onlinePaused) == .wait("paused"))

        policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        policy.didReconnectManually(succeeded: true, primaryWasOnline: true, now: 5)
        _ = tick(&policy, at: 6, online, input: thunderbolt)
        #expect(tick(&policy, at: 8, online, input: thunderbolt) == .wait("manual override until the HDMI source turns off"))
    }

    @Test func waitsForTheCooldownAfterAReconnect() {
        var policy = Policy()
        var now = 0.0
        takeoverCycle(&policy, at: &now)
        let reconnectedAt = now
        now += 2
        #expect(sourceTurnsOn(&policy, at: &now) == .wait("cooldown after the last action"))
        now = reconnectedAt + 16
        #expect(tick(&policy, at: now, online, input: thunderbolt) == switchReason)
    }

    @Test func sourceOffPollsWhileDisconnectedArmTheNextSession() {
        var policy = Policy()
        var now = 0.0
        takeoverCycle(&policy, at: &now)
        let reconnectedAt = now
        #expect(tick(&policy, at: now + 2, online, input: thunderbolt) == .wait("HDMI source active, confirming"))
        #expect(tick(&policy, at: now + 4, online, input: thunderbolt) == .wait("cooldown after the last action"))
        #expect(tick(&policy, at: reconnectedAt + 16, online, input: thunderbolt) == switchReason)
    }

    @Test func readsAtTheNormalPaceAfterALateSwitch() {
        var policy = Policy()
        for now in [0.0, 2, 4] { _ = policy.step(now: now, onlineInactive) }
        for now in stride(from: 6.0, through: 32, by: 2) { _ = tick(&policy, at: now, onlineAlone, input: thunderbolt) }
        #expect(tick(&policy, at: 34, online, input: thunderbolt) == switchReason)
        policy.willSwitchToHDMI(now: 34)
        policy.didSwitchToHDMI(succeeded: true, now: 34)
        _ = policy.step(now: 36, onlinePaused)
        #expect(tick(&policy, at: 38, online) == .wait("monitor shows HDMI, confirming"))
        #expect(tick(&policy, at: 40, online) == disconnectReason)
    }

    @Test func theFollowUpExemptionEndsWithTheFollowUpDisconnect() {
        var policy = Policy()
        var now = 0.0
        switchToHDMI(&policy, at: &now)
        _ = tick(&policy, at: now + 3, online)
        #expect(tick(&policy, at: now + 5, online) == disconnectReason)
        now += 5
        policy.willDisconnect(now: now)
        policy.didDisconnect(succeeded: true, now: now)
        for _ in 0..<5 { now += 2; _ = policy.step(now: now, offlineActive) }
        now += 2
        let handBack = now  // Reconnected through BetterDisplay while the Dell still shows HDMI
        _ = tick(&policy, at: now, online)
        #expect(tick(&policy, at: now + 2, online) == .wait("cooldown after the last action"))
        #expect(tick(&policy, at: handBack + 16, online) == disconnectReason)
        policy.willDisconnect(now: handBack + 16)
        #expect(policy.state.disconnectTimes.count == 2)
    }

    @Test func aRestartBetweenSwitchAndDisconnectCountsOnce() {
        var policy = Policy()
        var now = 0.0
        switchToHDMI(&policy, at: &now)
        var restarted = Policy(state: policy.state)
        _ = tick(&restarted, at: now + 5, online)
        #expect(tick(&restarted, at: now + 7, online) == disconnectReason)
        restarted.willDisconnect(now: now + 7)
        #expect(restarted.state.disconnectTimes.count == 1)
    }

    @Test func fiveSwitchesWithoutDisconnectTripTheBreaker() {
        var policy = Policy()
        var now = 0.0
        for _ in 0..<4 {
            switchToHDMI(&policy, at: &now)
            now += 3
            _ = tick(&policy, at: now, online, input: thunderbolt)
            now += 2
        }
        #expect(sourceTurnsOn(&policy, at: &now) == .wait("circuit breaker opened"))
    }

    @Test func breakerRefusesTheFifthTakeoverAndTheSessionStaysWithTheOwner() {
        var policy = Policy()
        var now = 0.0
        for _ in 0..<4 {
            takeoverCycle(&policy, at: &now)
            now += 16
        }
        #expect(policy.state.disconnectTimes.count == 4)
        #expect(sourceTurnsOn(&policy, at: &now) == .wait("circuit breaker opened"))
        let until = now + 1800
        #expect(policy.state.breakerUntil == until)
        #expect(!policy.state.ownsDisconnect)
        expectNoSwitch(&policy, from: now + 2, to: until + 20)
    }
}

private let offlinePlugged = Observation(primaryOnline: false, otherDisplayOnline: true, source: .inactive, selectedInputPlugged: true)
private let onlinePlugged = Observation(primaryOnline: true, otherDisplayOnline: true, source: .inactive, selectedInputPlugged: true)

@Suite struct PluggedInputTests {
    @Test func waitsWhileTheSelectedInputStaysPlugged() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let first = now + 2
        #expect(policy.step(now: first, offlinePlugged) == .wait("HDMI source off, confirming"))
        for t in stride(from: first + 2, through: first + 18, by: 2) {
            #expect(policy.step(now: t, offlinePlugged) == (t < first + 4 ? .wait("HDMI source off, confirming") : .wait("input still plugged, confirming the source is off")))
        }
        #expect(policy.step(now: first + 20, offlinePlugged) == .reconnect("HDMI source off"))
    }

    @Test func aQuickInputChangeKeepsTheDisplayDisconnected() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let takeovers = policy.state.disconnectTimes
        for t in stride(from: now + 2, through: now + 12, by: 2) {
            #expect(policy.step(now: t, offlinePlugged) != .reconnect("HDMI source off"))
        }
        #expect(policy.step(now: now + 14, offlineActive) == .wait("HDMI source active"))
        #expect(policy.state.ownsDisconnect)
        #expect(policy.state.disconnectTimes == takeovers)
    }

    @Test func anActivePollRestartsThePluggedWait() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for t in stride(from: now + 2, through: now + 16, by: 2) { _ = policy.step(now: t, offlinePlugged) }
        _ = policy.step(now: now + 18, offlineActive)
        for t in stride(from: now + 20, through: now + 38, by: 2) {
            #expect(policy.step(now: t, offlinePlugged) != .reconnect("HDMI source off"))
        }
        #expect(policy.step(now: now + 40, offlinePlugged) == .reconnect("HDMI source off"))
    }

    @Test func threeUnpluggedPollsInARowEndTheWait() {
        var now = 0.0
        var policy = disconnected(at: &now)
        _ = policy.step(now: now + 2, offlinePlugged)
        _ = policy.step(now: now + 4, offlinePlugged)
        #expect(policy.step(now: now + 6, offlineInactive) == .wait("HDMI source off, confirming"))
        #expect(policy.step(now: now + 8, offlineInactive) == .wait("HDMI source off, confirming"))
        #expect(policy.step(now: now + 10, offlineInactive) == .reconnect("HDMI source off"))
    }

    @Test func aPluggedPollRestartsTheRunOfUnpluggedPolls() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for (i, observation) in [offlineInactive, offlineInactive, offlinePlugged, offlineInactive, offlineInactive].enumerated() {
            #expect(policy.step(now: now + Double(i + 1) * 2, observation) != .reconnect("HDMI source off"))
        }
        #expect(policy.step(now: now + 12, offlineInactive) == .reconnect("HDMI source off"))
    }

    /// Measured Apple TV power-on: plugged, plugged, one poll on the sleeping Switch's port (`unplugged`), plugged, plugged, linked
    @Test func oneUnpluggedPollInsideAnInputChangeKeepsTheDisplayDisconnected() {
        var now = 0.0
        var policy = disconnected(at: &now)
        let takeovers = policy.state.disconnectTimes
        for (i, observation) in [offlinePlugged, offlinePlugged, offlineInactive, offlinePlugged, offlinePlugged].enumerated() {
            #expect(policy.step(now: now + Double(i + 1) * 2, observation) != .reconnect("HDMI source off"))
        }
        #expect(policy.step(now: now + 12, offlineActive) == .wait("HDMI source active"))
        #expect(policy.state.ownsDisconnect)
        #expect(policy.state.disconnectTimes == takeovers)
    }

    @Test func oneUnpluggedPollInsideAnInputChangeKeepsTheManualOverride() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 1)
        for (i, observation) in [onlinePlugged, onlinePlugged, onlineInactive, onlinePlugged, onlinePlugged].enumerated() {
            _ = policy.step(now: now + 20 + Double(i) * 2, observation)
        }
        #expect(policy.state.manualOverride)
        #expect(policy.step(now: now + 30, online) == .wait("manual override until the HDMI source turns off"))
    }

    @Test func aShortPluggedGapKeepsTheManualOverride() {
        var now = 0.0
        var policy = disconnected(at: &now)
        policy.didReconnectManually(succeeded: true, primaryWasOnline: false, now: now + 1)
        for t in stride(from: now + 20, through: now + 30, by: 2) { _ = policy.step(now: t, onlinePlugged) }
        #expect(policy.state.manualOverride)
        #expect(policy.step(now: now + 32, online) == .wait("manual override until the HDMI source turns off"))
        for t in stride(from: now + 34, through: now + 52, by: 2) { _ = policy.step(now: t, onlinePlugged) }
        #expect(policy.state.manualOverride)
        _ = policy.step(now: now + 54, onlinePlugged)
        #expect(!policy.state.manualOverride)
    }

    @Test func aShortPluggedGapDoesNotArmTheSwitch() {
        var policy = Policy()
        expectNoSwitch(&policy, from: 0, to: 4)
        for t in stride(from: 6.0, through: 16, by: 2) { _ = policy.step(now: t, onlinePlugged) }
        expectNoSwitch(&policy, from: 18, to: 30)
        for t in stride(from: 32.0, through: 52, by: 2) { _ = policy.step(now: t, onlinePlugged) }
        #expect(tick(&policy, at: 54, online, input: thunderbolt) == .wait("HDMI source active, confirming"))
        #expect(tick(&policy, at: 56, online, input: thunderbolt) == switchReason)
    }

    @Test func aLongUnknownStretchRestartsThePluggedWait() {
        var now = 0.0
        var policy = disconnected(at: &now)
        for t in stride(from: now + 2, through: now + 6, by: 2) { _ = policy.step(now: t, offlinePlugged) }
        for t in stride(from: now + 8, through: now + 48, by: 2) { _ = policy.step(now: t, offlineUnknown) }
        for t in stride(from: now + 50, through: now + 68, by: 2) {
            #expect(policy.step(now: t, offlinePlugged) != .reconnect("HDMI source off"))
        }
        #expect(policy.step(now: now + 70, offlinePlugged) == .reconnect("HDMI source off"))
    }
}
