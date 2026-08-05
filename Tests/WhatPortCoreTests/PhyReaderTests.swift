import Testing
@testable import WhatPortIOKit

// Synthetic-dictionary pin for PhyReader.parse's DP tunnel decode: it reads
// "AppleTypeCPhyDisplayPortTunnel" -> "Tunnel 0" -> "Link Rate", the same
// nested shape native alt mode uses under "AppleTypeCPhyDisplayPortPclk" ->
// "PCLK 0". The corpus sweep (PhyCorpusSweepTests) pins this against real
// recordings; this pins the exact dictionary shape so a future refactor
// can't silently change the nesting without a synthetic fixture catching it.

@Test func phyReaderParsesDPTunnelLinkRate() {
    let properties: [String: Any] = [
        "AppleTypeCPhyID": 0,
        "AppleTypeCPhyDisplayPortTunnel": [
            "Tunnel 0": [
                "Link Rate": "5.40Gbps/lane (HBR2)",
                "Client": "AppleATCDPINAdapterPort(atc1-dpin0)"
            ]
        ]
    ]

    let phy = PhyReader.parse(properties: properties, portNumber: 1)

    #expect(phy.dpTunnel == "5.40Gbps/lane (HBR2)")
    // Native alt-mode link rate lives in a separate dictionary; nothing here
    // should populate it.
    #expect(phy.dpLinkRate == "")
}

@Test func phyReaderReturnsEmptyDPTunnelWhenAbsent() {
    let phy = PhyReader.parse(properties: [:], portNumber: 1)
    #expect(phy.dpTunnel == "")
}
