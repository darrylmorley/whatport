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
        var parsed: [RawHPMPort] = []

        withMatchingServices(className: "IOAccessoryManager") { service in
            guard let properties = ioProperties(service) else { return }

            // The "@N" number is the location in the service plane, not part of
            // the registry name (the name is just "Port-USB-C"), and the UUID
            // lives on the HPM controller ancestor. Both are gathered here
            // because they are outside this service's own properties.
            let port = parse(
                properties: properties,
                entryName: ioEntryName(service),
                portNumber: ioLocationInPlaneInt(service),
                controllerUUID: ioHPMControllerUUID(service)
            )
            guard let port else { return }
            parsed.append(port)
        }

        return roster(from: parsed)
    }

    // Turns parsed ports into the roster: one entry per physical connector, in
    // a stable order.
    //
    // Separate from the walk so the corpus sweeps exercise the same
    // deduplication the app runs. They replay parse per recorded service, and
    // while this lived inside the walk they could not reach it at all: with
    // dedup disabled entirely, every sweep stayed green.
    static func roster(from ports: [RawHPMPort]) -> [RawHPMPort] {
        var seen = Set<String>()  // dedup by "portType:portNumber"
        var deduped: [RawHPMPort] = []

        for port in ports {
            let key = "\(port.portType):\(port.portNumber)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(port)
        }

        // Sorted on port number and then type, because MagSafe and USB-C can
        // share a number. Sorting on the number alone leaves their relative
        // order to sort's own discretion, and the input arrives in registry
        // order rather than a fixed sequence of class matches.
        return deduped.sorted {
            ($0.portNumber, $0.portType) < ($1.portNumber, $1.portType)
        }
    }

    // The port rules, given one service's properties plus the three values the
    // walk had to gather from elsewhere. Split out from the registry walk so
    // recorded properties from other Macs can be replayed through it.
    //
    // Returns nil for anything that is not a physical port on this Mac.
    static func parse(
        properties: [String: Any],
        entryName: String?,
        portNumber: Int?,
        controllerUUID: String?
    ) -> RawHPMPort? {
        guard let name = entryName, name.hasPrefix("Port-") else { return nil }

        // Real physical ports report a USB-C or MagSafe port type. This is
        // what excludes the HDMI and Inductive nodes that a few machines
        // publish under the same base class.
        let portType = ioString(properties["PortTypeDescription"])
        let isRealPort = portType == "USB-C" || portType.hasPrefix("MagSafe")
        guard isRealPort else { return nil }

        // Reject a port that says it is not built into this Mac. Note the
        // shape: only an explicit "false" rejects. Every port node in the
        // corpus publishes BuiltIn = true (2685 of 2685), but treating a
        // missing key as "not built in" would empty the roster on any
        // machine that stopped publishing it, which is the one failure this
        // reader must never have.
        if let builtIn = properties["BuiltIn"], !ioBool(builtIn) { return nil }

        guard let portNumber else { return nil }
        guard let uuid = controllerUUID, !uuid.isEmpty else { return nil }

        return RawHPMPort(
            uuid: uuid,
            portNumber: portNumber,
            portType: portType,
            serviceName: name,
            overcurrentCount: ioInt(properties["Overcurrent Count"]),
            plugEventCount: ioInt(properties["Plug Event Count"]),
            connectionCount: ioInt(properties["ConnectionCount"]),
            authorizationStatus: ioString(properties["UserAuthorizationStatusDescription"]),
            ldcmStatus: ioString(properties["LDCM_MeasurementStatusDescription"]),
            provisionedTransports: ioStringArray(properties["TransportsProvisioned"]),
            unauthorizedTransports: ioStringArray(properties["TransportsUnauthorized"]),
            liquidDetected: ioBool(properties["LDCM_LiquidDetected"]),
            mitigationsActive: ioBool(properties["LDCM_MitigationsEnabled"])
        )
    }
}
