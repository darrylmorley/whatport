import Foundation
import WhatPortCore

// The contract between IOKit and domain layers.
// The domain layer depends on this protocol, never on concrete IOKit calls.

public protocol PortDataSource: Sendable {
    func observePortUpdates() -> AsyncStream<PortSnapshot>
    // Decoded IOAccessoryManager lifecycle events (attach, negotiating,
    // contract established, transport ready), delivered as they happen
    // rather than folded into a snapshot. See RawPortLifecycleEvent.
    func observeLifecycleEvents() -> AsyncStream<RawPortLifecycleEvent>
    func start() async
    func stop()
}

// A complete, immutable snapshot of all port state at a point in time.
// The IOKit layer produces one of these on every notification or poll tick.
public struct PortSnapshot: Sendable {
    public let timestamp: Date
    public let hpmPorts: [RawHPMPort]
    public let phyData: [RawPhyData]
    public let thunderboltData: [RawThunderboltData]
    public let powerData: [RawPowerData]
    public let ccData: [RawCCData]
    public let chargerData: [RawChargerData]
    public let chargingPower: RawChargingPower?
    public let chargerIdentity: RawChargerIdentity?
    public let deviceData: [RawDeviceInfo]
    public let displayData: [RawDisplayInfo]
    public let portStatsData: [RawPortStats]
    // USB-PD port-controller lifetime reliability counters, keyed positionally
    // (see PDReliabilityReader). USB-C only; empty on machines without a
    // PortControllerInfo array (Mac Studio class desktops).
    public let pdReliabilityData: [RawPDReliability]
    public let powerMeteringAvailable: Bool
    // Live transport state from IOPortTransportState* services
    public let usb3Transport: [RawUSB3TransportState]
    public let dpTransport: [RawDPTransportState]
    public let cioTransport: [RawCIOTransportState]
    // SMC per-port power-OUT channels (desktop power path), joined by UUID.
    public let smcPortPower: [RawSMCPortPower]
    // SMC per-port charging contracts (power IN), joined by the same UUID.
    // Only read while a charger is attached; empty otherwise.
    public let smcPortContracts: [RawSMCPortContract]
    // Total system DC-in (wall) power from the SMC, read once per snapshot.
    // combineChargingPower already folds this into chargingPower when a
    // battery controller is present; this is the same read kept available for
    // desktops, which have no battery controller and so no chargingPower at
    // all despite genuinely drawing wall power.
    public let smcSystemPower: RawSMCSystemPower?
    // Machine-wide Thunderbolt/XHCI controller power state. Reader-only for
    // now: see ControllerPowerReader for the corpus evidence and why the
    // occupancy-confidence logic that will consume this is a separate PR.
    public let controllerPower: RawControllerPower?

    public init(
        timestamp: Date = .now,
        hpmPorts: [RawHPMPort] = [],
        phyData: [RawPhyData] = [],
        thunderboltData: [RawThunderboltData] = [],
        powerData: [RawPowerData] = [],
        ccData: [RawCCData] = [],
        chargerData: [RawChargerData] = [],
        chargingPower: RawChargingPower? = nil,
        chargerIdentity: RawChargerIdentity? = nil,
        deviceData: [RawDeviceInfo] = [],
        displayData: [RawDisplayInfo] = [],
        portStatsData: [RawPortStats] = [],
        pdReliabilityData: [RawPDReliability] = [],
        powerMeteringAvailable: Bool = false,
        usb3Transport: [RawUSB3TransportState] = [],
        dpTransport: [RawDPTransportState] = [],
        cioTransport: [RawCIOTransportState] = [],
        smcPortPower: [RawSMCPortPower] = [],
        smcPortContracts: [RawSMCPortContract] = [],
        smcSystemPower: RawSMCSystemPower? = nil,
        controllerPower: RawControllerPower? = nil
    ) {
        self.timestamp = timestamp
        self.hpmPorts = hpmPorts
        self.phyData = phyData
        self.thunderboltData = thunderboltData
        self.powerData = powerData
        self.ccData = ccData
        self.chargerData = chargerData
        self.chargingPower = chargingPower
        self.chargerIdentity = chargerIdentity
        self.deviceData = deviceData
        self.displayData = displayData
        self.portStatsData = portStatsData
        self.pdReliabilityData = pdReliabilityData
        self.powerMeteringAvailable = powerMeteringAvailable
        self.usb3Transport = usb3Transport
        self.dpTransport = dpTransport
        self.cioTransport = cioTransport
        self.smcPortPower = smcPortPower
        self.smcPortContracts = smcPortContracts
        self.smcSystemPower = smcSystemPower
        self.controllerPower = controllerPower
    }
}

