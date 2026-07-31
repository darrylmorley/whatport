import Foundation
import IOKit

// Reads the physical USB-C / MagSafe port roster from the HPM port-controller
// layer. This is the authoritative list of physical ports: each entry carries
// a stable UUID (read from the HPM controller ancestor) that uniquely
// identifies the port, even when MagSafe and USB-C share the same "@N" number.
//
// The port-interface class differs by chip generation (AppleTCControllerType10
// on M1 and M2, AppleHPMInterfaceType10 on M3 and later, and so on), so we match
// their shared base class IOAccessoryManager and let IOKit walk the hierarchy.
// Naming the concrete classes instead would fail silently and completely on any
// new one: no service matches, the roster falls back to Thunderbolt socket IDs,
// and every port loses its UUID, health counters, liquid detection and transport
// lists, with nothing logged and nothing visibly broken. That has already
// happened once, when A18 Pro machines arrived with AppleHPMInterfaceType18.
//
// Each real port node is named "Port-USB-C@N" / "Port-MagSafe 3@N" and has a
// "PortTypeDescription" property. There can be more interface instances than
// physical ports (e.g. internal DRD nodes), so we filter to real connectors.
// That filter is what does the selecting; across 780 Apple Silicon machines in
// the probe corpus, IOAccessoryManager returned 2693 services and every one of
// them was a port node (2130 USB-C, 555 MagSafe 3, 6 Inductive, 2 HDMI).
//
// The UUID is an in-session join key only. It is never shown in the UI.

public struct RawHPMPort: Sendable {
    public let uuid: String      // HPM controller UUID (raw, with dashes)
    public let portNumber: Int   // the "@N" suffix
    public let portType: String  // "USB-C", "MagSafe 3", etc.
    public let serviceName: String
    public let overcurrentCount: Int
    public let plugEventCount: Int
    public let connectionCount: Int
    public let authorizationStatus: String
    public let ldcmStatus: String
    // Transports the controller has actually set up for the current connection
    // (e.g. ["CC", "USB2", "USB3", "DP"]), and any it negotiated then blocked.
    public let provisionedTransports: [String]
    public let unauthorizedTransports: [String]
    // Liquid detection (LDCM). liquidDetected is the definitive wet-port flag;
    // mitigationsActive means macOS has restricted the port to limit damage.
    public let liquidDetected: Bool
    public let mitigationsActive: Bool

    public var isMagSafe: Bool {
        portType.lowercased().contains("magsafe")
    }
}

public enum HPMReader {
    public static func readAll() -> [RawHPMPort] {
        var results: [RawHPMPort] = []
        var seen = Set<String>()  // dedup by "portType:portNumber"

        withMatchingServices(className: "IOAccessoryManager") { service in
            guard let name = ioEntryName(service), name.hasPrefix("Port-") else { return }

            // Real physical ports report a USB-C or MagSafe port type. This is
            // what excludes the HDMI and Inductive nodes that a few machines
            // publish under the same base class.
            let portType = ioString(ioProperty(service, key: "PortTypeDescription"))
            let isRealPort = portType == "USB-C" || portType.hasPrefix("MagSafe")
            guard isRealPort else { return }

            // Reject a port that says it is not built into this Mac. Note the
            // shape: only an explicit "false" rejects. Every port node in the
            // corpus publishes BuiltIn = true (2685 of 2685), but treating a
            // missing key as "not built in" would empty the roster on any
            // machine that stopped publishing it, which is the one failure this
            // reader must never have.
            if let builtIn = ioProperty(service, key: "BuiltIn"), !ioBool(builtIn) { return }

            // The "@N" number is the location in the service plane, not
            // part of the registry name (the name is just "Port-USB-C").
            guard let portNumber = ioLocationInPlaneInt(service) else { return }

            // The UUID lives on the HPM controller ancestor, not here.
            guard let uuid = ioHPMControllerUUID(service), !uuid.isEmpty else { return }

            let key = "\(portType):\(portNumber)"
            guard !seen.contains(key) else { return }
            seen.insert(key)

            let overcurrentCount = ioInt(ioProperty(service, key: "Overcurrent Count"))
            let plugEventCount = ioInt(ioProperty(service, key: "Plug Event Count"))
            let connectionCount = ioInt(ioProperty(service, key: "ConnectionCount"))
            let authorizationStatus = ioString(ioProperty(service, key: "UserAuthorizationStatusDescription"))
            let ldcmStatus = ioString(ioProperty(service, key: "LDCM_MeasurementStatusDescription"))
            let provisioned = ioStringArray(ioProperty(service, key: "TransportsProvisioned"))
            let unauthorized = ioStringArray(ioProperty(service, key: "TransportsUnauthorized"))
            let liquidDetected = ioBool(ioProperty(service, key: "LDCM_LiquidDetected"))
            let mitigationsActive = ioBool(ioProperty(service, key: "LDCM_MitigationsEnabled"))

            results.append(RawHPMPort(
                uuid: uuid,
                portNumber: portNumber,
                portType: portType,
                serviceName: name,
                overcurrentCount: overcurrentCount,
                plugEventCount: plugEventCount,
                connectionCount: connectionCount,
                authorizationStatus: authorizationStatus,
                ldcmStatus: ldcmStatus,
                provisionedTransports: provisioned,
                unauthorizedTransports: unauthorized,
                liquidDetected: liquidDetected,
                mitigationsActive: mitigationsActive
            ))
        }

        // Sorted on port number and then type, because MagSafe and USB-C can
        // share a number. Sorting on the number alone leaves their relative
        // order to sort's own discretion, and the input is now in registry
        // order rather than a fixed sequence of class matches.
        return results.sorted {
            ($0.portNumber, $0.portType) < ($1.portNumber, $1.portType)
        }
    }
}
