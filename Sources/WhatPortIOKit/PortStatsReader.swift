import Foundation
import IOKit

// Reads USB port lifetime statistics from the host controller's root ports.
//
// A USB-C port publishes up to two root-port services, a SuperSpeed one and a
// USB 2.0 one, each with a "port-statistics" dictionary of lifetime counters:
// connections, error counts, and time spent in each power state. They exist
// whether or not anything is plugged in, which is exactly when the lifetime
// totals are worth reading.
//
// Two things make finding those nodes awkward, and both are solved by leaning
// on the device tree rather than on class names.
//
// Class names move between OS versions and chips: macOS 15+ publishes the
// AppleUSB*XHCIARMPort subclasses, macOS 14 publishes the plain AppleUSB*XHCIPort
// ones they derive from. We match the base class plus those two superclasses, so
// any one of them being matchable is enough.
//
// A class match alone is not selective enough, though. Hub and dock downstream
// ports carry a port-statistics dictionary of their own describing the hub, and
// a Thunderbolt accessory with its own XHCI silicon publishes root ports of the
// same classes for its own connectors. Neither describes a port on this Mac.
// This Mac's root ports are device-tree nodes, named "usb-drdN-port-ss" or
// "-hs", and that name comes from firmware rather than from the kext: it is the
// one identifier that holds across both renames above. It also holds across the
// whole probe corpus, on 2443 of 2443 root-port records.

public struct RawPortStats: Sendable {
    public let portNumber: Int
    public let connectCount: Int
    public let overcurrentCount: Int
    public let enumerationFailureCount: Int
    public let addressFailureCount: Int
    public let linkErrorCount: Int
    public let remoteWakeCount: Int
}

public enum PortStatsReader {
    // Matched in turn; a root port that answers to more than one of these is
    // read more than once, which costs nothing because folding a record into
    // itself leaves it unchanged.
    private static let rootPortClasses = [
        "AppleUSBHostPort",     // base class, covers every subclass by name
        "AppleUSB30XHCIPort",   // the pre-ARM names: the concrete classes on
        "AppleUSB20XHCIPort",   // macOS 14, and superclasses of the ARM ones
    ]

    public static func readAll() -> [RawPortStats] {
        var byPort: [Int: RawPortStats] = [:]

        for className in rootPortClasses {
            withMatchingServices(className: className) { service in
                guard isNativeRootPort(ioEntryName(service)) else { return }

                let stats = ioDictionary(ioProperty(service, key: "port-statistics"))
                guard !stats.isEmpty else { return }
                guard let portNumber = physicalPortNumber(of: service) else { return }

                let record = RawPortStats(
                    portNumber: portNumber,
                    connectCount: ioInt(stats["kPortStatConnectCount"]),
                    overcurrentCount: ioInt(stats["kPortStatOverCurrentCount"]),
                    enumerationFailureCount: ioInt(stats["kPortStatEnumerationFailureCount"]),
                    addressFailureCount: ioInt(stats["kPortStatAddressFailureCount"]),
                    linkErrorCount: ioInt(stats["kPortStatEOF2ViolationCount"]),
                    remoteWakeCount: ioInt(stats["kPortStatRemoteWakeCount"])
                )

                byPort[portNumber] = byPort[portNumber].map { merged($0, record) } ?? record
            }
        }

        return byPort.values.sorted { $0.portNumber < $1.portNumber }
    }

    // A root port belonging to this Mac, as opposed to a hub's downstream port
    // or a Thunderbolt accessory's own XHCI silicon.
    //
    // Only the Mac's own ports are device-tree nodes, so only they carry a
    // device-tree name. IOKit names everything else after its class
    // ("AppleUSB30HubPort"), which is how the two are told apart without
    // needing to recognise every kind of thing that is not a Mac port.
    static func isNativeRootPort(_ entryName: String?) -> Bool {
        guard let entryName else { return false }
        return entryName.hasPrefix("usb-drd")
    }

    // The physical port number a root port belongs to.
    //
    // "UsbIOPort" is a registry path straight to the HPM port node
    // (".../Port-USB-C@4"), so it joins directly to the roster HPMReader builds.
    // macOS 15 publishes it on no root port at all, so the device-tree
    // "port-number" on the usb-drdN ancestor stays as the fallback.
    //
    // "UsbCPortNumber" is deliberately not consulted: it numbers ports
    // sequentially and so disagrees with the physical number on any Mac that
    // skips one (this M5 reports 3 for its port 4).
    static func physicalPortNumber(of service: io_service_t) -> Int? {
        if let path = ioProperty(service, key: "UsbIOPort") as? String,
           let portNumber = usbCPortNumber(fromPath: path) {
            return portNumber
        }

        // Root port -> host controller -> usb-drdN is two steps on every Mac
        // measured, and the bound leaves headroom for a chip that inserts one.
        // Walking further is safe here: the only nodes above are the SoC and
        // platform ones, which carry no port-number, and only this Mac's own
        // ports reach this line at all.
        guard let portNumber = ioFirstAncestorDataInt(service, key: "port-number", maxLevels: 6),
              portNumber > 0 else { return nil }
        return portNumber
    }

    // "IOService:/.../Port-USB-C@4" -> 4.
    //
    // The "@N" is the node's location in the service plane and is rendered in
    // hex, matching how ioLocationInPlaneInt reads the same number for the HPM
    // roster. Only USB-C leaves resolve: anything else is not a port that
    // carries USB data.
    static func usbCPortNumber(fromPath path: String) -> Int? {
        guard let leaf = path.split(separator: "/").last else { return nil }
        let parts = leaf.split(separator: "@")
        guard parts.count == 2, parts[0] == "Port-USB-C" else { return nil }
        guard let portNumber = Int(parts[1], radix: 16), portNumber > 0 else { return nil }
        return portNumber
    }

    // Fold the SuperSpeed and USB 2.0 nodes of one physical port together.
    //
    // Neither node dominates: link errors are a SuperSpeed concept, while a USB
    // 2.0 device only ever bumps the USB 2.0 node's connect count. Taking the
    // higher of each counter lets one port report everything that happened to
    // it. Never sum them, since both nodes count most connections.
    static func merged(_ a: RawPortStats, _ b: RawPortStats) -> RawPortStats {
        RawPortStats(
            portNumber: a.portNumber,
            connectCount: max(a.connectCount, b.connectCount),
            overcurrentCount: max(a.overcurrentCount, b.overcurrentCount),
            enumerationFailureCount: max(a.enumerationFailureCount, b.enumerationFailureCount),
            addressFailureCount: max(a.addressFailureCount, b.addressFailureCount),
            linkErrorCount: max(a.linkErrorCount, b.linkErrorCount),
            remoteWakeCount: max(a.remoteWakeCount, b.remoteWakeCount)
        )
    }
}
