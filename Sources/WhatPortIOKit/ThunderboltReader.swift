import Foundation
import IOKit

// Reads per-port Thunderbolt/USB4 link state from IOThunderboltPort services.
//
// Each USB-C port has several logical adapters (TB port, DP adapter, PCIe adapter,
// USB adapter, NHI adapter). We filter to adapters where Description = "Thunderbolt Port"
// because those are the ones with Socket ID mapping to physical ports.
//
// Socket ID is a string ("1", "2", "4") that maps directly to the physical
// USB-C port number.

public struct RawThunderboltData: Sendable {
    public let socketID: String
    public let portNumber: Int
    public let currentLinkWidth: Int
    // Speed reference (from research):
    //
    // Current Link Speed (a single code; among the nonzero codes, lower is faster):
    //   0x0 = idle
    //   0x8 = 10 Gb/s per lane (TB3)
    //   0x4 = 20 Gb/s per lane (TB4/USB4)
    //   0x2 = 40 Gb/s per lane (TB5/USB4 v2)
    public let currentLinkSpeed: Int
    public let supportedLinkWidth: Int
    // Supported Link Speed: a bitmask of the Current Link Speed codes.
    //   12 (0x4 | 0x8) = TB4-class controller
    //   14 (0x2 | 0x4 | 0x8) = TB5-capable controller
    public let supportedLinkSpeed: Int
    public let targetLinkWidth: Int
    public let targetLinkSpeed: Int
    public let linkBandwidth: Int
    public let description: String
    public let thunderboltVersion: Int
    public let dualLinkPort: Int

    public var isActive: Bool {
        currentLinkWidth > 0 && currentLinkSpeed > 0
    }
}

public enum ThunderboltReader {
    public static func readAll() -> [RawThunderboltData] {
        var results: [RawThunderboltData] = []

        withMatchingServices(className: "IOThunderboltPort") { service in
            guard let props = ioProperties(service) else { return }
            guard let data = parse(properties: props) else { return }
            results.append(data)
        }

        return results
    }

    // The adapter rules, given one service's properties. Split out from the
    // registry walk so recorded properties from other Macs can be replayed
    // through it; the walk above is then only responsible for finding services.
    //
    // Returns nil for an adapter that is not a physical port.
    static func parse(properties: [String: Any]) -> RawThunderboltData? {
        let desc = ioString(properties["Description"])

        // Only keep "Thunderbolt Port" adapters. These have Socket ID
        // and represent physical USB-C ports.
        guard desc == "Thunderbolt Port" else { return nil }

        return RawThunderboltData(
            socketID: ioString(properties["Socket ID"]),
            portNumber: ioInt(properties["Port Number"]),
            currentLinkWidth: ioInt(properties["Current Link Width"]),
            currentLinkSpeed: ioInt(properties["Current Link Speed"]),
            supportedLinkWidth: ioInt(properties["Supported Link Width"]),
            supportedLinkSpeed: ioInt(properties["Supported Link Speed"]),
            targetLinkWidth: ioInt(properties["Target Link Width"]),
            targetLinkSpeed: ioInt(properties["Target Link Speed"]),
            linkBandwidth: ioInt(properties["Link Bandwidth"]),
            description: desc,
            thunderboltVersion: ioInt(properties["Thunderbolt Version"]),
            dualLinkPort: ioInt(properties["Dual-Link Port"])
        )
    }
}
