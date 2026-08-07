import Testing
@testable import WhatPortCore

@Test func laneTransportEnumExists() {
    let transport: LaneTransport = .thunderbolt
    #expect(transport == .thunderbolt)
}

@Test func tbGenerationFromSpeedCode() {
    #expect(TBGeneration(speedCode: 0x8) == .tb3)
    #expect(TBGeneration(speedCode: 0x4) == .tb4)
    #expect(TBGeneration(speedCode: 0x2) == .tb5)
    #expect(TBGeneration(speedCode: 99) == .tb4) // unknown defaults to TB4
}

@Test func tbGenerationFromThunderboltVersion() {
    #expect(TBGeneration(thunderboltVersion: 16) == .tb3)
    #expect(TBGeneration(thunderboltVersion: 32) == .tb4)
    #expect(TBGeneration(thunderboltVersion: 64) == .tb5)
    #expect(TBGeneration(thunderboltVersion: 0) == nil) // unknown -> nil
}

@Test func tbGenerationFromSupportedSpeedMask() {
    #expect(TBGeneration(supportedSpeedMask: 0x8) == .tb3)        // TB3 only
    #expect(TBGeneration(supportedSpeedMask: 12) == .tb4)         // 0x4|0x8
    #expect(TBGeneration(supportedSpeedMask: 14) == .tb5)         // 0x2|0x4|0x8
    #expect(TBGeneration(supportedSpeedMask: 0) == nil)           // nothing set
}

// Regression: a TB5 host (Thunderbolt Version 64) whose supported-speed
// bitmask reads 12 must report TB5 capability, not TB4. Previously the
// bitmask was fed into the per-lane speed-code decoder and fell through
// to the TB4 default.
@Test func tbCapabilityReportsTB5OnTB5Host() {
    let cap = ThunderboltCapability(
        supportedLinkSpeed: 12,
        supportedLinkWidth: 0x2,
        thunderboltVersion: 64
    )
    #expect(cap.maxGeneration == .tb5)
}

@Test func tbCapabilityFallsBackToMaskWhenVersionUnknown() {
    let cap = ThunderboltCapability(
        supportedLinkSpeed: 14,
        supportedLinkWidth: 0x2,
        thunderboltVersion: 0
    )
    #expect(cap.maxGeneration == .tb5)
}

// Regression: supportedLinkWidth is a bitmask. TB5 reports 3 (0x1|0x2) which
// previously fell through to the default and wrongly returned 1 (single-lane).
@Test func tbCapabilityMaxLanesBitmask() {
    let dualCap = ThunderboltCapability(supportedLinkSpeed: 14, supportedLinkWidth: 3, thunderboltVersion: 64)
    #expect(dualCap.maxLanes == 2)

    let singleCap = ThunderboltCapability(supportedLinkSpeed: 14, supportedLinkWidth: 1, thunderboltVersion: 64)
    #expect(singleCap.maxLanes == 1)
}

@Test func tbGenerationPerLaneSpeed() {
    #expect(TBGeneration.tb3.perLaneGbps == 10)
    #expect(TBGeneration.tb4.perLaneGbps == 20)
    #expect(TBGeneration.tb5.perLaneGbps == 40)
}

// USBSpeed decodes the IOUSBHostDevice "Device Speed" enum (0=LS...5=SSPlus2x2).
// There is a SECOND, unrelated USB enum with an almost identical name and
// overlapping numbering: the BOS descriptor's "USBSpeed" field (1=FS, 2=HS,
// 3=HS, 4=SS, 5=SSPlus). Feeding that table's numbers through this one would
// silently mislabel every device 3 and up. This pins code 3 as SuperSpeed
// (5 Gbps) specifically to catch a future refactor that reads the wrong key.
@Test func usbSpeedDecodesDeviceSpeedNotBOSSpeed() {
    #expect(USBSpeed(code: 3) == .superSpeed)
    #expect(USBSpeed(code: 3).label == "5 Gbps")
}

