import Foundation
import IOKit
import WhatPortCore

// Reads the negotiated USB-PD power contract from IOPortFeaturePowerSource.
//
// Each port that receives power (MagSafe, USB-C acting as sink) has an
// IOPortFeaturePowerSource child with a "WinningPowerSourceOption" dict
// showing the selected PDO: max watts, voltage, and current.
//
// MagSafe ports don't have WinningPowerSourceOption. They do have
// PowerSourceOptions (an array of available PDOs). We fall back to
// the highest-power PDO in that array.
//
// We use this for MagSafe because PowerOutDetails only tracks power
// the laptop delivers OUT. MagSafe power comes IN, so it needs a
// different data source.

public struct RawChargerData: Sendable {
    public let portType: String   // "MagSafe 3", "USB-C", etc.
    public let portNumber: Int
    public let maxWatts: Int      // milliwatts, 0 when the node carries no PDO
    public let voltage: Int       // millivolts
    public let maxCurrent: Int    // milliamps
    // True when the PDO came from WinningPowerSourceOption (the contract the
    // system actually selected) rather than the highest-PDO fallback.
    public let hasWinningContract: Bool

    // The domain-layer form. One conversion, used by the snapshot adapter and
    // by the SMC contract read gate, so neither can describe a charger node
    // differently from the other.
    public func toChargerInput() -> ChargerInput {
        ChargerInput(
            portType: portType,
            portNumber: portNumber,
            maxWatts: maxWatts,
            voltage: voltage,
            maxCurrent: maxCurrent,
            hasWinningContract: hasWinningContract
        )
    }
}

public enum ChargerReader {
    public static func readAll() -> [RawChargerData] {
        var results: [RawChargerData] = []

        withMatchingServices(className: "IOPortFeaturePowerSource") { service in
            guard let props = ioProperties(service) else { return }

            // Only read USB-PD sources (skip Brick ID, TypeC fallback, etc.)
            let name = ioString(props["PowerSourceName"])
            guard name == "USB-PD" else { return }

            let portType = ioString(props["ParentPortTypeDescription"])
            let portNumber = ioInt(props["ParentBuiltInPortNumber"])

            // Try WinningPowerSourceOption first (the PDO the system selected).
            // USB-C ports have this, MagSafe does not always.
            var pdo = ioDictionary(props["WinningPowerSourceOption"])
            let hasWinningContract = !pdo.isEmpty

            // Fallback: pick the highest-power PDO from PowerSourceOptions.
            // MagSafe exposes the array of available PDOs but not which one
            // was selected, so we take the max-wattage entry as the best
            // approximation of the negotiated contract.
            if pdo.isEmpty {
                pdo = highestPDO(from: ioArray(props["PowerSourceOptions"]))
            }

            let maxWatts = ioInt(pdo["Max Power (mW)"])

            // A node with no usable PDO is still reported, with maxWatts 0.
            // Callers that attribute power filter on maxWatts > 0; the reason
            // this entry exists at all is that "macOS published a node here"
            // and "macOS published nothing here" are different facts, and the
            // SMC contract fallback (which only fires when macOS published
            // nothing) cannot tell them apart otherwise.
            results.append(RawChargerData(
                portType: portType,
                portNumber: portNumber,
                maxWatts: maxWatts,
                voltage: ioInt(pdo["Voltage (mV)"]),
                maxCurrent: ioInt(pdo["Max Current (mA)"]),
                hasWinningContract: hasWinningContract && maxWatts > 0
            ))
        }

        return results
    }

    // Finds the PDO with the highest Max Power from an array of option dicts.
    private static func highestPDO(from options: [Any]) -> [String: Any] {
        var best: [String: Any] = [:]
        var bestWatts = 0
        for option in options {
            let dict = ioDictionary(option)
            let watts = ioInt(dict["Max Power (mW)"])
            if watts > bestWatts {
                bestWatts = watts
                best = dict
            }
        }
        return best
    }
}
