import IOKit
import Testing
@testable import WhatPortIOKit

// Smoke tests that read from real IOKit on this machine.
// These verify the readers don't crash and return plausible data.

@Test func phyReaderFindsAtLeastOnePort() {
    let phys = PhyReader.readAll()
    #expect(!phys.isEmpty, "Expected at least one AppleTypeCPhy instance on Apple Silicon")
}

@Test func phyReaderReturnsSortedByID() {
    let phys = PhyReader.readAll()
    let ids = phys.map(\.phyID)
    #expect(ids == ids.sorted())
}

@Test func thunderboltReaderFindsPhysicalPorts() {
    let ports = ThunderboltReader.readAll()
    #expect(!ports.isEmpty, "Expected at least one IOThunderboltPort with Socket ID")

    // Only the host controller's own ports carry a Socket ID. Attaching a
    // Thunderbolt device adds a downstream switch whose "Thunderbolt Port"
    // adapters have none, so requiring one on every adapter would fail
    // whenever a dock or display is plugged in. PortManager.bestTBPerSocket
    // already skips socket-less adapters; the host ports are what must be
    // present and well-formed.
    // Known gap: this can't catch a reader regression that drops the Socket ID
    // from only some host ports. Cross-checking against HPMReader's roster
    // wouldn't be safe either, since not every USB-C port is a Thunderbolt one
    // (Mac mini front ports are USB-only). Catching that needs replayed
    // multi-machine fixtures, not a smoke test on whatever Mac runs the suite.
    let socketIDs = ports.map(\.socketID).filter { !$0.isEmpty }
    #expect(!socketIDs.isEmpty, "Expected at least one host port carrying a Socket ID")

    for socketID in socketIDs {
        let parsed = Int(socketID)
        #expect(parsed != nil, "Socket ID should parse as an Int, got \(socketID)")
        #expect((parsed ?? 0) > 0, "Socket ID should be a positive physical port number")
    }
}

@Test func hpmReaderFindsPortsWithUUIDs() {
    let ports = HPMReader.readAll()
    #expect(!ports.isEmpty, "Expected at least one HPM port-controller node on Apple Silicon")

    for port in ports {
        #expect(!port.uuid.isEmpty, "Each HPM port should carry a UUID")
        #expect(port.portNumber > 0, "Each HPM port should have a positive port number")
    }

    // UUIDs must be unique per physical port, even when MagSafe and USB-C
    // share the same "@N" number (the whole point of using them).
    let uuids = ports.map(\.uuid)
    #expect(Set(uuids).count == uuids.count, "HPM port UUIDs should be unique")
}

// The roster matches the base class IOAccessoryManager rather than naming the
// chip-specific port-interface classes. This pins the assumption that makes that
// safe: every concrete class present on this Mac must also answer to the base.
// If a future macOS moves a port-interface class out from under it, the roster
// would empty out silently, which is exactly the failure this change existed to
// prevent, so it is worth catching in the suite rather than in the wild.
@Test func portInterfaceClassesAnswerToTheBaseClass() {
    // Every port-interface class seen across the probe corpus, plus the two
    // non-port ones it also returns (HDMI, Inductive), which the reader filters
    // out by port type rather than by class.
    let knownConcreteClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",  // never observed, kept in case it ever is
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11",
        "AppleDockConnectAIC",
        "AppleTCControllerSingleTransport",
    ]

    // Compared by registry entry ID, which is the only unambiguous identity for
    // a service. Comparing names would let two different services collapse to
    // one key and hide exactly the gap this is looking for. No port-type
    // filtering either: conformance is the property under test, and it should
    // hold for every service of these classes, port or not.
    func entryIDs(matching className: String) -> Set<UInt64> {
        var found: Set<UInt64> = []
        withMatchingServices(className: className) { service in
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return }
            found.insert(entryID)
        }
        return found
    }

    let viaConcreteClasses = knownConcreteClasses.reduce(into: Set<UInt64>()) {
        $0.formUnion(entryIDs(matching: $1))
    }
    let viaBaseClass = entryIDs(matching: "IOAccessoryManager")

    // Both sets empty would pass the subset check vacuously, so require the
    // base class to have found something first.
    #expect(!viaBaseClass.isEmpty, "Expected IOAccessoryManager services on Apple Silicon")
    #expect(!viaConcreteClasses.isEmpty, "Expected at least one known concrete class on this Mac")

    let missing = viaConcreteClasses.subtracting(viaBaseClass)
    #expect(missing.isEmpty, "Services the base class no longer reaches: \(missing.sorted())")
}

@Test func hpmReaderReturnsNonNegativeHealthCounters() {
    let ports = HPMReader.readAll()
    #expect(!ports.isEmpty, "Expected at least one HPM port on Apple Silicon")

    for port in ports {
        #expect(port.overcurrentCount >= 0, "Overcurrent count must be non-negative")
        #expect(port.plugEventCount >= 0, "Plug event count must be non-negative")
        #expect(port.connectionCount >= 0, "Connection count must be non-negative")
    }
}

@Test func snapshotReaderProducesCompleteSnapshot() {
    let snapshot = SnapshotReader.takeSnapshot()
    #expect(!snapshot.phyData.isEmpty)
    #expect(!snapshot.thunderboltData.isEmpty)
    #expect(!snapshot.hpmPorts.isEmpty)
}

@Test func smcDecodeFloatHandlesFiniteAndGarbage() {
    // 5.0f little-endian = 0x40A00000 -> bytes 00 00 A0 40
    #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0xA0, 0x40]) == 5.0)
    // Short payloads and non-finite bit patterns return nil.
    #expect(SMCPowerReader.decodeFloat([0x00, 0x00]) == nil)
    #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0x80, 0x7F]) == nil) // +inf
    #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0xC0, 0x7F]) == nil) // NaN
}

@Test func smcFourCCPacksKey() {
    // "D3UI" -> 0x44 33 55 49
    #expect(SMCPowerReader.fourCC("D3UI") == 0x44335549)
    #expect(SMCPowerReader.fourCC("TOOLONG") == nil)
}

@Test func smcReaderReadsPortChannelsWithUUIDs() {
    let channels = SMCPowerReader().readPortPowerChannels()
    // Apple Silicon exposes D1..D4 power channels with a DxUI per channel.
    #expect(!channels.isEmpty, "Expected SMC port-power channels on Apple Silicon")
    for channel in channels {
        #expect(channel.uuid.count == 32, "DxUI should be 32 hex chars")
        #expect(channel.uuid == channel.uuid.lowercased())
    }
    // Each channel's UUID must be unique (one per physical port).
    let uuids = channels.map(\.uuid)
    #expect(Set(uuids).count == uuids.count)
}
