import Testing
@testable import WhatPortIOKit

// The corpus loader, checked against text transcribed by hand.
//
// Every sweep feeds production code from ProbeCorpus, and the sweeps compare
// that output against other values ALSO read out of ProbeCorpus. That makes
// them independent of the readers but not of the loader: blank a key here and
// both sides of a sweep's comparison lose it together, so the sweep stays green
// while covering nothing. Review demonstrated exactly that.
//
// These fixtures are the closure. The expected values were read off the raw
// probe text by eye, so the loader is measured against something it did not
// produce.
@Suite("Probe corpus loader")
struct ProbeCorpusTests {

    // Transcribed from m4_macos15.7.7/01_walk_pd_tree.json, trimmed to the keys
    // a reader touches plus the shapes that have caused trouble: a nested
    // dictionary, a nested-inside-nested one, and a string array.
    private static let accessoryBlock = """
    === IOAccessoryManager[0] ===
      Class: AppleHPMInterfaceType10
      Name:  Port-USB-C
      Properties:
        PortTypeDescription = "USB-C"
        BuiltIn = true
        ConnectionCount = 3 (0x3)
        Overcurrent Count = 0 (0x0)
        Description = "Port-USB-C@2"
        Pin Configuration = {
          sbu1 = 0 (0x0)
          rx2 = 4 (0x4)
        }
        TransportsProvisioned = [
          [0] "CC"
          [1] "USB3"
        ]
        Metadata = {
        }
    """

    @Test("An accessory block parses to the values the raw text shows")
    func accessoryBlockParsesToTheRawValues() throws {
        let blocks = ProbeCorpus.accessoryBlocks(in: Self.accessoryBlock)
        try #require(blocks.count == 1)
        let block = try #require(blocks.first)

        #expect(block.entryName == "Port-USB-C")
        #expect(block.portNumber == 2)
        #expect(block.properties["PortTypeDescription"] as? String == "USB-C")
        #expect(block.properties["BuiltIn"] as? Bool == true)
        #expect(block.properties["ConnectionCount"] as? Int == 3)
        #expect(block.properties["Overcurrent Count"] as? Int == 0)
        #expect(block.properties["TransportsProvisioned"] as? [String] == ["CC", "USB3"])

        // A nested dictionary is kept, with its own values, and does not leak
        // its keys into the parent.
        let pins = block.properties["Pin Configuration"] as? [String: Any]
        #expect(pins?["rx2"] as? Int == 4)
        #expect(block.properties["rx2"] == nil, "a nested key must not surface in the parent")

        // An empty nested dictionary is a dictionary, not a dropped key.
        #expect((block.properties["Metadata"] as? [String: Any])?.isEmpty == true)
    }

    // Transcribed from m4_macos15.7.3/01_walk_pd_tree.json. The Clients value is
    // a CFBasicHash blob that spans several lines and carries its own braces,
    // including a bare closing one at the start of a line. Line-wise depth
    // tracking ended the PCLK dictionary there and lost the link rate on 88
    // machines, which read as "the corpus does not record link rates".
    private static let phyBlockWithBlob = """
    === AppleT8132TypeCPhy[0] ===
      Class: AppleT8132TypeCPhy
      Name:  AppleT8132TypeCPhy
      Properties:
        AppleTypeCPhyDisplayPortPclk = {
          PCLK 1 = {
            Clients = <<CFBasicHash 0x600003968 [0x1efcafef8]>{type = mutable set, count = 1,
    entries =>
    	1 : <CFString 0x600002268 [0x1efcafef8]>{contents = "AppleATCDPAltModePort(atc1-dpphy)"}
    }
    >
            Link Rate = "5.40Gbps/lane (HBR2)"
          }
        }
        AppleTypeCPhyLane = {
          Lane 1 = {
          }
          Lane 0 = {
            Transport = "USB3"
            Power Level = "on"
            Client = "AppleT8132USBXHCI"
          }
        }
        AppleTypeCPhyID = 0 (0x0)
    """

    @Test("A multi-line blob does not end the dictionary containing it")
    func aMultiLineBlobDoesNotEndItsDictionary() throws {
        let blocks = ProbeCorpus.phyBlocks(in: Self.phyBlockWithBlob)
        try #require(blocks.count == 1)
        let block = try #require(blocks.first)

        // The link rate sits AFTER the blob inside the same PCLK dictionary, so
        // it only survives if the blob's braces were counted rather than matched
        // line by line.
        let pclk = block["AppleTypeCPhyDisplayPortPclk"] as? [String: Any]
        let pclk1 = pclk?["PCLK 1"] as? [String: Any]
        #expect(pclk1?["Link Rate"] as? String == "5.40Gbps/lane (HBR2)")

        // And the dictionary that follows the blob's own is still read.
        let lanes = block["AppleTypeCPhyLane"] as? [String: Any]
        let lane0 = lanes?["Lane 0"] as? [String: Any]
        #expect(lane0?["Transport"] as? String == "USB3")
        #expect(lane0?["Client"] as? String == "AppleT8132USBXHCI")
        #expect(lane0?["Power Level"] as? String == "on")
        #expect((lanes?["Lane 1"] as? [String: Any])?.isEmpty == true)
        #expect(block["AppleTypeCPhyID"] as? Int == 0)
    }

    // Transcribed from a18pro_macos26.5.2/36_xhci_port_map.json.
    private static let rosterText = """
    === HPM UUID map ===

    [0] Port-USB-C@1        class=AppleHPMDeviceHALType3
          UUID=ED782231-F55A-6E65-C9B2-181AB86E1A2B  RID=0  Address=12
          ConnectionUUID=(none)
    [1] Port-MagSafe 3@1        class=AppleHPMDeviceHALType3
          UUID=CA862231-5C06-D662-E7A1-A62B8665B97E  RID=1  Address=10
    """

    @Test("A roster parses its ports, types and UUIDs")
    func rosterParsesPortsTypesAndUUIDs() throws {
        let ports = ProbeCorpus.roster(in: Self.rosterText)
        try #require(ports.count == 2)

        #expect(ports[0].portType == "USB-C")
        #expect(ports[0].portNumber == 1)
        #expect(ports[0].uuid == "ED782231-F55A-6E65-C9B2-181AB86E1A2B")

        // A port type containing a space, which is the shape that would break a
        // naive split.
        #expect(ports[1].portType == "MagSafe 3")
        #expect(ports[1].portNumber == 1)
        #expect(ports[1].uuid == "CA862231-5C06-D662-E7A1-A62B8665B97E")

        // The ConnectionUUID line must not be mistaken for the port's own UUID.
        #expect(ports[0].uuid != "(none)")
    }

    // Transcribed from a18pro_macos27.0/34_smc_power_keys.json.
    private static let smcText = """
      KEY  type  size  value
      D1UI hex_ 16    raw=6230af2dee594c1b9f3a1d2e3f4a5b6c
      D1MV ui16  2    raw=4e20  = 20000
      AP1A hex_ 44    (read failed 0xe00002c2)
      #KEY ui32  4    raw=00000998  = 2456
    """

    @Test("SMC keys parse to raw bytes, skipping keys that did not read")
    func smcKeysParseToRawBytes() {
        let keys = ProbeCorpus.smcKeys(in: Self.smcText)

        #expect(keys["D1MV"] == [0x4E, 0x20])
        #expect(keys["D1UI"]?.count == 16)
        #expect(keys["D1UI"]?.first == 0x62)

        // A key the probe could not read carries no bytes and must not appear
        // as an empty reading.
        #expect(keys["AP1A"] == nil)
    }
}
