import Testing
@testable import WhatPortIOKit

@Test func decodeLifecycleMessageMapsDocumentedCodes() {
    #expect(decodeLifecycleMessage(0xe3ff80c9) == .attach)
    #expect(decodeLifecycleMessage(0xe3ff80ca) == .negotiating)
    #expect(decodeLifecycleMessage(0xe3ff80cb) == .contractEstablished)
    #expect(decodeLifecycleMessage(0xe3ff8014) == .transportReady)
}

@Test func decodeLifecycleMessageIgnoresNoiseCodes() {
    // Every other message type observed in the probe 30 capture that is not
    // one of the four documented lifecycle codes.
    let noiseCodes: [UInt32] = [
        0xe0000120,
        0xe0000130,
        0xe3ff8000,
        0xe3ff8001,
        0xe3ff8010,
        0xe3ff8011,
        0xe3ff8013,
        0xe3ff8018,
        0xe3ff8051,
        0xe3ff8059,
        0xffffffff,
        0x0,
    ]

    for code in noiseCodes {
        #expect(decodeLifecycleMessage(code) == nil)
    }
}
