import Testing
@testable import WhatPortIOKit

// ControllerPowerReader.parse aggregates per-instance CurrentPowerState reads
// into the machine-wide awake/asleep summary. Split from the registry walk so
// synthetic state lists can be replayed through it directly, same pattern as
// DeviceReaderTests / PhyReaderTests.

@Test func controllerPowerDecodesOffVsAwakeState() {
    let allOff = ControllerPowerReader.parse(thunderboltStates: [0, 0], xhciStates: [0])
    #expect(allOff.anyThunderboltControllerAwake == false)
    #expect(allOff.anyXHCIControllerAwake == false)

    let oneAwake = ControllerPowerReader.parse(thunderboltStates: [0, 4], xhciStates: [3])
    #expect(oneAwake.anyThunderboltControllerAwake == true)
    #expect(oneAwake.anyXHCIControllerAwake == true)
}

// currentPowerState reads CurrentPowerState out of the nested IOPowerManagement
// dict, the real shape IOKit publishes it in.
@Test func controllerPowerReadsCurrentPowerStateFromRealDictShape() {
    let properties: [String: Any] = [
        "IOPowerManagement": [
            "CurrentPowerState": 4,
            "CapabilityFlags": 0
        ]
    ]
    #expect(ControllerPowerReader.currentPowerState(properties: properties) == 4)
}

// A service matched by class but missing IOPowerManagement (or missing
// CurrentPowerState within it) must not crash, and parse must not silently
// drop the instance from the "found" count even though its state is unknown.
@Test func controllerPowerHandlesMissingPowerManagementDict() {
    #expect(ControllerPowerReader.currentPowerState(properties: [:]) == nil)
    #expect(ControllerPowerReader.currentPowerState(properties: ["IOPowerManagement": ["OtherKey": 1]]) == nil)

    let result = ControllerPowerReader.parse(thunderboltStates: [nil], xhciStates: [])
    #expect(result.anyThunderboltControllerAwake == false, "Unknown state should not read as awake")
    #expect(result.thunderboltControllerCount == 1, "Instance still counts as matched")
}

// Zero matched instances must read as nil ("can't answer"), never as false
// ("answered: asleep"). This is the case Intel Macs hit, where Thunderbolt
// controllers publish under class names this reader doesn't match.
@Test func controllerPowerNoneFoundIsNilNotFalse() {
    let result = ControllerPowerReader.parse(thunderboltStates: [], xhciStates: [])
    #expect(result.anyThunderboltControllerAwake == nil)
    #expect(result.anyXHCIControllerAwake == nil)
    #expect(result.thunderboltControllerCount == 0)
    #expect(result.xhciControllerCount == 0)
}

// The two families are aggregated independently: one family being fully
// asleep or entirely unmatched must not affect the other's answer.
@Test func controllerPowerHandlesMixedFamilies() {
    let result = ControllerPowerReader.parse(thunderboltStates: [0, 0, 0], xhciStates: [])
    #expect(result.anyThunderboltControllerAwake == false)
    #expect(result.anyXHCIControllerAwake == nil)
    #expect(result.thunderboltControllerCount == 3)
    #expect(result.xhciControllerCount == 0)
}

// "Matched but every instance's properties were unreadable" and "no
// instance of this family was matched at all" must read differently: the
// former is a matched family (count > 0, awake answered as false), the
// latter is an unanswerable question (count == 0, awake == nil). readAll
// used to collapse the two by dropping services when ioProperties failed;
// this pins the distinction at the parse level, which is as close as this
// can get to readAll without a live IORegistry.
@Test func controllerPowerDistinguishesMatchedUnreadableFromNoMatches() {
    let matchedButUnreadable = ControllerPowerReader.parse(thunderboltStates: [nil], xhciStates: [nil])
    #expect(matchedButUnreadable.anyThunderboltControllerAwake == false)
    #expect(matchedButUnreadable.anyXHCIControllerAwake == false)
    #expect(matchedButUnreadable.thunderboltControllerCount == 1)
    #expect(matchedButUnreadable.xhciControllerCount == 1)

    let noMatches = ControllerPowerReader.parse(thunderboltStates: [], xhciStates: [])
    #expect(noMatches.anyThunderboltControllerAwake == nil)
    #expect(noMatches.anyXHCIControllerAwake == nil)
    #expect(noMatches.thunderboltControllerCount == 0)
    #expect(noMatches.xhciControllerCount == 0)
}
