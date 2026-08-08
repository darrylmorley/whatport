import Foundation
import IOKit

// Reads per-port power delivery data from AppleSmartBattery.PowerOutDetails.
//
// PowerOutDetails is an array of dictionaries, one per port that is currently
// sourcing power. If no ports are sourcing power, the array may be empty or
// the key may be absent entirely.
//
// Power values use centiwatts (divide by 100 for watts), milliamps, and millivolts.
// This reader returns raw values; conversion happens in the domain layer.
//
// Important: PowerOutDetails does NOT fire IOKit notifications when it updates.
// It must be polled (every 2-5 seconds). This is handled in Chunk 4.

public struct RawPowerData: Sendable {
    public let portIndex: Int
    public let watts: Int
    public let current: Int
    public let adapterVoltage: Int
    public let configuredVoltage: Int
    public let configuredCurrent: Int
    public let pdPowerMW: Int
    public let filteredPower: Int
    public let vconnCurrent: Int
    public let vconnPower: Int
    public let vconnMaxCurrent: Int
    public let powerState: Int
}

// Live system-level charging power from PowerTelemetryData.
//
// PowerTelemetryData sits alongside PowerOutDetails on AppleSmartBattery.
// It provides real-time power flowing IN from the charger. The key fields:
//   SystemPowerIn  - total power drawn from the active charger (mW)
//   SystemVoltageIn - charger voltage at the input rail (mV)
//   SystemCurrentIn - current drawn from the charger (mA)
//
// Only one charger is active at a time (the "best adapter"). SystemPowerIn
// represents the live draw from that charger, split between system load
// and battery charging.
public struct RawChargingPower: Sendable {
    public let systemPowerIn: Int     // milliwatts, total input from charger
    public let systemVoltageIn: Int   // millivolts
    public let systemCurrentIn: Int   // milliamps
    public let isCharging: Bool       // battery is actively charging
    public let fullyCharged: Bool     // battery is full
    public let notChargingReason: Int // ChargerData.NotChargingReason bitfield
}

// One advertised PDO from the charger's USB-PD menu (UsbHvcMenu).
public struct RawChargerPDO: Sendable {
    public let voltageMV: Int
    public let currentMA: Int
}

// Charger / power-adapter identity from AppleSmartBattery.AdapterDetails.
// Apple adapters report Name + Manufacturer; third-party PD chargers usually
// only report a generic Description ("pd charger"). The UsbHvcMenu is the
// adapter's full advertised voltage/current menu.
public struct RawChargerIdentity: Sendable {
    public let name: String
    public let manufacturer: String
    public let description: String
    public let maxWatts: Int          // watts
    public let pdos: [RawChargerPDO]
}

public enum PowerReader {
    public static func readAll() -> [RawPowerData] {
        var results: [RawPowerData] = []

        // AppleSmartBattery is a single service instance.
        withMatchingServices(className: "AppleSmartBattery") { service in
            // PowerOutDetails is an array property on the battery service.
            guard let raw = ioProperty(service, key: "PowerOutDetails") else { return }
            let entries = ioArray(raw)

            for entry in entries {
                let dict = ioDictionary(entry)
                let data = RawPowerData(
                    portIndex: ioInt(dict["PortIndex"]),
                    watts: ioInt(dict["Watts"]),
                    current: ioInt(dict["Current"]),
                    adapterVoltage: ioInt(dict["AdapterVoltage"]),
                    configuredVoltage: ioInt(dict["ConfiguredVoltage"]),
                    configuredCurrent: ioInt(dict["ConfiguredCurrent"]),
                    pdPowerMW: ioInt(dict["PDPowermW"]),
                    filteredPower: ioInt(dict["FilteredPower"]),
                    vconnCurrent: ioInt(dict["VConnCurrent"]),
                    vconnPower: ioInt(dict["VConnPower"]),
                    vconnMaxCurrent: ioInt(dict["VConnMaxCurrent"]),
                    powerState: ioInt(dict["PowerState"])
                )
                results.append(data)
            }
        }

        return results
    }

