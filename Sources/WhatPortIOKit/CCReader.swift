import Foundation
import IOKit
import WhatPortCore

// Reads CC (communication channel) connection state from all port types.
//
// Each port (USB-C, MagSafe, etc.) has an IOPortTransportStateCC service.
// Its "Active" property indicates whether anything is physically connected.
//
// ParentBuiltInPortNumber maps each CC service to its physical port, but
// different port types can share the same number (e.g. MagSafe and USB-C
// port 1 both report ParentBuiltInPortNumber = 1). We use
// ParentPortTypeDescription to distinguish them.

public struct RawCCData: Sendable {
    public let portNumber: Int
    public let portType: String   // "USB-C", "MagSafe 3", etc.
    public let active: Bool
    // Cable identity from SOP' child service (when a cable is detected)
    public let cableProductType: String  // "Passive Cable", "Active Cable", ""
    public let cablePDRevision: Int      // USB PD Specification Revision (1, 2, 3)
}

public enum CCReader {
    public static func readAll() -> [RawCCData] {
        var results: [RawCCData] = []

        withMatchingServices(className: "IOPortTransportStateCC") { service in
            guard let props = ioProperties(service) else { return }

            // Read cable identity from SOP' child service.
            // SOP' represents the cable plug. Its Metadata dict has
            // "Product Type Description" (Passive/Active Cable) and
            // Specification Revision (USB PD rev).
            let cable = readCableIdentity(ccService: service)

            guard let entry = parse(
                properties: props,
                cableProductType: cable.productType,
                cablePDRevision: cable.pdRevision
            ) else { return }
            results.append(entry)
        }

        return dedupedAndSorted(results)
    }

    // The dedup/ordering rule, given the raw entries the registry walk (or a
    // replay builder) produced. Split out from readAll so a replayed
    // snapshot goes through exactly the same collapsing production does,
    // rather than the replay being able to construct a shape (two entries
    // for one port/type pair, or unsorted) production's registry walk could
    // never hand to the domain layer.
    //
    // Dedup key is (portNumber, portType): different port types can share
    // the same built-in port number (e.g. MagSafe and USB-C port 1 both
    // report ParentBuiltInPortNumber = 1). The first entry for a given key
    // wins, matching the registry walk's own first-match-wins order.
    static func dedupedAndSorted(_ entries: [RawCCData]) -> [RawCCData] {
        var seen = Set<String>()
        var deduped: [RawCCData] = []
        deduped.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.portNumber > 0 else { continue }
            let key = "\(entry.portNumber):\(entry.portType)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(entry)
        }

        return deduped.sorted { $0.portNumber < $1.portNumber }
    }

    // The port rules, given one service's properties plus the cable identity
    // the child walk found (or empty, when there is no cable / no SOP' child).
    // Split out from the registry walk so recorded properties from other Macs
    // can be replayed through it.
    //
    // Returns nil for a service with no usable port number.
    static func parse(
        properties: [String: Any],
        cableProductType: String,
        cablePDRevision: Int
    ) -> RawCCData? {
        let portNumber = ioInt(properties["ParentBuiltInPortNumber"])
        guard portNumber > 0 else { return nil }

        return RawCCData(
            portNumber: portNumber,
            portType: ioString(properties["ParentPortTypeDescription"]),
            active: ioBool(properties["Active"]),
            cableProductType: cableProductType,
            cablePDRevision: cablePDRevision
        )
    }

    // Walk child services of a CC entry looking for SOP' (cable identity).
    // The SOP' service has Metadata with cable VDOs decoded by the kernel.
    //
    // The child iterator can be invalidated mid-walk by the same registry
    // mutation that connect/disconnect events trigger, which makes
    // IOIteratorNext return 0 as if the walk had simply finished. Retrying
    // through IteratorWalkRetry catches that instead of silently missing a
    // cable that was actually there.
    private static func readCableIdentity(
        ccService: io_service_t
    ) -> (productType: String, pdRevision: Int) {
        var iter: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(ccService, kIOServicePlane, &iter)
        guard kr == KERN_SUCCESS else { return ("", 0) }
        defer { IOObjectRelease(iter) }

        let matches = IteratorWalkRetry.retry(
            isValid: { IOIteratorIsValid(iter) != 0 },
            reset: { IOIteratorReset(iter) },
            walk: { walkChildrenForCableIdentity(iter) }
        )

        return matches.first ?? ("", 0)
    }

    // Drain a child iterator looking for the SOP' cable-identity service.
    // Stops at the first match found (there is at most one).
    private static func walkChildrenForCableIdentity(
        _ iter: io_iterator_t
    ) -> [(productType: String, pdRevision: Int)] {
        while case let child = IOIteratorNext(iter), child != 0 {
            defer { IOObjectRelease(child) }
            guard let childProps = ioProperties(child) else { continue }
            guard let identity = cableIdentity(fromSOPProperties: childProps) else { continue }
            return [identity]
        }

        return []
    }

    // The cable-identity rule, given one SOP' child's properties. Split out
    // from the registry walk so recorded properties from other Macs can be
    // replayed through it, same as parse(properties:cableProductType:
    // cablePDRevision:) above.
    //
    // Returns nil for a child that is not the SOP' cable-plug service, or
    // that carries no product type.
    static func cableIdentity(
        fromSOPProperties properties: [String: Any]
    ) -> (productType: String, pdRevision: Int)? {
        let componentName = ioString(properties["ComponentName"])
        guard componentName == "SOP'" else { return nil }

        let metadata = ioDictionary(properties["Metadata"])
        let productType = ioString(metadata["Product Type Description"])
        guard !productType.isEmpty else { return nil }

        return (productType, ioInt(properties["Specification Revision"]))
    }
}
