import Testing
import Foundation
@testable import WhatPortCore

@Test func lifecycleAttachStartsDetecting() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)

    #expect(machine.phases[1] == .detecting)
}

@Test func lifecycleNegotiatingWithoutPriorAttachStartsNegotiating() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.negotiating, portID: 1, at: t0)

    #expect(machine.phases[1] == .negotiating)
}

@Test func lifecycleContractEstablishedWithoutPriorAttachStartsNegotiating() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.contractEstablished, portID: 1, at: t0)

    #expect(machine.phases[1] == .negotiating)
}

@Test func lifecycleDetectingThenNegotiatingUpgrades() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(1))

    #expect(machine.phases[1] == .negotiating)
}

@Test func lifecycleTransportReadyClears() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(1))
    machine.handle(.transportReady, portID: 1, at: t0.addingTimeInterval(2))

    #expect(machine.phases[1] == nil)
}

@Test func lifecycleLateStrayAttachDoesNotDowngrade() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(1))
    // A stray, late-arriving attach code after negotiating has already begun.
    machine.handle(.attach, portID: 1, at: t0.addingTimeInterval(2))

    #expect(machine.phases[1] == .negotiating)
}

@Test func lifecycleReconcileClearsOnDisconnectMidNegotiation() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(1))
    machine.reconcile(disconnectedPortIDs: [1], resolvedPortIDs: [], now: t0.addingTimeInterval(1.1))

    #expect(machine.phases[1] == nil)
}

@Test func lifecycleReconcileClearsOnResolved() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [1], now: t0.addingTimeInterval(0.5))

    #expect(machine.phases[1] == nil)
}

@Test func lifecycleStaleTimeoutClearsAfterThreeSeconds() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    // Just under the stale timeout: kept.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(2.9))
    #expect(machine.phases[1] == .detecting)

    // At/over the stale timeout with no fresh signal: cleared.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(3.0))
    #expect(machine.phases[1] == nil)
}

@Test func lifecycleHardCeilingClearsDespiteContinuousSignalChurn() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    // Refresh lastSignalAt every 2s (under the stale timeout each time) so the
    // stale check alone would never fire, right up to the 6s ceiling.
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(2))
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(2))
    #expect(machine.phases[1] == .negotiating)

    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(4))
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(4))
    #expect(machine.phases[1] == .negotiating)

    // startedAt is now >= 6s old even though lastSignalAt was just refreshed.
    machine.handle(.negotiating, portID: 1, at: t0.addingTimeInterval(6))
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(6))
    #expect(machine.phases[1] == nil)
}

@Test func lifecycleMultiplePortsTrackedIndependently() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    machine.handle(.negotiating, portID: 2, at: t0)

    // Port 1 resolves and clears; port 2 is untouched and survives.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [1], now: t0.addingTimeInterval(0.5))

    #expect(machine.phases[1] == nil)
    #expect(machine.phases[2] == .negotiating)
}

@Test func lifecycleNegativeClockIntervalDoesNotCrashOrWedge() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)
    // Clock jumps backwards: reconcile must not crash, and must not leave the
    // episode permanently stuck once time moves forward normally again.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(-100))
    #expect(machine.phases[1] != nil)

    // A normal forward reconcile past the hard ceiling still clears it.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: t0.addingTimeInterval(6))
    #expect(machine.phases[1] == nil)
}

@Test func lifecycleClockJumpBackwardRebasesAndClearsWithinStaleTimeoutOfCorrection() {
    var machine = PortLifecycleStateMachine()
    let t0 = Date()

    machine.handle(.attach, portID: 1, at: t0)

    // Clock is corrected backward by 100s, no signals since: reconcile must
    // not crash, and must rebase the episode to the corrected `now` rather
    // than leaving it reading as fresh for the next ~100s.
    let corrected = t0.addingTimeInterval(-100)
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: corrected)
    #expect(machine.phases[1] != nil)

    // Time then progresses normally from the corrected clock. Just under the
    // stale timeout measured from the correction: still kept.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: corrected.addingTimeInterval(2.9))
    #expect(machine.phases[1] != nil)

    // At the stale timeout measured from the correction: cleared. Without the
    // rebase this would still be well within the (deeply negative) original
    // interval and would wrongly survive.
    machine.reconcile(disconnectedPortIDs: [], resolvedPortIDs: [], now: corrected.addingTimeInterval(3.0))
    #expect(machine.phases[1] == nil)
}