    // Read live charging power and battery state from AppleSmartBattery.
    // PowerTelemetryData provides real-time input power.
    // IsCharging / FullyCharged are top-level properties on the same service.
    // Returns nil only if AppleSmartBattery is absent (unlikely on laptops).
    public static func readChargingPower() -> RawChargingPower? {
        var result: RawChargingPower?

        withMatchingServices(className: "AppleSmartBattery") { service in
            guard let props = ioProperties(service) else { return }
            // Only overwrite `result` on a successful parse. AppleSmartBattery
            // is a single service instance in practice, but the callback still
            // runs once per matching service; if a later match parsed to nil
            // it must not clobber a valid result an earlier match produced.
            if let parsed = parseChargingPower(properties: props) { result = parsed }
        }

        return result
    }

    // The charging-power rules, given one service's properties. Split out from
    // the registry walk so recorded properties from other Macs can be replayed
    // through it.
    //
    // Returns nil when no charger is connected at all.
    static func parseChargingPower(properties: [String: Any]) -> RawChargingPower? {
        let isCharging = ioBool(properties["IsCharging"])
        let fullyCharged = ioBool(properties["FullyCharged"])
        let externalConnected = ioBool(properties["ExternalConnected"])

        // No charger connected at all, nothing to report
        guard externalConnected else { return nil }

        let telemetry = ioDictionary(properties["PowerTelemetryData"])
        let powerIn = ioInt(telemetry["SystemPowerIn"])

        // NotChargingReason lives in the ChargerData dict, falling back to the
        // top level on machines that expose it there.
        let chargerData = ioDictionary(properties["ChargerData"])
        let notChargingReason = chargerData["NotChargingReason"] != nil
            ? ioInt(chargerData["NotChargingReason"])
            : ioInt(properties["NotChargingReason"])

        return RawChargingPower(
            systemPowerIn: powerIn,
            systemVoltageIn: ioInt(telemetry["SystemVoltageIn"]),
            systemCurrentIn: ioInt(telemetry["SystemCurrentIn"]),
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            notChargingReason: notChargingReason
        )
    }

    // Read the active charger's identity and advertised power menu from
    // AppleSmartBattery.AdapterDetails. Returns nil when no charger is
    // connected or on Macs without a battery controller (desktops).
    public static func readChargerIdentity() -> RawChargerIdentity? {
        var result: RawChargerIdentity?

        withMatchingServices(className: "AppleSmartBattery") { service in
            guard let props = ioProperties(service) else { return }
            // Same rule as readChargingPower above: a nil parse from a later
            // matching service must never overwrite a valid earlier result.
            if let parsed = parseChargerIdentity(properties: props) { result = parsed }
        }

        return result
    }

    // The charger-identity rules, given one service's properties. Split out
    // from the registry walk so recorded properties from other Macs can be
    // replayed through it.
    //
    // Returns nil when no charger is connected, or when AdapterDetails carries
    // neither a name/description nor a usable power menu.
    static func parseChargerIdentity(properties: [String: Any]) -> RawChargerIdentity? {
        guard ioBool(properties["ExternalConnected"]) else { return nil }

        let adapter = ioDictionary(properties["AdapterDetails"])
        guard !adapter.isEmpty else { return nil }

        let name = ioString(adapter["Name"])
        let description = ioString(adapter["Description"])
        let manufacturer = ioString(adapter["Manufacturer"])
        let watts = ioInt(adapter["Watts"])

        var pdos: [RawChargerPDO] = []
        for entry in ioArray(adapter["UsbHvcMenu"]) {
            let dict = ioDictionary(entry)
            let voltageMV = ioInt(dict["MaxVoltage"])
            let currentMA = ioInt(dict["MaxCurrent"])
            // Skip non-fixed-supply or malformed entries (zero current would
            // otherwise produce a 0 W PDO and a wattless menu summary).
            guard voltageMV > 0, currentMA > 0 else { continue }
            pdos.append(RawChargerPDO(voltageMV: voltageMV, currentMA: currentMA))
        }

        // Nothing worth surfacing if we have neither a name nor a menu.
        guard !name.isEmpty || !description.isEmpty || !pdos.isEmpty else { return nil }

        return RawChargerIdentity(
            name: name,
            manufacturer: manufacturer,
            description: description,
            maxWatts: watts,
            pdos: pdos
        )
    }

    // Check whether PowerOutDetails is available on this machine.
    // Desktop Macs and some older laptops don't have it.
    public static func isPowerMeteringAvailable() -> Bool {
        var available = false
        withMatchingServices(className: "AppleSmartBattery") { service in
            if ioProperty(service, key: "PowerOutDetails") != nil {
                available = true
            }
        }
        return available
    }
}
