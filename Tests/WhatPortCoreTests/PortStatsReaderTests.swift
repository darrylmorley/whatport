import Testing
@testable import WhatPortIOKit

// Port lifetime counters are read off the host controller's root ports rather
// than off whatever device happens to be plugged in. These pin the two pure
// pieces of that: which physical port a root port belongs to, and how the two
// nodes of one port fold together.

@Test func usbIOPortPathResolvesToThePhysicalPortNumber() {
    let path = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/nub-spmi-a1@78A08000"
        + "/AppleSPMIController/hpm3@C/AppleHPMARMSPMI/AppleHPMDeviceHALType3@C/Port-USB-C@4"
    #expect(PortStatsReader.usbCPortNumber(fromPath: path) == 4)
}

// The "@N" is a service-plane location, which IOKit renders in hex. Only bites
// at 10 and above, so only a Mac Studio-sized roster would ever notice.
@Test func usbIOPortPathParsesTheLocationAsHex() {
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C@A") == 10)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C@10") == 16)
}

// MagSafe carries no USB data, so it has no root port and no statistics. A path
// leading anywhere but a USB-C port must fail rather than hand back a number
// that would land on the USB-C port sharing that "@N".
@Test func usbIOPortPathRejectsAnythingButAUSBCPort() {
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-MagSafe 3@1") == nil)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C") == nil)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C@") == nil)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C@0") == nil)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-USB-C@zz") == nil)
    #expect(PortStatsReader.usbCPortNumber(fromPath: "") == nil)
    // "(none)" is what a probe prints for the property; a real read gets nil,
    // but the parse should not be the thing that saves us.
    #expect(PortStatsReader.usbCPortNumber(fromPath: "(none)") == nil)
}

// The device-tree name is what separates this Mac's own ports from everything
// else that publishes the same counters under the same classes: a hub's
// downstream ports, and a Thunderbolt accessory carrying its own XHCI silicon.
// IOKit names those after their class, and only device-tree nodes get a
// device-tree name.
@Test func onlyDeviceTreeNamedPortsCountAsThisMacsOwn() {
    #expect(PortStatsReader.isNativeRootPort("usb-drd0-port-ss"))
    #expect(PortStatsReader.isNativeRootPort("usb-drd3-port-hs"))

    #expect(!PortStatsReader.isNativeRootPort("AppleUSB30HubPort"))
    #expect(!PortStatsReader.isNativeRootPort("AppleUSB20HubPort"))
    #expect(!PortStatsReader.isNativeRootPort("AppleUSB30XHCIPort"))
    #expect(!PortStatsReader.isNativeRootPort(""))
    #expect(!PortStatsReader.isNativeRootPort(nil))
}

// Neither node of a port dominates the other, which is why this is a per-counter
// max and not a preference for one node.
@Test func mergeTakesTheHigherOfEachCounterFromEitherNode() {
    // Real shape from this Mac's port 4: the USB 2.0 node has seen one more
    // connection, the SuperSpeed node is the only one that counts link errors.
    let superSpeed = RawPortStats(
        portNumber: 4,
        connectCount: 24,
        overcurrentCount: 0,
        enumerationFailureCount: 1,
        addressFailureCount: 0,
        linkErrorCount: 3,
        remoteWakeCount: 0
    )
    let usb2 = RawPortStats(
        portNumber: 4,
        connectCount: 25,
        overcurrentCount: 2,
        enumerationFailureCount: 0,
        addressFailureCount: 5,
        linkErrorCount: 0,
        remoteWakeCount: 1
    )

    let merged = PortStatsReader.merged(superSpeed, usb2)
    #expect(merged.portNumber == 4)
    #expect(merged.connectCount == 25)
    #expect(merged.overcurrentCount == 2)
    #expect(merged.enumerationFailureCount == 1)
    #expect(merged.addressFailureCount == 5)
    #expect(merged.linkErrorCount == 3)
    #expect(merged.remoteWakeCount == 1)

    // Order must not matter: registry iteration order is not stable, and a
    // figure that moves between snapshots would fire phantom counter events.
    let reversed = PortStatsReader.merged(usb2, superSpeed)
    #expect(reversed.connectCount == merged.connectCount)
    #expect(reversed.overcurrentCount == merged.overcurrentCount)
    #expect(reversed.enumerationFailureCount == merged.enumerationFailureCount)
    #expect(reversed.addressFailureCount == merged.addressFailureCount)
    #expect(reversed.linkErrorCount == merged.linkErrorCount)
    #expect(reversed.remoteWakeCount == merged.remoteWakeCount)
}

// Summing would roughly double the connect count, since both nodes count most
// connections. Worth pinning: it is the obvious wrong way to combine these.
@Test func mergeNeverSumsCounters() {
    let a = RawPortStats(
        portNumber: 1,
        connectCount: 10,
        overcurrentCount: 0,
        enumerationFailureCount: 0,
        addressFailureCount: 0,
        linkErrorCount: 0,
        remoteWakeCount: 0
    )
    #expect(PortStatsReader.merged(a, a).connectCount == 10)
}

// Live: the whole point of the change is that an idle port still reports its
// lifetime totals, so this must hold on a Mac with nothing plugged in.
@Test func statsReaderCoversPortsWithNothingAttached() {
    let stats = PortStatsReader.readAll()
    #expect(!stats.isEmpty, "Expected root USB ports with statistics on Apple Silicon")

    let portNumbers = stats.map(\.portNumber)
    #expect(Set(portNumbers).count == portNumbers.count, "One record per physical port")
    #expect(portNumbers == portNumbers.sorted())
    for portNumber in portNumbers {
        #expect(portNumber > 0)
    }

    // Every USB-C port on the roster should be covered, whatever is plugged in.
    // MagSafe is excluded: it carries no USB data and has no root port.
    let usbCPorts = Set(HPMReader.readAll().filter { !$0.isMagSafe }.map(\.portNumber))
    let missing = usbCPorts.subtracting(portNumbers)
    #expect(missing.isEmpty, "USB-C ports with no lifetime statistics: \(missing.sorted())")

    // And nothing beyond it. Coverage alone would not notice a second source
    // publishing under a port number that already exists, which is the bug this
    // reader was rewritten to fix: the counters would just quietly be wrong.
    let unexpected = Set(portNumbers).subtracting(usbCPorts)
    #expect(unexpected.isEmpty, "Statistics for ports not on the roster: \(unexpected.sorted())")
}