// One-shot reader that produces a single snapshot from current IOKit state.
// Used for initial load and on-demand refresh. Notifications and polling
// are added in Chunk 4.
public enum SnapshotReader {
    // One-shot entry point (initial load, on-demand refresh). Uses a throwaway
    // SMC reader whose connection closes on deinit. The polling data source
    // passes a persisted reader via the overload below instead.
    public static func takeSnapshot() -> PortSnapshot {
        takeSnapshot(smc: SMCPowerReader())
    }

    public static func takeSnapshot(smc: SMCPowerReader) -> PortSnapshot {
        // Read the SMC once and reuse for the per-port channels, the system DC-in
        // power, and the power-metering-available flag.
        let smcPortPower = smc.readPortPowerChannels()

        // One read of the SMC DC-in rails, shared by two consumers: the
        // laptop charging-power path below (which discards it on desktops,
        // no battery controller to combine it with) and smcSystemPower on
        // the snapshot itself, which desktops can still read directly.
        let smcSystemPower = smc.readSystemPowerInput()

        // Charger power-IN: the battery telemetry is the baseline (and gates on a
        // charger being connected), but the SMC DC-in rails are the live source.
        // AppleSmartBattery.SystemPowerIn freezes under load just like
        // PowerOutDetails, so prefer the SMC where it's available.
        let chargingPower = combineChargingPower(
            battery: PowerReader.readChargingPower(),
            smc: smcSystemPower
        )

        // Per-port metering is available if the battery exposes PowerOutDetails
        // (laptops) OR the SMC exposes power channels (desktops).
        let powerMeteringAvailable =
            PowerReader.isPowerMeteringAvailable() || !smcPortPower.isEmpty

        let chargerData = ChargerReader.readAll()

        // Per-port charging contracts, for the machines where macOS publishes
        // no USB-C power-source node (M1 Pro / Max / Ultra).
        //
        // Two gates, because this read is not cheap: each populated channel
        // costs five key reads, and every key read is two driver calls (size
        // and type first, then the value), so a fully populated four-channel
        // machine pays 40 round trips every second. A charger must be attached
        // (chargingPower is non-nil only then), AND macOS must not already be
        // describing the charge itself.
        //
        // The second condition calls the same function the attribution layer
        // uses rather than restating it, so this cannot end up reading data
        // that layer is certain to throw away.
        let smcPortContracts = (chargingPower == nil
            || SMCContractAttribution.macOSDescribesCharging(
                chargerNodes: chargerData.map { $0.toChargerInput() }))
            ? []
            : smc.readPortContracts()

        return PortSnapshot(
            timestamp: .now,
            hpmPorts: HPMReader.readAll(),
            phyData: PhyReader.readAll(),
            thunderboltData: ThunderboltReader.readAll(),
            powerData: PowerReader.readAll(),
            ccData: CCReader.readAll(),
            chargerData: chargerData,
            chargingPower: chargingPower,
            chargerIdentity: PowerReader.readChargerIdentity(),
            deviceData: DeviceReader.readUSBDevices(),
            displayData: DisplayReader.readDisplays(),
            portStatsData: PortStatsReader.readAll(),
            pdReliabilityData: PDReliabilityReader.readAll(),
            powerMeteringAvailable: powerMeteringAvailable,
            usb3Transport: TransportStateReader.readUSB3(),
            dpTransport: TransportStateReader.readDisplayPort(),
            cioTransport: TransportStateReader.readCIO(),
            smcPortPower: smcPortPower,
            smcPortContracts: smcPortContracts,
            smcSystemPower: smcSystemPower,
            controllerPower: ControllerPowerReader.readAll()
        )
    }

    // Combines battery telemetry with the live SMC DC-in rails. The battery
    // value being non-nil means a charger is connected (PowerReader gates on
    // ExternalConnected); when it is, the SMC's voltage/current/watts replace the
    // frozen battery figures while the battery's charging state is kept. Falls
    // back to the battery telemetry when the SMC rails aren't present.
    private static func combineChargingPower(
        battery: RawChargingPower?,
        smc: RawSMCSystemPower?
    ) -> RawChargingPower? {
        guard let battery else { return nil }
        // Fall back to the battery telemetry when the SMC rails read zero: they
        // are momentarily 0 during USB-PD negotiation and just after wake, and
        // overriding a real battery figure with 0 W would flash "0 W in".
        guard let smc, smc.watts > 0 else { return battery }
        return RawChargingPower(
            systemPowerIn: Int((smc.watts * 1000).rounded()),
            systemVoltageIn: Int((smc.volts * 1000).rounded()),
            systemCurrentIn: Int((smc.amps * 1000).rounded()),
            isCharging: battery.isCharging,
            fullyCharged: battery.fullyCharged,
            notChargingReason: battery.notChargingReason
        )
    }
}
