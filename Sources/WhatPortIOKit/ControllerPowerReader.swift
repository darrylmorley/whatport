import Foundation
import IOKit

// Reads machine-wide Thunderbolt and USB XHCI controller power state from
// IOPowerManagement.
//
// This is the reader-only half of a future occupancy-confidence feature. It
// deliberately produces no per-port data and drives no behaviour: the
// corpus evidence below is machine-wide, and the hold/hysteresis logic that
// will turn it into something a view can show is a separate, later PR.
//
// Corpus-verified: when every Thunderbolt controller on a machine reports
// IOPowerManagement CurrentPowerState == 0 (off), zero devices are attached
// (772/772 machines checked). Same holds for USB XHCI controllers (186/186).
// The granularity of that evidence is machine-wide, not per-port, so the
// output here is two machine-wide booleans, not a per-port map.
//
// Matches the superclasses IOThunderboltController and AppleUSBHostController
// (not the chip-specific subclasses like IOThunderboltControllerType5 or
// AppleT8132USBXHCI) so this works across M-series generations the same way
// PhyReader matches AppleTypeCPhy rather than the per-chip subclass.
//
// Deliberately does not read ChildrenPowerState: the research this feature
// is based on found it unreliable on Thunderbolt controllers.

// Machine-wide controller power-state summary, read once per snapshot.
//
// anyThunderboltControllerAwake and anyXHCIControllerAwake are Optional so
// "no controller of this family was matched at all" can be told apart from
// "matched, and every one of them is off". Intel Macs publish Thunderbolt
// controllers under different class names than the Apple Silicon subclasses
// IOThunderboltController covers, so an unconditional false there would be a
// false "nothing attached" reading. nil means the question can't be answered
// on this machine; false means it was answered and the answer is "asleep".
//
// The counts are carried alongside since they fall out of the same walk for
// free, and are useful for future diagnostics without another registry pass.
public struct RawControllerPower: Sendable {
    public let anyThunderboltControllerAwake: Bool?
    public let anyXHCIControllerAwake: Bool?
    public let thunderboltControllerCount: Int
    public let xhciControllerCount: Int

    public init(
        anyThunderboltControllerAwake: Bool?,
        anyXHCIControllerAwake: Bool?,
        thunderboltControllerCount: Int = 0,
        xhciControllerCount: Int = 0
    ) {
        self.anyThunderboltControllerAwake = anyThunderboltControllerAwake
        self.anyXHCIControllerAwake = anyXHCIControllerAwake
        self.thunderboltControllerCount = thunderboltControllerCount
        self.xhciControllerCount = xhciControllerCount
    }
}

public enum ControllerPowerReader {
    public static func readAll() -> RawControllerPower {
        // Every matched service gets an entry, even when its properties can't
        // be read (nil state) -- dropping it here would make "matched but
        // unreadable" indistinguishable from "family not matched at all",
        // which parse()/anyAwake() rely on telling apart.
        var thunderboltStates: [Int?] = []
        withMatchingServices(className: "IOThunderboltController") { service in
            thunderboltStates.append(ioProperties(service).flatMap { currentPowerState(properties: $0) })
        }

        var xhciStates: [Int?] = []
        withMatchingServices(className: "AppleUSBHostController") { service in
            xhciStates.append(ioProperties(service).flatMap { currentPowerState(properties: $0) })
        }

        return parse(thunderboltStates: thunderboltStates, xhciStates: xhciStates)
    }

    // Read CurrentPowerState from one service's IOPowerManagement dict.
    // Returns nil when the dict or the key is missing (driver hasn't
    // published power management, or it isn't shaped as expected). Split out
    // from the walk so recorded/synthetic property dictionaries can be
    // replayed through it directly.
    static func currentPowerState(properties: [String: Any]) -> Int? {
        let pm = ioDictionary(properties["IOPowerManagement"])
        guard let raw = pm["CurrentPowerState"] else { return nil }
        return ioInt(raw)
    }

    // Combine the per-instance power states already read from the registry
    // walk into the machine-wide summary. Split out from the walk so
    // recorded/synthetic state lists can be replayed through it directly,
    // same pattern as the other readers' parse functions.
    static func parse(thunderboltStates: [Int?], xhciStates: [Int?]) -> RawControllerPower {
        RawControllerPower(
            anyThunderboltControllerAwake: anyAwake(thunderboltStates),
            anyXHCIControllerAwake: anyAwake(xhciStates),
            thunderboltControllerCount: thunderboltStates.count,
            xhciControllerCount: xhciStates.count
        )
    }

    // nil when no instance was matched at all. Otherwise true if any matched
    // instance reports a power state above 0; an instance with no readable
    // state counts as off rather than dropping out of the answer, since the
    // controller was still found.
    private static func anyAwake(_ states: [Int?]) -> Bool? {
        guard !states.isEmpty else { return nil }
        return states.contains { ($0 ?? 0) > 0 }
    }
}
