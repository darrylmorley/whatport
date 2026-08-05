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
        // Dedup key: (portNumber, portType) since different types share numbers
        var seen = Set<String>()

        withMatchingServices(className: "IOPortTransportStateCC") { service in
            guard let props = ioProperties(service) else { return }

            let portNumber = ioInt(props["ParentBuiltInPortNumber"])
            let portType = ioString(props["ParentPortTypeDescription"])
            let active = ioBool(props["Active"])

            let key = "\(portNumber):\(portType)"
            guard portNumber > 0, !seen.contains(key) else { return }
            seen.insert(key)

            // Read cable identity from SOP' child service.
            // SOP' represents the cable plug. Its Metadata dict has
            // "Product Type Description" (Passive/Active Cable) and
            // Specification Revision (USB PD rev).
            let cable = readCableIdentity(ccService: service)

            results.append(RawCCData(
                portNumber: portNumber,
                portType: portType,
                active: active,
                cableProductType: cable.productType,
                cablePDRevision: cable.pdRevision
            ))
        }

        return results.sorted { $0.portNumber < $1.portNumber }
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

            let componentName = ioString(childProps["ComponentName"])
            guard componentName == "SOP'" else { continue }

            let metadata = ioDictionary(childProps["Metadata"])
            let productType = ioString(metadata["Product Type Description"])
            let pdRevision = ioInt(childProps["Specification Revision"])

            if !productType.isEmpty {
                return [(productType, pdRevision)]
            }
        }

        return []
    }
}
