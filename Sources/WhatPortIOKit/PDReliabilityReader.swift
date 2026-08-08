import Foundation
import IOKit

// Reads per-port-controller USB-PD reliability counters from
// AppleSmartBattery.PortControllerInfo.
//
// PortControllerInfo is an array of dictionaries, one per port-controller
// chip, carrying NO port identifier of its own. The join is ORDINAL, not
// positional-by-port-number: entry at array offset i corresponds to the
// (i+1)-th USB-C port when the machine's USB-C ports are sorted ascending
// by physical port number. On machines with contiguous USB-C port numbering
// (1..N) that happens to equal the old offset+1 == portNumber rule, but 24
// corpus machines number their USB-C ports non-contiguously (e.g. M5
// MacBook Pros with ports {1, 2, 4}), and there the old rule attributed
// counters to the wrong port or dropped them.
//
// Validated on 237/237 corpus machines with exactly one powered
// PortControllerInfo entry and exactly one active USB-C USB-PD source
// (probe 17): the ordinal rule matched the independently-reported charging
// port, including all 8 non-contiguous machines in that sample; contract
// wattage agreed 235/235 where comparable. Entry count equals the USB-C
// port count, or count+1 with a final MagSafe-controller entry (seen on
// 101/103 MagSafe-only-charging machines; the other 2 were a second live
// USB-C contract, not join errors) -- 0 violations of that count invariant
// across the whole corpus.
//
// The actual join (matching offsets to the machine's USB-C port roster, and
// failing closed on any other entry count) happens in PortManager.correlate,
// not here: this reader has no view of the port roster, only the raw array.
//
// Absent entirely on Mac Studio class desktops (no port-controller chips to
// report power delivery for): readAll() returns an empty array there. Some
// macOS builds publish a reduced key set, so every field is read with ioInt's
// zero-default tolerance rather than failing the whole entry.
public struct RawPDReliability: Sendable {
    public let entryOffset: Int   // 0-based array offset; carries no port identity of its own
    public let attachCount: Int
    public let detachCount: Int
    public let hardResetCount: Int
    public let irqHardResetCount: Int
    public let shortDetectCount: Int
    public let dataRoleSwapFailCount: Int
    public let powerRoleSwapFailCount: Int
    public let i2cErrorCount: Int
}

public enum PDReliabilityReader {
    public static func readAll() -> [RawPDReliability] {
        var results: [RawPDReliability] = []

        // AppleSmartBattery is a singleton service; AppleSmartBatteryManager
        // republishes near-identical keys under a different class, so
        // matching by class already scopes this away from it. Still, only
        // stop looking once a matching service has actually produced a
        // non-empty parsed entries array (defensive: a hypothetical second
        // matching service with real data must not be skipped just because
        // an earlier, empty match already claimed the roster).
        var handled = false
        withMatchingServices(className: "AppleSmartBattery") { service in
            guard !handled else { return }

            guard let raw = ioProperty(service, key: "PortControllerInfo") else { return }
            let entries = ioArray(raw)
            guard !entries.isEmpty else { return }

            handled = true
            for (offset, entry) in entries.enumerated() {
                results.append(parse(entry: ioDictionary(entry), entryOffset: offset))
            }
        }

        return results
    }

    // One PortControllerInfo entry's counters, given its already-decoded
    // dictionary and its 0-based array offset. Split out from the registry
    // walk so recorded dictionaries from other Macs can be replayed through
    // it.
    static func parse(entry: [String: Any], entryOffset: Int) -> RawPDReliability {
        RawPDReliability(
            entryOffset: entryOffset,
            attachCount: ioInt(entry["PortControllerAttachCount"]),
            detachCount: ioInt(entry["PortControllerDetachCount"]),
            hardResetCount: ioInt(entry["PortControllerHardResetCount"]),
            irqHardResetCount: ioInt(entry["PortControllerIrqCntHrdRst"]),
            shortDetectCount: ioInt(entry["PortControllerShortDetectCount"]),
            dataRoleSwapFailCount: ioInt(entry["PortControllerDataRoleSwapFailCount"]),
            powerRoleSwapFailCount: ioInt(entry["PortControllerPwrRoleSwapFailCount"]),
            i2cErrorCount: ioInt(entry["PortControllerI2cErrCount"])
        )
    }
}
