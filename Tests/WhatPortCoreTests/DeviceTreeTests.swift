import Testing
@testable import WhatPortCore

// DeviceTree's locationID walk, checked against real corpus captures so the
// nibble-stripping arithmetic is pinned to actual hardware, not just made-up
// numbers.

// Machine: m2ultra_macos27.0. A "Drive Dock" hub attached directly to the
// host, with "Drive Dock Bay 2" behind it as the only child.
@Test func deviceTreeResolvesDriveDockParentAndDepth() {
    let dock = DeviceInput(portNumber: 1, productName: "Drive Dock", locationID: 0x8200000)
    let bay = DeviceInput(portNumber: 1, productName: "Drive Dock Bay 2", locationID: 0x8210000)
    let all = [dock, bay]

    #expect(DeviceTree.parentLocationID(bay.locationID) == dock.locationID)
    #expect(DeviceTree.hubDepth(of: bay, in: all) == 1)
    #expect(DeviceTree.viaName(of: bay, in: all) == "Drive Dock")

    // The dock itself is directly attached: no parent, depth 0.
    #expect(DeviceTree.parentLocationID(dock.locationID) == nil)
    #expect(DeviceTree.hubDepth(of: dock, in: all) == 0)
    #expect(DeviceTree.viaName(of: dock, in: all) == nil)
}

// Machine: m4max_macos26.5.1_f. Two nested VIA Labs "USB2.0 Hub" devices
// (outer directly attached, inner behind the outer), with a PreSonus "ATOM"
// audio interface behind the inner hub.
@Test func deviceTreeResolvesNestedHubDepthAndViaName() {
    let outerHub = DeviceInput(portNumber: 2, productName: "USB2.0 Hub", locationID: 0x3100000)
    let innerHub = DeviceInput(portNumber: 2, productName: "USB2.0 Hub", locationID: 0x3140000)
    let atom = DeviceInput(portNumber: 2, productName: "ATOM", locationID: 0x3141000)
    let all = [outerHub, innerHub, atom]

    #expect(DeviceTree.parentLocationID(atom.locationID) == innerHub.locationID)
    #expect(DeviceTree.parentLocationID(innerHub.locationID) == outerHub.locationID)
    #expect(DeviceTree.hubDepth(of: atom, in: all) == 2)
    #expect(DeviceTree.viaName(of: atom, in: all) == "USB2.0 Hub")
}

@Test func deviceTreeDirectlyAttachedDeviceHasNoParent() {
    // Single non-zero path nibble: directly attached, not behind a hub.
    let device = DeviceInput(portNumber: 3, productName: "Direct Device", locationID: 0x1500000)
    let all = [device]

    #expect(DeviceTree.parentLocationID(device.locationID) == nil)
    #expect(DeviceTree.hubDepth(of: device, in: all) == 0)
    #expect(DeviceTree.viaName(of: device, in: all) == nil)
}

@Test func deviceTreeOrphanChildStopsAtDepthZero() {
    // The child's locationID resolves to a parent, but that parent is not
    // present in `all` (e.g. filtered out, or unplugged mid-poll).
    let orphan = DeviceInput(portNumber: 1, productName: "Drive Dock Bay 2", locationID: 0x8210000)
    let all = [orphan]

    #expect(DeviceTree.parentLocationID(orphan.locationID) != nil)
    #expect(DeviceTree.hubDepth(of: orphan, in: all) == 0)
    #expect(DeviceTree.viaName(of: orphan, in: all) == nil)
}

@Test func deviceTreeTreatsNonPositiveLocationIDsAsMalformed() {
    #expect(DeviceTree.parentLocationID(0) == nil)
    #expect(DeviceTree.parentLocationID(-1) == nil)

    let zeroed = DeviceInput(portNumber: 1, productName: "Mystery Device", locationID: 0)
    #expect(DeviceTree.hubDepth(of: zeroed, in: [zeroed]) == 0)
    #expect(DeviceTree.viaName(of: zeroed, in: [zeroed]) == nil)
}

@Test func deviceTreePicksFirstOccurrenceOnDuplicateLocationIDs() {
    let dock = DeviceInput(portNumber: 1, productName: "Drive Dock", locationID: 0x8200000)
    let duplicateDock = DeviceInput(portNumber: 2, productName: "Impostor Dock", locationID: 0x8200000)
    let bay = DeviceInput(portNumber: 1, productName: "Drive Dock Bay 2", locationID: 0x8210000)
    let all = [dock, duplicateDock, bay]

    #expect(DeviceTree.viaName(of: bay, in: all) == "Drive Dock")
}

// A valid locationID fills its path nibbles contiguously from the top. A
// gapped path (0x08201000, nibbles 2-0-1) cannot come from the encoding, and
// stripping it would fabricate 0x08200000, a plausible but wrong parent.
@Test func deviceTreeRejectsGappedNibblePaths() {
    #expect(DeviceTree.parentLocationID(0x08201000) == nil)
    #expect(DeviceTree.parentLocationID(0x08000100) == nil)
}

// locationID is a UInt32 quantity; anything wider is malformed input, not a
// value IOKit can have produced.
@Test func deviceTreeRejectsValuesWiderThanUInt32() {
    #expect(DeviceTree.parentLocationID(0x1_0000_0000) == nil)
    #expect(DeviceTree.parentLocationID(Int.max) == nil)
}

// Bus bytes with bit 31 set are valid unsigned values (read via uint32Value
// at the IOKit layer, so they arrive positive). The tree arithmetic must
// treat them like any other bus.
@Test func deviceTreeHandlesHighBusBytes() {
    #expect(DeviceTree.parentLocationID(0x8221_0000) == 0x8220_0000)
    #expect(DeviceTree.parentLocationID(0x8220_0000) == nil)
}
