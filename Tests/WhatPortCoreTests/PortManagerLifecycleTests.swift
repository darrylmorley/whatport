import Testing
import Foundation
@testable import WhatPortCore

// Integration tests for PortLifecycleStateMachine as wired into PortManager,
// through the public API only. See PortLifecycleStateMachineTests.swift for
// the machine's own unit tests.

@Test func portManagerLifecycleSignalSetsPhase() {
    let manager = PortManager()
    let t0 = Date()

    manager.applyLifecycleSignal(PortLifecycleSignalInput(portID: 1, signal: .attach), at: t0)

    #expect(manager.lifecyclePhases[1] == .detecting)
}

@Test func portManagerLifecycleClearsWhenSnapshotShowsPortIdleDisconnected() {
    let manager = PortManager()
    let t0 = Date()

    manager.applyLifecycleSignal(PortLifecycleSignalInput(portID: 1, signal: .attach), at: t0)
    #expect(manager.lifecyclePhases[1] == .detecting)

    // No ccData / deviceData for port 1, so it correlates as idle and
    // disconnected (ccConnected defaults to false); reconcile should clear
    // the tracked episode immediately, regardless of the timeout window.
    let snapshot = PortManagerSnapshot(
        timestamp: t0.addingTimeInterval(0.1),
        phyData: [PhyInput(phyID: 0)],
        tbData: [ThunderboltInput(socketID: 1)]
    )
    manager.applySnapshot(snapshot)

    #expect(manager.lifecyclePhases[1] == nil)
}

@Test func portManagerLifecycleClearsWhenSnapshotShowsResolvedPort() {
    let manager = PortManager()
    let t0 = Date()

    manager.applyLifecycleSignal(PortLifecycleSignalInput(portID: 1, signal: .negotiating), at: t0)
    #expect(manager.lifecyclePhases[1] == .negotiating)

    // CC connected (so it does not clear via the disconnected path) and a
    // device name resolved on the port: the resolved path alone must clear it.
    let snapshot = PortManagerSnapshot(
        timestamp: t0.addingTimeInterval(0.1),
        phyData: [PhyInput(phyID: 0)],
        tbData: [ThunderboltInput(socketID: 1)],
        ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)],
        deviceData: [DeviceInput(portNumber: 1, productName: "Widget")]
    )
    manager.applySnapshot(snapshot)

    #expect(manager.lifecyclePhases[1] == nil)
}

@Test func portManagerLifecycleSuppressesStaleSignalOnResolvedPort() {
    let manager = PortManager()
    let t0 = Date()

    // Resolve port 1 via a snapshot (reuses the resolved-port fixture from
    // portManagerLifecycleClearsWhenSnapshotShowsResolvedPort): CC connected
    // and a device name resolved, so the port reads as connected.
    let snapshot = PortManagerSnapshot(
        timestamp: t0,
        phyData: [PhyInput(phyID: 0)],
        tbData: [ThunderboltInput(socketID: 1)],
        ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)],
        deviceData: [DeviceInput(portNumber: 1, productName: "Widget")]
    )
    manager.applySnapshot(snapshot)
    #expect(manager.lifecyclePhases[1] == nil)

    // A late "negotiating" repeat arrives for the now-resolved port (the
    // codes repeat after completion). It must not recreate a phase and
    // flash "Negotiating" over the already-connected port.
    manager.applyLifecycleSignal(
        PortLifecycleSignalInput(portID: 1, signal: .negotiating),
        at: t0.addingTimeInterval(0.2)
    )

    #expect(manager.lifecyclePhases.isEmpty)
}

@Test func portManagerLifecycleRepeatedIdenticalSignalsLeaveDictionaryEqual() {
    let manager = PortManager()
    let t0 = Date()
    let input = PortLifecycleSignalInput(portID: 1, signal: .attach)

    manager.applyLifecycleSignal(input, at: t0)
    let firstPhases = manager.lifecyclePhases

    // Same signal repeated (these codes fire repeatedly on real hardware);
    // the phase value itself doesn't change, so the published dictionary
    // must compare equal, proving the equality guard coalesced the write.
    manager.applyLifecycleSignal(input, at: t0.addingTimeInterval(0.5))
    let secondPhases = manager.lifecyclePhases

    #expect(firstPhases == secondPhases)
    #expect(secondPhases[1] == .detecting)
}