@Test func usbDeviceClassDecodesKnownClasses() {
    #expect(USBDeviceClass(code: 0x09) == .hub)
    #expect(USBDeviceClass(code: 0x01) == .audio)
    #expect(USBDeviceClass(code: 0x0E) == .video)
    #expect(USBDeviceClass(code: 0x08) == .massStorage)
    #expect(USBDeviceClass(code: 0x0B) == .smartCard)
    #expect(USBDeviceClass(code: 0x11) == .billboard)
    #expect(USBDeviceClass(code: 0xE0) == .wireless)
    #expect(USBDeviceClass(code: 0xEF) == .miscellaneous)
    #expect(USBDeviceClass(code: 0xFF) == .vendorSpecific)
}

// 0x00 means "per-interface", not a real device-level class, and anything
// not in the mapped list must stay unlabelled rather than guess.
@Test func usbDeviceClassRejectsPerInterfaceAndUnknown() {
    #expect(USBDeviceClass(code: 0x00) == nil)
    #expect(USBDeviceClass(code: 0x02) == nil) // CDC, not mapped at device level
    #expect(USBDeviceClass(code: 0xFE) == nil)
}

@Test func portStateIsActiveWhenLaneHasTransport() {
    var port = PortState(id: 1)
    #expect(!port.isActive)

    port.lane0 = LaneState(transport: .thunderbolt, powerLevel: .on, client: nil)
    #expect(port.isActive)
}

@Test func portHealthSeverityOk() {
    let health = PortHealth(overcurrentCount: 0, ldcmStatus: "No Error")
    #expect(health.severity == .ok)
    #expect(health.isHealthy == true)
}

@Test func portHealthSeverityOkEmptyLdcm() {
    let health = PortHealth(overcurrentCount: 0, ldcmStatus: "")
    #expect(health.severity == .ok)
    #expect(health.isHealthy == true)
}

@Test func portHealthSeverityWarning() {
    let health = PortHealth(overcurrentCount: 0, ldcmStatus: "Some Error")
    #expect(health.severity == .warning)
    #expect(health.isHealthy == false)
}

@Test func portHealthSeveritySeriousOvercurrent() {
    let health = PortHealth(overcurrentCount: 1, ldcmStatus: "No Error")
    #expect(health.severity == .serious)
    #expect(health.isHealthy == false)
}

@Test func portHealthSeverityOvercurrentDominates() {
    // Overcurrent takes priority over a warning-level LDCM status
    let health = PortHealth(overcurrentCount: 2, ldcmStatus: "Some Error")
    #expect(health.severity == .serious)
}

@Test func portStatePrimaryProtocol() {
    let idle = PortState(id: 1)
    #expect(idle.primaryProtocol == .idle)

    let tb = PortState(
        id: 2,
        lane0: LaneState(transport: .thunderbolt, powerLevel: .on, client: nil),
        thunderboltLink: ThunderboltLinkState(generation: .tb4, perLaneGbps: 20, txLanes: 2, rxLanes: 2)
    )
    #expect(tb.primaryProtocol == .thunderbolt)

    let dp = PortState(
        id: 3,
        lane0: LaneState(transport: .displayPort, powerLevel: .on, client: nil),
        lane1: LaneState(transport: .displayPort, powerLevel: .on, client: nil)
    )
    #expect(dp.primaryProtocol == .displayPort)
}

// Regression: macOS can leave IOThunderboltPort's Current Link Speed/Width
// populated long after a device is unplugged. Without lane or CC
// corroboration, a stale thunderboltLink must not paint the port blue.
@Test func portStatePrimaryProtocolIgnoresStaleThunderboltLink() {
    let stale = PortState(
        id: 1,
        lane0: .idle,
        lane1: .idle,
        usb2Active: false,
        ccConnected: false,
        thunderboltLink: ThunderboltLinkState(generation: .tb3, perLaneGbps: 10, txLanes: 2, rxLanes: 2)
    )
    #expect(stale.primaryProtocol == .idle)
}

