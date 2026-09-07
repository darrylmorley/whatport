import Testing
@testable import WhatPortIOKit

// Deduplication of two records for one physical connector.
//
// The roster keeps one entry per "portType:portNumber" in registry order, and
// registry order is not ours to choose. Since the parse started admitting a
// port with no UUID, first-wins alone could keep the record without the
// identity and drop the one that has it, which is the one thing the roster
// exists to carry. No corpus machine lists a connector twice (990 machines),
// so this pins the rule rather than fixing a live failure.
@Suite("HPM roster dedup")
struct HPMRosterDedupTests {

    private static let firstUUID = "DED58523-3D40-AFA6-9F47-046CFF0878FF"
    private static let secondUUID = "FCD58523-115C-EE9D-1143-1A1A67A71B46"

    // One USB-C port service as the walk hands it to the parse. Two of these
    // with the same number are the same physical connector seen twice.
    private static func port(uuid: String?, connectionCount: Int) -> RawHPMPort {
        let parsed = HPMReader.parse(
            properties: [
                "PortTypeDescription": "USB-C",
                "BuiltIn": true,
                "ConnectionCount": connectionCount
            ],
            entryName: "Port-USB-C",
            portNumber: 1,
            controllerUUID: uuid
        )
        return parsed!
    }

    @Test("A later record with a UUID beats a kept one without")
    func laterRecordWithAUUIDWins() {
        let roster = HPMReader.roster(from: [
            Self.port(uuid: nil, connectionCount: 1),
            Self.port(uuid: Self.firstUUID, connectionCount: 2)
        ])

        #expect(roster.count == 1)
        #expect(roster.first?.uuid == Self.firstUUID)
        // The whole record is taken, not just the UUID grafted onto the other.
        #expect(roster.first?.connectionCount == 2)
    }

    @Test("A record with a UUID is not lost to a later one without")
    func earlierRecordWithAUUIDIsKept() {
        let roster = HPMReader.roster(from: [
            Self.port(uuid: Self.firstUUID, connectionCount: 2),
            Self.port(uuid: nil, connectionCount: 1)
        ])

        #expect(roster.count == 1)
        #expect(roster.first?.uuid == Self.firstUUID)
        #expect(roster.first?.connectionCount == 2)
    }

    @Test("Two records that both carry a UUID stay first-wins")
    func twoIdentifiedRecordsStayFirstWins() {
        let roster = HPMReader.roster(from: [
            Self.port(uuid: Self.firstUUID, connectionCount: 2),
            Self.port(uuid: Self.secondUUID, connectionCount: 3)
        ])

        #expect(roster.count == 1)
        #expect(roster.first?.uuid == Self.firstUUID)
        #expect(roster.first?.connectionCount == 2)
    }

    @Test("Two records with no UUID at all collapse to one")
    func twoUnidentifiedRecordsCollapse() {
        let roster = HPMReader.roster(from: [
            Self.port(uuid: nil, connectionCount: 2),
            Self.port(uuid: nil, connectionCount: 3)
        ])

        #expect(roster.count == 1)
        #expect(roster.first?.uuid == "")
        #expect(roster.first?.connectionCount == 2)
    }
}