// Regression: a plain USB-C PD charger trips the CC line (isActive becomes
// true) without training either lane as Thunderbolt. isActive alone is not
// enough corroboration, only a lane transport of .thunderbolt is. With a
// negotiated power contract present, this must report .charging, not
// .thunderbolt.
@Test func portStatePrimaryProtocolChargerDoesNotCorroborateStaleThunderboltLink() {
    let chargerPlugged = PortState(
        id: 1,
        lane0: .idle,
        lane1: .idle,
        usb2Active: false,
        ccConnected: true,
        thunderboltLink: ThunderboltLinkState(generation: .tb3, perLaneGbps: 10, txLanes: 2, rxLanes: 2),
        power: PortPower(watts: 20.0, current: 3000, voltage: 9000, configuredVoltage: 9000, configuredCurrent: 3000, vconnCurrent: 0)
    )
    #expect(chargerPlugged.hasLiveThunderboltLink == false)
    #expect(chargerPlugged.primaryProtocol == .charging)
}

// A genuine Thunderbolt connection always lights the PHY lanes as CIO
// transport, so a real link still reports .thunderbolt.
@Test func portStatePrimaryProtocolTrustsCorroboratedThunderboltLink() {
    let real = PortState(
        id: 1,
        lane0: LaneState(transport: .thunderbolt, powerLevel: .on, client: nil),
        lane1: .idle,
        usb2Active: false,
        ccConnected: false,
        thunderboltLink: ThunderboltLinkState(generation: .tb3, perLaneGbps: 10, txLanes: 2, rxLanes: 2)
    )
    #expect(real.primaryProtocol == .thunderbolt)
}

// Regression: PHY, TB and CIO are read non-atomically, so a genuine link
// can briefly show an active CIO transport before the lane catches up (or
// vice versa). An active CIO LiveTransport is just as real a corroboration
// as a trained lane, and is torn down with the connection like the lane is,
// unlike IOThunderboltPort's lingering link values.
@Test func portStatePrimaryProtocolTrustsActiveCIOTransportWithIdleLanes() {
    var port = PortState(
        id: 1,
        lane0: .idle,
        lane1: .idle,
        usb2Active: false,
        ccConnected: false,
        thunderboltLink: ThunderboltLinkState(generation: .tb4, perLaneGbps: 20, txLanes: 2, rxLanes: 2)
    )
    port.liveTransports = [LiveTransport(kind: .thunderbolt, dataRate: "40 Gbps")]
    #expect(port.hasLiveThunderboltLink == true)
    #expect(port.primaryProtocol == .thunderbolt)
}

// MARK: - eventIdentityName

@Test func eventIdentityNamePrefersDeviceNameWhenADisplayIsPresent() {
    var port = PortState(id: 1, ccConnected: true, deviceName: "27-inch Display")
    port.displayWidth = 3840
    port.displayHeight = 2160
    // A device tree can still be present behind a DP/TB port (e.g. a hub
    // sharing the same cable); the display keeps priority either way.
    port.usbDevices = [
        USBDeviceInfo(productName: "Hub", vendorName: "", deviceClass: .hub)
    ]
    #expect(port.eventIdentityName == "27-inch Display")
}

// The tree root stays put across polls even as usbDevice (the free tier's
// front-facing pick) flips from the hub to the real device behind it once
// the child enumerates.
@Test func eventIdentityNameUsesTheRootDeviceAndStaysStableAsTheTreeGrows() {
    var hubOnly = PortState(id: 1, ccConnected: true)
    hubOnly.usbDevices = [
        USBDeviceInfo(productName: "Dock Hub", vendorName: "", deviceClass: .hub)
    ]
    #expect(hubOnly.usbDevice?.productName == "Dock Hub")
    #expect(hubOnly.eventIdentityName == "Dock Hub")

    var hubAndChild = hubOnly
    hubAndChild.usbDevices.append(
        USBDeviceInfo(productName: "Drive", vendorName: "", deviceClass: .massStorage)
    )
    // usbDevice flips to the child now it has enumerated...
    #expect(hubAndChild.usbDevice?.productName == "Drive")
    // ...but eventIdentityName is unmoved: it is still the root.
    #expect(hubAndChild.eventIdentityName == "Dock Hub")
}

@Test func eventIdentityNameIsNilForAnEmptyPort() {
    let port = PortState(id: 1)
    #expect(port.eventIdentityName == nil)
}
