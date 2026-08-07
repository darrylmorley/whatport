import Foundation

// PortManager is the central domain object. It holds the current state of all
// ports and updates when new IOKit snapshots arrive.
//
// @Observable is Swift 5.9's Observation framework. It replaces the older
// ObservableObject + @Published pattern. SwiftUI views that read properties
// on an @Observable object automatically re-render when those properties change.
// No @Published wrappers needed - the macro handles it.
@Observable
public final class PortManager: @unchecked Sendable {
    public private(set) var ports: [PortState] = []
    public private(set) var portCount: Int = 0
    public private(set) var powerMeteringAvailable: Bool = false

    // Battery / charging state (system-level, not per-port)
    public private(set) var isCharging: Bool = false
    public private(set) var fullyCharged: Bool = false
    // The Mac's charging status when a charger is connected (nil on battery or
    // on a Mac with no battery controller). Answers "why isn't it charging?".
    public private(set) var chargingStatus: ChargingStatus?
    // Total wall power the Mac itself is drawing, straight from the SMC.
    // System-level like isCharging/chargingStatus, and set directly from the
    // snapshot rather than through correlate(): it isn't attributed to any
    // one port. Present on desktops too, where chargingStatus is always nil
    // (no battery controller) but the SMC still reports real wall draw.
    public private(set) var systemWallPowerWatts: Double?

    // Machine-wide Thunderbolt/XHCI controller power state, set directly from
    // the snapshot like systemWallPowerWatts, bypassing correlate() (this
    // isn't per-port data either). Nothing reads this yet: it is the
    // reader-only half of a future occupancy-confidence feature landing ahead
    // of the hold/hysteresis logic that will consume it, so the data path is
    // proven before that logic exists.
    public private(set) var controllerPower: ControllerPowerInput?

    // Power history for sparkline graphs (per port ID)
    public private(set) var powerHistory: [Int: [PowerSample]] = [:]

    // Per-port connection-lifecycle phase, derived from IOAccessoryManager
    // signals (see PortLifecycleStateMachine). Absence of an entry means
    // "connected" (or simply idle): there is no tracked phase for it.
    public private(set) var lifecyclePhases: [Int: PortLifecyclePhase] = [:]
    private var lifecycleMachine = PortLifecycleStateMachine()

    // 60 samples at the 1s poll interval = the 60s window the sparkline labels.
    private let maxPowerSamples = 60

    // Port recorder: stores long-running history and events.
    // When nil, recording is disabled (no-op). Set by the Pro plugin
    // via PluginRegistry's portManagerHooks.
    public var recorder: (any PortRecorder)?

    public init() {}

    // Called by the IOKit layer (or mock) whenever new data arrives.
    // This is the single entry point for all state updates.
    public func applySnapshot(_ snapshot: PortManagerSnapshot) {
        powerMeteringAvailable = snapshot.powerMeteringAvailable
        isCharging = snapshot.chargingPower?.isCharging ?? false
        fullyCharged = snapshot.chargingPower?.fullyCharged ?? false
        // chargingPower is non-nil only when a charger is connected (the reader
        // gates on ExternalConnected), so nil here means on battery / no battery.
        chargingStatus = snapshot.chargingPower.map {
            ChargingStatus(
                isCharging: $0.isCharging,
                fullyCharged: $0.fullyCharged,
                notChargingReason: $0.notChargingReason
            )
        }
        systemWallPowerWatts = snapshot.systemPower?.watts
        controllerPower = snapshot.controllerPower

        let correlated = correlate(
            hpmPorts: snapshot.hpmPorts,
            phyData: snapshot.phyData,
            tbData: snapshot.tbData,
            powerData: snapshot.powerData,
            ccData: snapshot.ccData,
            chargerData: snapshot.chargerData,
            chargingPower: snapshot.chargingPower,
            chargerIdentity: snapshot.chargerIdentity,
            deviceData: snapshot.deviceData,
            displayData: snapshot.displayData,
            portStatsData: snapshot.portStatsData,
            usb3Transport: snapshot.usb3Transport,
            dpTransport: snapshot.dpTransport,
            cioTransport: snapshot.cioTransport,
            smcPortPower: snapshot.smcPortPower,
            smcPortContracts: snapshot.smcPortContracts
        )

        // Lifecycle reconciliation. A port is disconnected once CC drops, or
        // once it stops appearing in the correlated set entirely (e.g. an HPM
        // roster change); it is resolved once the port state actually shows
        // something live, rather than waiting on the lifecycle signals alone.
        // This runs on every applySnapshot, so it also serves as the machine's
        // timeout clock -- see PortLifecycleStateMachine.reconcile.
        let trackedLifecyclePortIDs = Set(lifecycleMachine.phases.keys)
        let correlatedPortIDs = Set(correlated.map(\.id))
        var disconnectedPortIDs = Set(correlated.filter { !$0.ccConnected }.map(\.id))
        disconnectedPortIDs.formUnion(trackedLifecyclePortIDs.subtracting(correlatedPortIDs))
        let resolvedPortIDs = Set(correlated.filter(\.isLifecycleResolved).map(\.id))
        lifecycleMachine.reconcile(
            disconnectedPortIDs: disconnectedPortIDs,
            resolvedPortIDs: resolvedPortIDs,
            now: snapshot.timestamp
        )
        let reconciledLifecyclePhases = lifecycleMachine.phases
        if reconciledLifecyclePhases != lifecyclePhases {
            lifecyclePhases = reconciledLifecyclePhases
        }

        // Flight Recorder: record before updating published state so the
        // recorder can diff old ports vs new correlated ports.
        recorder?.recordSnapshot(ports: correlated, timestamp: snapshot.timestamp)

        portCount = correlated.count

        ports = correlated

        for port in correlated {
            if let power = port.power {
                var history = powerHistory[port.id] ?? []
                history.append(PowerSample(timestamp: snapshot.timestamp, watts: power.watts))
                if history.count > maxPowerSamples {
                    history.removeFirst(history.count - maxPowerSamples)
                }
                powerHistory[port.id] = history
            }
        }
    }

    // Called by the IOKit layer whenever a lifecycle notification decodes to
    // one of the known signals. Separate from applySnapshot because these
    // notifications arrive on their own interest-notification path, not the
    // poll/snapshot path.
    //
    // Not internally synchronised (no locking, PortManager is
    // @unchecked Sendable): callers must invoke this on the same executor as
    // applySnapshot, since both mutate lifecycleMachine and the published
    // lifecyclePhases. In the app that's the MainActor, matching every other
    // PortManager entry point.
    public func applyLifecycleSignal(_ input: PortLifecycleSignalInput, at timestamp: Date = .now) {
        // The lifecycle codes repeat after the port has already resolved
        // (empirically, "negotiating" fires again after "contract
        // established" and after "transport ready"). reconcile() clears a
        // resolved port on the next poll, but that leaves a sub-second window
        // where a late repeat could recreate a phase and flash "Negotiating"
        // over an already-connected port. Guard it here too.
        if let existing = ports.first(where: { $0.id == input.portID }), existing.isLifecycleResolved {
            return
        }

        lifecycleMachine.handle(input.signal, portID: input.portID, at: timestamp)
        let updatedPhases = lifecycleMachine.phases
        // Equality guard: a repeated no-op signal (the common case, since
        // these codes repeat) must not trigger an Observable write.
        if updatedPhases != lifecyclePhases {
            lifecyclePhases = updatedPhases
        }
    }

    public var activePortCount: Int {
        ports.filter { $0.isActive }.count
    }

    // Total power flowing INTO the Mac (chargers, powered docks).
    public var totalWattsIn: Double {
        ports.compactMap { $0.power }
            .filter { $0.direction == .incoming }
            .reduce(0) { $0 + $1.watts }
    }

    // Total power the Mac is sourcing OUT to bus-powered devices.
    public var totalWattsOut: Double {
        ports.compactMap { $0.power }
            .filter { $0.direction == .outgoing }
            .reduce(0) { $0 + $1.watts }
    }
}

// MARK: - Snapshot input type (decoupled from IOKit raw types)

// This is what the IOKit layer passes to the domain layer.
// It mirrors the IOKit PortSnapshot but uses simpler types that
// don't require importing the IOKit module.
public struct PortManagerSnapshot: Sendable {
    public let timestamp: Date
    public let hpmPorts: [HPMPortInput]
    public let phyData: [PhyInput]
    public let tbData: [ThunderboltInput]
    public let powerData: [PowerInput]
    public let ccData: [CCInput]
    public let chargerData: [ChargerInput]
    public let chargingPower: ChargingPowerInput?
    public let chargerIdentity: ChargerIdentityInput?
    public let deviceData: [DeviceInput]
    public let displayData: [DisplayInput]
    public let portStatsData: [PortStatsInput]
    public let powerMeteringAvailable: Bool
    // Live transport state from IOPortTransportState* services
    public let usb3Transport: [USB3TransportInput]
    public let dpTransport: [DPTransportInput]
    public let cioTransport: [CIOTransportInput]
    public let smcPortPower: [SMCPortPowerInput]
    public let smcPortContracts: [SMCPortContractInput]
    public let systemPower: SystemPowerInput?
    public let controllerPower: ControllerPowerInput?

    public init(
        timestamp: Date = .now,
        hpmPorts: [HPMPortInput] = [],
        phyData: [PhyInput] = [],
        tbData: [ThunderboltInput] = [],
        powerData: [PowerInput] = [],
        ccData: [CCInput] = [],
        chargerData: [ChargerInput] = [],
        chargingPower: ChargingPowerInput? = nil,
        chargerIdentity: ChargerIdentityInput? = nil,
        deviceData: [DeviceInput] = [],
        displayData: [DisplayInput] = [],
        portStatsData: [PortStatsInput] = [],
        powerMeteringAvailable: Bool = false,
        usb3Transport: [USB3TransportInput] = [],
        dpTransport: [DPTransportInput] = [],
        cioTransport: [CIOTransportInput] = [],
        smcPortPower: [SMCPortPowerInput] = [],
        smcPortContracts: [SMCPortContractInput] = [],
        systemPower: SystemPowerInput? = nil,
        controllerPower: ControllerPowerInput? = nil
    ) {
        self.timestamp = timestamp
        self.hpmPorts = hpmPorts
        self.phyData = phyData
        self.tbData = tbData
        self.powerData = powerData
        self.ccData = ccData
        self.chargerData = chargerData
        self.chargingPower = chargingPower
        self.chargerIdentity = chargerIdentity
        self.deviceData = deviceData
        self.displayData = displayData
        self.portStatsData = portStatsData
        self.powerMeteringAvailable = powerMeteringAvailable
        self.usb3Transport = usb3Transport
        self.dpTransport = dpTransport
        self.cioTransport = cioTransport
        self.smcPortPower = smcPortPower
        self.smcPortContracts = smcPortContracts
        self.systemPower = systemPower
        self.controllerPower = controllerPower
    }
}

public struct CCInput: Sendable {
    public let portNumber: Int
    public let portType: String   // "USB-C", "MagSafe 3", etc.
    public let active: Bool
    public let cableProductType: String
    public let cablePDRevision: Int

    public init(
        portNumber: Int,
        portType: String = "USB-C",
        active: Bool,
        cableProductType: String = "",
        cablePDRevision: Int = 0
    ) {
        self.portNumber = portNumber
        self.portType = portType
        self.active = active
        self.cableProductType = cableProductType
        self.cablePDRevision = cablePDRevision
    }
}

public struct PhyInput: Sendable {
    public let phyID: Int
    // Direct port mapping from the device tree. 0 means unavailable.
    // When present, this is used instead of positional mapping to
    // correlate PHY data with Thunderbolt socket IDs.
    public let portNumber: Int
    public let lane0Transport: String
    public let lane0PowerLevel: String
    public let lane0Client: String
    public let lane1Transport: String
    public let lane1PowerLevel: String
    public let lane1Client: String
    public let usb2Transport: String
    // DP link rate from PHY pixel clock data, e.g. "5.40Gbps/lane (HBR2)"
    public let dpLinkRate: String
    // DP tunnel link rate from PHY tunnel data, when DisplayPort is tunnelled
    // over CIO rather than running native alt mode. Same format as dpLinkRate.
    public let dpTunnel: String

    public init(
        phyID: Int,
        portNumber: Int = 0,
        lane0Transport: String = "",
        lane0PowerLevel: String = "",
        lane0Client: String = "",
        lane1Transport: String = "",
        lane1PowerLevel: String = "",
        lane1Client: String = "",
        usb2Transport: String = "",
        dpLinkRate: String = "",
        dpTunnel: String = ""
    ) {
        self.phyID = phyID
        self.portNumber = portNumber
        self.lane0Transport = lane0Transport
        self.lane0PowerLevel = lane0PowerLevel
        self.lane0Client = lane0Client
        self.lane1Transport = lane1Transport
        self.lane1PowerLevel = lane1PowerLevel
        self.lane1Client = lane1Client
        self.usb2Transport = usb2Transport
        self.dpLinkRate = dpLinkRate
        self.dpTunnel = dpTunnel
    }
}

public struct ThunderboltInput: Sendable {
    public let socketID: Int
    public let currentLinkWidth: Int
    public let currentLinkSpeed: Int
    public let supportedLinkWidth: Int
    public let supportedLinkSpeed: Int
    public let thunderboltVersion: Int
    public let dualLinkPort: Int

    public init(
        socketID: Int,
        currentLinkWidth: Int = 0,
        currentLinkSpeed: Int = 0,
        supportedLinkWidth: Int = 0,
        supportedLinkSpeed: Int = 0,
        thunderboltVersion: Int = 0,
        dualLinkPort: Int = 0
    ) {
        self.socketID = socketID
        self.currentLinkWidth = currentLinkWidth
        self.currentLinkSpeed = currentLinkSpeed
        self.supportedLinkWidth = supportedLinkWidth
        self.supportedLinkSpeed = supportedLinkSpeed
        self.thunderboltVersion = thunderboltVersion
        self.dualLinkPort = dualLinkPort
    }
}

public struct PowerInput: Sendable {
    public let portIndex: Int
    public let watts: Int
    public let current: Int
    public let adapterVoltage: Int
    public let configuredVoltage: Int
    public let configuredCurrent: Int
    public let vconnCurrent: Int
    public let vconnPower: Int
    public let vconnMaxCurrent: Int

    public init(
        portIndex: Int,
        watts: Int = 0,
        current: Int = 0,
        adapterVoltage: Int = 0,
        configuredVoltage: Int = 0,
        configuredCurrent: Int = 0,
        vconnCurrent: Int = 0,
        vconnPower: Int = 0,
        vconnMaxCurrent: Int = 0
    ) {
        self.portIndex = portIndex
        self.watts = watts
        self.current = current
        self.adapterVoltage = adapterVoltage
        self.configuredVoltage = configuredVoltage
        self.configuredCurrent = configuredCurrent
        self.vconnCurrent = vconnCurrent
        self.vconnPower = vconnPower
        self.vconnMaxCurrent = vconnMaxCurrent
    }
}

// One physical port from the HPM controller layer. The authoritative port
// roster, carrying the stable UUID identity and health counters.
public struct HPMPortInput: Sendable {
    public let uuid: String
    public let portNumber: Int
    public let portType: String   // "USB-C", "MagSafe 3", etc.
    public let overcurrentCount: Int
    public let plugEventCount: Int
    public let connectionCount: Int
    public let authorizationStatus: String
    public let ldcmStatus: String
    public let provisionedTransports: [String]
    public let unauthorizedTransports: [String]
    public let liquidDetected: Bool
    public let mitigationsActive: Bool

    public var isMagSafe: Bool {
        portType.lowercased().contains("magsafe")
    }

    public init(
        uuid: String,
        portNumber: Int,
        portType: String,
        overcurrentCount: Int = 0,
        plugEventCount: Int = 0,
        connectionCount: Int = 0,
        authorizationStatus: String = "",
        ldcmStatus: String = "",
        provisionedTransports: [String] = [],
        unauthorizedTransports: [String] = [],
        liquidDetected: Bool = false,
        mitigationsActive: Bool = false
    ) {
        self.uuid = uuid
        self.portNumber = portNumber
        self.portType = portType
        self.overcurrentCount = overcurrentCount
        self.plugEventCount = plugEventCount
        self.connectionCount = connectionCount
        self.authorizationStatus = authorizationStatus
        self.ldcmStatus = ldcmStatus
        self.provisionedTransports = provisionedTransports
        self.unauthorizedTransports = unauthorizedTransports
        self.liquidDetected = liquidDetected
        self.mitigationsActive = mitigationsActive
    }
}

// One SMC per-port power-OUT channel. Tied to a physical port by `uuid`
// (the channel's DxUI = the port's HPM UUID), since the SMC D-index does not
// equal the physical port number.
public struct SMCPortPowerInput: Sendable {
    public let present: Bool
    public let volts: Double
    public let amps: Double
    public let uuid: String   // 32-char lowercase hex (normalised)

    public var watts: Double { volts * amps }

    public init(present: Bool, volts: Double, amps: Double, uuid: String) {
        self.present = present
        self.volts = volts
        self.amps = amps
        self.uuid = uuid
    }
}

public struct ChargerInput: Sendable {
    public let portType: String   // "MagSafe 3", "USB-C", etc.
    public let portNumber: Int
    public let maxWatts: Int      // milliwatts, 0 when the node carries no PDO
    public let voltage: Int       // millivolts
    public let maxCurrent: Int    // milliamps
    // True when the PDO came from WinningPowerSourceOption (the contract the
    // system selected) rather than the highest-PDO fallback.
    public let hasWinningContract: Bool

    public init(
        portType: String,
        portNumber: Int,
        maxWatts: Int = 0,
        voltage: Int = 0,
        maxCurrent: Int = 0,
        hasWinningContract: Bool = false
    ) {
        self.portType = portType
        self.portNumber = portNumber
        self.maxWatts = maxWatts
        self.voltage = voltage
        self.maxCurrent = maxCurrent
        self.hasWinningContract = hasWinningContract
    }
}

// One SMC charging contract channel (power IN), joined to a port by UUID.
public struct SMCPortContractInput: Sendable {
    public let channel: Int       // SMC D-index (1..4), NOT the physical port
    public let uuid: String       // 32-char lowercase hex (normalised)
    public let powerMW: Int
    public let voltageMV: Int
    public let currentMA: Int
    public let label: String

    public init(
        channel: Int,
        uuid: String,
        powerMW: Int,
        voltageMV: Int,
        currentMA: Int,
        label: String = ""
    ) {
        self.channel = channel
        self.uuid = uuid
        self.powerMW = powerMW
        self.voltageMV = voltageMV
        self.currentMA = currentMA
        self.label = label
    }
}

// Live charging power from PowerTelemetryData on AppleSmartBattery.
// System-level (not per-port): represents total power drawn from the
// active charger. Only one charger supplies power at a time.
public struct ChargingPowerInput: Sendable {
    public let systemPowerIn: Int     // milliwatts
    public let systemVoltageIn: Int   // millivolts
    public let systemCurrentIn: Int   // milliamps
    public let isCharging: Bool       // battery is actively charging
    public let fullyCharged: Bool     // battery is full
    public let notChargingReason: Int // AppleSmartBattery NotChargingReason bitfield

    public init(
        systemPowerIn: Int,
        systemVoltageIn: Int,
        systemCurrentIn: Int,
        isCharging: Bool = false,
        fullyCharged: Bool = false,
        notChargingReason: Int = 0
    ) {
        self.systemPowerIn = systemPowerIn
        self.systemVoltageIn = systemVoltageIn
        self.systemCurrentIn = systemCurrentIn
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.notChargingReason = notChargingReason
    }
}

// Total system DC-in (wall) power straight from the SMC rails, independent of
// AppleSmartBattery. System-level, like ChargingPowerInput, but present on
// desktop Macs too: they have no battery controller, so chargingPower is
// always nil there even though the SMC still reports real wall draw.
public struct SystemPowerInput: Sendable {
    public let watts: Double
    public let volts: Double
    public let amps: Double

    public init(watts: Double, volts: Double, amps: Double) {
        self.watts = watts
        self.volts = volts
        self.amps = amps
    }
}

// Machine-wide Thunderbolt/XHCI controller power state. Mirrors
// WhatPortIOKit's RawControllerPower; kept as a separate type here because
// the domain layer never imports IOKit types. See RawControllerPower for the
// none-found semantics (nil vs false) and the corpus evidence behind the two
// booleans.
public struct ControllerPowerInput: Sendable {
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

// Charger identity from AppleSmartBattery.AdapterDetails. System-level (one
// active charger); attached in correlation to the port receiving power.
public struct ChargerIdentityInput: Sendable {
    public let name: String
    public let manufacturer: String
    public let description: String
    public let maxWatts: Int
    public let pdos: [ChargerPDO]

    public init(
        name: String,
        manufacturer: String = "",
        description: String = "",
        maxWatts: Int = 0,
        pdos: [ChargerPDO] = []
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.description = description
        self.maxWatts = maxWatts
        self.pdos = pdos
    }

    // The display name, falling back through description to a generic label.
    public var resolvedName: String {
        if !name.isEmpty { return name }
        if !description.isEmpty { return description }
        return "PD charger"
    }

    public func toChargerInfo() -> ChargerInfo {
        ChargerInfo(
            name: resolvedName,
            manufacturer: manufacturer,
            maxWatts: maxWatts,
            pdos: pdos
        )
    }
}

public struct DeviceInput: Sendable {
    public let portNumber: Int
    public let productName: String
    public let vendorName: String
    public let speedCode: Int       // USB Device Speed enum
    public let usbVersion: Int      // bcdUSB (e.g. 800 = USB 3.2)
    public let deviceClass: Int     // bDeviceClass (8 = storage, etc.)
    public let currentDraw: Int     // mA allocated
    public let serialNumber: String
    public let locationID: Int      // encodes the USB hub-topology path

    public init(
        portNumber: Int,
        productName: String,
        vendorName: String = "",
        speedCode: Int = 0,
        usbVersion: Int = 0,
        deviceClass: Int = 0,
        currentDraw: Int = 0,
        serialNumber: String = "",
        locationID: Int = 0
    ) {
        self.portNumber = portNumber
        self.productName = productName
        self.vendorName = vendorName
        self.speedCode = speedCode
        self.usbVersion = usbVersion
        self.deviceClass = deviceClass
        self.currentDraw = currentDraw
        self.serialNumber = serialNumber
        self.locationID = locationID
    }
}

public struct DisplayInput: Sendable {
    public let portNumber: Int
    public let productName: String
    public let maxWidth: Int
    public let maxHeight: Int

    public init(
        portNumber: Int,
        productName: String,
        maxWidth: Int = 0,
        maxHeight: Int = 0
    ) {
        self.portNumber = portNumber
        self.productName = productName
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

public struct PortStatsInput: Sendable {
    public let portNumber: Int
    public let connectCount: Int
    public let overcurrentCount: Int
    public let enumerationFailureCount: Int
    public let addressFailureCount: Int
    public let linkErrorCount: Int
    public let remoteWakeCount: Int

    public init(
        portNumber: Int,
        connectCount: Int = 0,
        overcurrentCount: Int = 0,
        enumerationFailureCount: Int = 0,
        addressFailureCount: Int = 0,
        linkErrorCount: Int = 0,
        remoteWakeCount: Int = 0
    ) {
        self.portNumber = portNumber
        self.connectCount = connectCount
        self.overcurrentCount = overcurrentCount
        self.enumerationFailureCount = enumerationFailureCount
        self.addressFailureCount = addressFailureCount
        self.linkErrorCount = linkErrorCount
        self.remoteWakeCount = remoteWakeCount
    }
}

// MARK: - Live transport state inputs

public struct USB3TransportInput: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let dataRate: String          // "10 Gbps"
    public let generation: String        // "Gen 2"
    public let generationFamily: String  // "USB 3.x"
    public let tunneled: Bool
    public let transportRestricted: Bool // macOS TRM has blocked data

    public init(
        portNumber: Int,
        active: Bool = false,
        dataRate: String = "",
        generation: String = "",
        generationFamily: String = "",
        tunneled: Bool = false,
        transportRestricted: Bool = false
    ) {
        self.portNumber = portNumber
        self.active = active
        self.dataRate = dataRate
        self.generation = generation
        self.generationFamily = generationFamily
        self.tunneled = tunneled
        self.transportRestricted = transportRestricted
    }
}

public struct DPTransportInput: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let linkRate: String          // "5.4 Gbps (HBR2)"
    public let laneCount: Int
    public let maxLaneCount: Int
    public let tunneled: Bool
    public let sinkCount: Int
    public let branchDevice: String      // MST hub / converter chip, e.g. "Dp1.2"
    public let dfpType: String           // downstream port type, e.g. "HDMI"

    public init(
        portNumber: Int,
        active: Bool = false,
        linkRate: String = "",
        laneCount: Int = 0,
        maxLaneCount: Int = 0,
        tunneled: Bool = false,
        sinkCount: Int = 0,
        branchDevice: String = "",
        dfpType: String = ""
    ) {
        self.portNumber = portNumber
        self.active = active
        self.linkRate = linkRate
        self.laneCount = laneCount
        self.maxLaneCount = maxLaneCount
        self.tunneled = tunneled
        self.sinkCount = sinkCount
        self.branchDevice = branchDevice
        self.dfpType = dfpType
    }
}

public struct CIOTransportInput: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let dataRate: String
    public let tunneled: Bool
    public let tunnelProvisioned: [String]
    public let tunnelSupported: [String]
    public let deviceModel: String
    public let deviceVendor: String

    public init(
        portNumber: Int,
        active: Bool = false,
        dataRate: String = "",
        tunneled: Bool = false,
        tunnelProvisioned: [String] = [],
        tunnelSupported: [String] = [],
        deviceModel: String = "",
        deviceVendor: String = ""
    ) {
        self.portNumber = portNumber
        self.active = active
        self.dataRate = dataRate
        self.tunneled = tunneled
        self.tunnelProvisioned = tunnelProvisioned
        self.tunnelSupported = tunnelSupported
        self.deviceModel = deviceModel
        self.deviceVendor = deviceVendor
    }
}

// MARK: - Power sample for history graph

public struct PowerSample: Sendable {
    public let timestamp: Date
    public let watts: Double

    public init(timestamp: Date, watts: Double) {
        self.timestamp = timestamp
        self.watts = watts
    }
}

// MARK: - Correlation logic

extension PortManager {
    // Correlates PHY lane data with Thunderbolt link data and power data
    // to build a unified PortState per physical port.
    //
    // The key insight: IOThunderboltPort's Socket ID = physical port number.
    // We use Socket ID as the canonical port identifier.
    //
    // PHY-to-port mapping uses two strategies:
    // 1. Direct: if PHY data has portNumber (from the parent atc-phy device
    //    tree node), match portNumber to socketID. Confirmed on M4 Pro;
    //    not yet verified across all Mac models, but device-tree port-number
    //    is a standard ARM IOKit property so it should be universal.
    // 2. Positional fallback: PHYs sorted by ID map to sockets sorted by
    //    ID. Works when PHY count == port count but breaks when there are
    //    extra PHYs (e.g. M4 Pro has 4 PHYs for 3 ports).
    private func correlate(
        hpmPorts: [HPMPortInput] = [],
        phyData: [PhyInput],
        tbData: [ThunderboltInput],
        powerData: [PowerInput],
        ccData: [CCInput],
        chargerData: [ChargerInput] = [],
        chargingPower: ChargingPowerInput? = nil,
        chargerIdentity: ChargerIdentityInput? = nil,
        deviceData: [DeviceInput] = [],
        displayData: [DisplayInput] = [],
        portStatsData: [PortStatsInput] = [],
        usb3Transport: [USB3TransportInput] = [],
        dpTransport: [DPTransportInput] = [],
        cioTransport: [CIOTransportInput] = [],
        smcPortPower: [SMCPortPowerInput] = [],
        smcPortContracts: [SMCPortContractInput] = []
    ) -> [PortState] {
        // Deduplicate TB data by socket ID (multiple adapters per port, take best)
        let tbBySocket = bestTBPerSocket(tbData)

        // Deduplicate PHY data by port number (multiple PHYs per port, take best)
        let dedupedPhys = bestPhyPerPort(phyData)
        let hasDirectMapping = dedupedPhys.contains { $0.portNumber > 0 }

        // Separate USB-C CC data from non-USB-C (MagSafe, etc.)
        // They can share the same ParentBuiltInPortNumber, so we must
        // not let MagSafe's state bleed into USB-C port matching.
        let usbCCC = ccData.filter { $0.portType == "USB-C" }
        let nonUSBCCC = ccData.filter { $0.portType != "USB-C" && $0.portType != "" }

        let ccByPort = Dictionary(usbCCC.map { ($0.portNumber, $0.active) }, uniquingKeysWith: { a, _ in a })

        // Get unique socket IDs sorted (these are our physical ports)
        let socketIDs = tbBySocket.keys.sorted()

        // Build PHY lookup for direct mapping
        let phyByPort: [Int: PhyInput] = hasDirectMapping
            ? Dictionary(
                dedupedPhys.compactMap { $0.portNumber > 0 ? ($0.portNumber, $0) : nil },
                uniquingKeysWith: { existing, _ in existing }
              )
            : [:]

        // Picks the PHY for a port: direct by port number, else positional.
        func phyFor(portNumber: Int, index: Int) -> PhyInput? {
            if hasDirectMapping { return phyByPort[portNumber] }
            return index < dedupedPhys.count ? dedupedPhys[index] : nil
        }

        // Build the USB-C port roster. The HPM controller layer is the
        // authoritative source of physical ports and their stable UUID, so we
        // prefer it. When there is no HPM node (Intel, desktop front ports, or
        // tests) we fall back to Thunderbolt socket IDs, then PHY port numbers.
        // All sources key the per-port data by the same "@N" number, which
        // agrees across the HPM / PHY / TB / transport trees.
        let usbcHPM = hpmPorts.filter { !$0.isMagSafe }.sorted { $0.portNumber < $1.portNumber }
        var results: [PortState]

        if !usbcHPM.isEmpty {
            results = usbcHPM.enumerated().map { index, hpm in
                var state = buildPortState(
                    portID: hpm.portNumber,
                    phy: phyFor(portNumber: hpm.portNumber, index: index),
                    tb: tbBySocket[hpm.portNumber],
                    power: powerData.first { $0.portIndex == hpm.portNumber },
                    ccActive: ccByPort[hpm.portNumber] ?? false
                )
                state.uuid = hpm.uuid
                state.health = PortHealth(
                    overcurrentCount: hpm.overcurrentCount,
                    plugEventCount: hpm.plugEventCount,
                    connectionCount: hpm.connectionCount,
                    authorizationStatus: hpm.authorizationStatus,
                    ldcmStatus: hpm.ldcmStatus,
                    liquidDetected: hpm.liquidDetected,
                    mitigationsActive: hpm.mitigationsActive
                )
                return state
            }
        } else if !socketIDs.isEmpty {
            results = socketIDs.enumerated().map { index, socketID in
                buildPortState(
                    portID: socketID,
                    phy: phyFor(portNumber: socketID, index: index),
                    tb: tbBySocket[socketID],
                    power: powerData.first { $0.portIndex == socketID },
                    ccActive: ccByPort[socketID] ?? false
                )
            }
        } else {
            results = dedupedPhys.map { phy in
                let portID = phy.portNumber > 0 ? phy.portNumber : (phy.phyID + 1)
                return buildPortState(
                    portID: portID,
                    phy: phy,
                    tb: nil,
                    power: powerData.first { $0.portIndex == portID },
                    ccActive: ccByPort[portID] ?? false
                )
            }
        }

        // Attach charger power to the USB-C port that negotiated a USB-PD
        // contract (power flows IN, so it never shows in PowerOutDetails).
        applyChargerPower(to: &results, chargerData: chargerData, chargingPower: chargingPower)

        // Append non-USB-C ports (MagSafe, etc.), stamping their HPM UUID and health.
        //
        // On M1 Pro / Max / Ultra there is no USB-C power-source node to read,
        // so "no USB-C contract" cannot be taken to mean "USB-C is not
        // charging". An SMC contract resolving to a connected USB-C port says
        // it is, and that has to be settled here, before a MagSafe cable that
        // is merely plugged in claims the machine's whole power-in figure.
        // Two separate signals, because they carry different weight and
        // collapsing them into one boolean blanks a MagSafe port that holds its
        // own macOS-confirmed contract.
        let usbCHoldsNodeContract = chargerData.contains { $0.portType == "USB-C" && $0.maxWatts > 0 }
        let usbCHasSMCEvidence = SMCContractAttribution.hasUSBCContractCandidate(
            contracts: smcPortContracts,
            ports: results,
            // Same channels' power-OUT readings as the attribution path uses.
            // Without them this asks a weaker question than resolve() does, and
            // a USB-C channel that is actually feeding a peripheral would count
            // as evidence that USB-C is being fed, blanking a MagSafe port that
            // is genuinely delivering.
            powerOut: smcPortPower
        )

        // The same evidence for the MagSafe side. The SMC publishes contract
        // channels for MagSafe ports too, on 118 corpus machines, and a channel
        // carrying a contract is a port being fed. We never ATTRIBUTE from it
        // (the node is authoritative for MagSafe, and the attribution path
        // takes USB-C ports only), but it settles the one case the node cannot:
        // MagSafe genuinely delivering while publishing no usable node, with a
        // USB-C dock also negotiating. Without it that machine's whole draw
        // lands on the dock.
        //
        // Held to the same standard as the USB-C check above, not just a
        // positive wattage: power, voltage and current are three independently
        // read SMC keys, so a partial read can leave a plausible-looking power
        // beside a nonsense voltage, and here that noise would swing the whole
        // figure onto MagSafe.
        let magSafeSMCContractPorts = Set(
            hpmPorts.filter { hpm in
                hpm.isMagSafe && smcPortContracts.contains { contract in
                    SMCContractAttribution.isPlausibleIncomingContract(
                        contract,
                        powerOut: smcPortPower.first { $0.uuid == contract.uuid }
                    ) && SMCContractAttribution.normalisedUUID(hpm.uuid) == contract.uuid
                }
            }.map(\.portNumber)
        )
        var nonUSBC = buildNonUSBCPorts(
            nonUSBCCC,
            chargerData: chargerData,
            chargingPower: chargingPower,
            usbCHoldsNodeContract: usbCHoldsNodeContract,
            usbCHasSMCEvidence: usbCHasSMCEvidence,
            smcContractPorts: magSafeSMCContractPorts
        )
        stampMagSafeHPMData(&nonUSBC, hpmPorts: hpmPorts)
        results.append(contentsOf: nonUSBC)

        // Charging contract from the SMC, for the machines where macOS never
        // publishes the USB-C power-source node the charger path above reads
        // (M1 Pro / Max / Ultra). Runs after MagSafe ports are built because
        // one of its gates is "no port is already showing incoming power", and
        // a MagSafe port that is genuinely charging must be able to trip it.
        applySMCContract(
            to: &results,
            smcPortContracts: smcPortContracts,
            smcPortPower: smcPortPower,
            chargerData: chargerData,
            chargingPower: chargingPower
        )

        // Per-port power-OUT: join SMC channels to ports by UUID. The SMC is the
        // primary source (live ~1 Hz; PowerOutDetails freezes under load), so it
        // overrides the PowerOutDetails reading wherever a channel resolves. It
        // runs after the charger path so it never clobbers an incoming reading.
        // The channel's DxUI (= the port's HPM UUID) is the only correct join;
        // the SMC D-index is not the physical port number.
        applySMCPower(to: &results, smcPortPower: smcPortPower)

        // Name the charger on whichever port ended up receiving power. Runs
        // after every power path so it only tags a confirmed incoming port.
        applyChargerIdentity(to: &results, chargerIdentity: chargerIdentity)

        // Build lookup dictionaries for enrichment data. Devices are grouped
        // (not first-wins) because a port can carry a whole tree behind a
        // hub or dock, not just one device.
        let deviceDataByPort = Dictionary(grouping: deviceData, by: \.portNumber)
        let displaysByPort = Dictionary(
            displayData.map { ($0.portNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let statsByPort = Dictionary(
            portStatsData.map { ($0.portNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let ccByPortFull = Dictionary(
            usbCCC.map { ($0.portNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        // HPM transport lists are keyed by physical port number. MagSafe is
        // charge-only and has no data transports, so only USB-C ports qualify.
        let hpmByPort = Dictionary(
            hpmPorts.filter { !$0.isMagSafe }.map { ($0.portNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let cioByPort = Dictionary(
            cioTransport.map { ($0.portNumber, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        for i in results.indices {
            let portID = results[i].id

            // Full USB device tree for the detail view, pre-order (parents
            // before children, siblings in enumeration order). Built from
            // this port's own slice only, so a locationID collision on
            // another port can never cross-contaminate this tree.
            let usbDevices = buildDeviceTree(deviceDataByPort[portID] ?? [])
            results[i].usbDevices = usbDevices

            // Same primary-selection rule as PortState.usbDevice: the first
            // real (non-hub) device in tree order, falling back to a hub
            // only when hubs are all the port has. Keeps the row title in
            // step with whatever the free tier fronts.
            let primaryDevice = usbDevices.first { $0.deviceClass != .hub } ?? usbDevices.first

            // Display name takes priority over USB device name since a USB
            // device on a TB/DP port is usually the hub, not the display.
            if let display = displaysByPort[portID] {
                results[i].deviceName = display.productName
                results[i].displayWidth = display.maxWidth
                results[i].displayHeight = display.maxHeight
            } else if let primary = primaryDevice {
                results[i].deviceName = primary.productName
                if let speed = primary.speed {
                    results[i].usbSpeed = speed
                }
            }

            // Cable identity from CC SOP' data
            if let cc = ccByPortFull[portID], !cc.cableProductType.isEmpty {
                results[i].cable = CableInfo(
                    productType: cc.cableProductType,
                    pdRevision: cc.cablePDRevision
                )
            }

            // Port statistics (lifetime counters)
            if let stats = statsByPort[portID] {
                results[i].portStats = PortStatistics(
                    connectCount: stats.connectCount,
                    overcurrentCount: stats.overcurrentCount,
                    enumerationFailureCount: stats.enumerationFailureCount,
                    addressFailureCount: stats.addressFailureCount,
                    linkErrorCount: stats.linkErrorCount,
                    remoteWakeCount: stats.remoteWakeCount
                )
            }

            // TB port capability (supported speed/width even when no link active)
            if let tb = tbBySocket[portID] {
                results[i].thunderboltCapability = ThunderboltCapability(
                    supportedLinkSpeed: tb.supportedLinkSpeed,
                    supportedLinkWidth: tb.supportedLinkWidth,
                    thunderboltVersion: tb.thunderboltVersion
                )
            }

            // Live transport state (real-time link data per transport)
            results[i].liveTransports = buildLiveTransports(
                portID: portID,
                usb3Transport: usb3Transport,
                dpTransport: dpTransport,
                cioTransport: cioTransport
            )

            // Provisioned / blocked / tunnelled transports (the "why doesn't
            // my dock work" answer). HPM lists are M3+; CIO lists need a TB
            // link. Only attach when something is actually present.
            let hpm = hpmByPort[portID]
            let cio = cioByPort[portID]
            let transports = PortTransports(
                provisioned: hpm?.provisionedTransports ?? [],
                unauthorized: hpm?.unauthorizedTransports ?? [],
                tunnelProvisioned: cio?.tunnelProvisioned ?? [],
                tunnelSupported: cio?.tunnelSupported ?? []
            )
            if transports.hasData {
                results[i].transports = transports
            }

            // Name the connected Thunderbolt device from its TB controller.
            // The link itself is built from IOThunderboltPort (no name there);
            // the CIO node carries the dock/hub identity. Require an active CIO
            // node (matching buildLiveTransports) so a stale node left behind
            // after a fast device swap can't stamp the old name onto a new one.
            if let cio, cio.active, results[i].thunderboltLink != nil {
                if !cio.deviceModel.isEmpty {
                    results[i].thunderboltLink?.deviceName = cio.deviceModel
                }
                if !cio.deviceVendor.isEmpty {
                    results[i].thunderboltLink?.deviceVendor = cio.deviceVendor
                }
            }
        }

        return results
    }

    // Build LiveTransport entries for a port from the transport state services.
    // Only includes transports that are active on this port.
    private func buildLiveTransports(
        portID: Int,
        usb3Transport: [USB3TransportInput],
        dpTransport: [DPTransportInput],
        cioTransport: [CIOTransportInput]
    ) -> [LiveTransport] {
        var transports: [LiveTransport] = []

        // Include a restricted link even when it is not active: macOS has
        // negotiated a speed but blocked data, and we want to show that
        // rather than silently dropping the port as idle.
        if let usb3 = usb3Transport.first(where: {
            $0.portNumber == portID && ($0.active || $0.transportRestricted)
        }) {
            transports.append(LiveTransport(
                kind: .usb,
                dataRate: usb3.dataRate,
                generation: usb3.generation,
                tunneled: usb3.tunneled,
                restricted: usb3.transportRestricted
            ))
        }

        if let dp = dpTransport.first(where: { $0.portNumber == portID && $0.active }) {
            transports.append(LiveTransport(
                kind: .displayPort,
                dataRate: dp.linkRate,
                laneCount: dp.laneCount,
                maxLaneCount: dp.maxLaneCount,
                tunneled: dp.tunneled,
                sinkCount: dp.sinkCount,
                branchDevice: dp.branchDevice,
                dfpType: dp.dfpType
            ))
        }

        if let cio = cioTransport.first(where: { $0.portNumber == portID && $0.active }) {
            transports.append(LiveTransport(
                kind: .thunderbolt,
                dataRate: cio.dataRate,
                tunneled: cio.tunneled
            ))
        }

        return transports
    }

    // Multiple TB adapters exist per socket (one per lane). Pick the one
    // with the highest link width as the representative.
    private func bestTBPerSocket(_ tbData: [ThunderboltInput]) -> [Int: ThunderboltInput] {
        var best: [Int: ThunderboltInput] = [:]
        for tb in tbData {
            guard tb.socketID > 0 else { continue }
            if let existing = best[tb.socketID] {
                if tb.currentLinkWidth > existing.currentLinkWidth {
                    best[tb.socketID] = tb
                }
            } else {
                best[tb.socketID] = tb
            }
        }
        return best
    }

    // Multiple PHY controllers can map to the same physical port.
    // For example, M4 Pro has 4 PHYs for 3 ports (PHY 0 and PHY 2 both
    // map to port 1). Pick the one with active transport data.
    // If port-number isn't available, each PHY is treated as unique.
    private func bestPhyPerPort(_ phyData: [PhyInput]) -> [PhyInput] {
        let hasPortNumbers = phyData.contains { $0.portNumber > 0 }
        guard hasPortNumbers else { return phyData }

        var best: [Int: PhyInput] = [:]
        for phy in phyData {
            let key = phy.portNumber > 0 ? phy.portNumber : phy.phyID
            if let existing = best[key] {
                // Prefer the PHY with active transport
                let phyActive = !phy.lane0Transport.isEmpty || !phy.lane1Transport.isEmpty
                let existingActive = !existing.lane0Transport.isEmpty || !existing.lane1Transport.isEmpty
                if phyActive && !existingActive {
                    best[key] = phy
                }
            } else {
                best[key] = phy
            }
        }

        return best.values.sorted {
            let a = $0.portNumber > 0 ? $0.portNumber : $0.phyID
            let b = $1.portNumber > 0 ? $1.portNumber : $1.phyID
            return a < b
        }
    }

    // Attach charger (power-IN) data to the USB-C port that negotiated a
    // USB-PD source contract. PowerOutDetails only covers power the Mac
    // delivers OUT to bus-powered devices; a charger supplies power IN, so
    // it never appears there. On Macs without PowerOutDetails (e.g. base M5)
    // this IOPortFeaturePowerSource contract is the only per-port power
    // signal we get. We show the negotiated contract (volts / amps) plus the
    // live draw from PowerTelemetryData, which is near zero when the battery
    // is full and ramps up while charging.
    //
    // Only the port with an actual USB-PD contract gets power. This is also
    // what stops a bare cable (CC active, no contract) from being treated as
    // a charger and inheriting the system battery state.
    private func applyChargerPower(
        to results: inout [PortState],
        chargerData: [ChargerInput],
        chargingPower: ChargingPowerInput?
    ) {
        // maxWatts > 0 is what makes this a contract rather than a bare node.
        // ChargerReader reports nodes carrying no PDO too, so that the SMC
        // fallback below can tell "macOS published nothing here" apart from
        // "macOS published a node that has not settled yet"; those bare entries
        // must never reach the attribution here.
        let usbcChargers = Dictionary(
            chargerData
                .filter { $0.portType == "USB-C" && $0.portNumber > 0 && $0.maxWatts > 0 }
                .map { ($0.portNumber, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !usbcChargers.isEmpty else { return }

        for i in results.indices {
            guard results[i].power == nil, results[i].ccConnected else { continue }
            guard let charger = usbcChargers[results[i].id] else { continue }

            results[i].power = PortPower(
                watts: Double(chargingPower?.systemPowerIn ?? 0) / 1000.0,
                current: chargingPower?.systemCurrentIn ?? 0,
                voltage: chargingPower?.systemVoltageIn ?? charger.voltage,
                configuredVoltage: charger.voltage,
                configuredCurrent: charger.maxCurrent,
                vconnCurrent: 0,
                vconnPower: 0,
                vconnMaxCurrent: 0,
                direction: .incoming,
                // A node without a winning contract is the highest-PDO
                // fallback (see buildNonUSBCPorts' comment): a capability the
                // charger offers, not the agreement the two of them reached.
                contractIsEstimated: !charger.hasWinningContract
            )
        }
    }

    // Attach a charging contract read from the SMC to the one port it resolves
    // to. This only ever fires on machines where macOS published no USB-C
    // power-source node at all: see SMCContractAttribution for the gates and
    // the corpus evidence behind the join.
    //
    // The contract supplies the negotiated volts and amps; the live draw still
    // comes from the same system telemetry the real-node path uses, so a port
    // fixed up here reads identically to one macOS described itself.
    private func applySMCContract(
        to results: inout [PortState],
        smcPortContracts: [SMCPortContractInput],
        smcPortPower: [SMCPortPowerInput],
        chargerData: [ChargerInput],
        chargingPower: ChargingPowerInput?
    ) {
        guard !smcPortContracts.isEmpty else { return }

        guard let resolved = SMCContractAttribution.resolve(
            contracts: smcPortContracts,
            ports: results,
            chargerNodes: chargerData,
            // chargingPower is non-nil only when a charger is connected: the
            // reader gates on ExternalConnected.
            externalConnected: chargingPower != nil,
            // The same channels' power-OUT readings, so a channel measurably
            // feeding a peripheral cannot be published as an incoming charge.
            powerOut: smcPortPower
        ) else { return }

        guard let index = results.firstIndex(where: { $0.id == resolved.portID }) else { return }

        results[index].power = PortPower(
            watts: Double(chargingPower?.systemPowerIn ?? 0) / 1000.0,
            current: chargingPower?.systemCurrentIn ?? 0,
            voltage: chargingPower?.systemVoltageIn ?? resolved.contract.voltageMV,
            configuredVoltage: resolved.contract.voltageMV,
            configuredCurrent: resolved.contract.currentMA,
            vconnCurrent: 0,
            vconnPower: 0,
            vconnMaxCurrent: 0,
            direction: .incoming,
            // This whole path only ever fires where macOS published no
            // USB-C power-source node of its own; the contract is always
            // synthesized from the SMC, never macOS-confirmed.
            contractIsEstimated: true
        )
    }

    // Join SMC per-port power-OUT channels to ports by UUID. The SMC is the
    // primary per-port power-OUT source: its analog rails (DxJV/DxJI) update
    // ~1 Hz and track the real draw, whereas AppleSmartBattery.PowerOutDetails
    // is firmware-batched and freezes under load on Apple Silicon (confirmed in
    // WhatCable, M5 Pro: held 6098 mW for 20 s while the SMC tracked 6.6-7.5 W).
    // So where a channel resolves to a port by UUID we override the
    // PowerOutDetails reading with the live SMC values, but carry over the
    // PD-contract metadata (configured voltage/current, VConn) the SMC doesn't
    // provide. We never override an incoming (charger) reading: the SMC measures
    // power OUT, and the charger path applied earlier owns charging ports.
    // Matched on the channel's DxUI = the port's HPM UUID, never the SMC D-index
    // (which is not the physical port number). On M1/M2 (no UUID map) or any
    // unresolved port, no channel matches and the PowerOutDetails reading stands.
    private func applySMCPower(to results: inout [PortState], smcPortPower: [SMCPortPowerInput]) {
        guard !smcPortPower.isEmpty else { return }

        // SMC UUIDs arrive already normalised (lowercase, no dashes).
        let byUUID = Dictionary(
            smcPortPower.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in results.indices {
            guard let uuid = results[i].uuid else { continue }
            // Keep incoming (charger) readings: the SMC only measures power OUT.
            if let existing = results[i].power, existing.direction == .incoming { continue }
            guard let channel = byUUID[normalisedUUID(uuid)] else { continue }
            // Only surface a reading when the Mac is actually sourcing power.
            // A channel at 0 W means nothing is drawing; leave the existing
            // reading (or nil) so the UI shows the real state, not a stale 0 W.
            guard channel.watts > 0 else { continue }

            // Carry the PD contract over from the PowerOutDetails reading when we
            // have one; the SMC doesn't report it and it isn't frozen-sensitive.
            let existing = results[i].power
            results[i].power = PortPower(
                watts: channel.watts,
                current: Int((channel.amps * 1000).rounded()),
                voltage: Int((channel.volts * 1000).rounded()),
                configuredVoltage: existing?.configuredVoltage ?? 0,
                configuredCurrent: existing?.configuredCurrent ?? 0,
                vconnCurrent: existing?.vconnCurrent ?? 0,
                vconnPower: existing?.vconnPower ?? 0,
                vconnMaxCurrent: existing?.vconnMaxCurrent ?? 0,
                direction: .outgoing,
                contractIsEstimated: existing?.contractIsEstimated ?? false
            )
        }
    }

    // Attach the active charger's identity to the port(s) receiving power.
    // The charger is system-level (AppleSmartBattery reports one active
    // adapter), so we tag every incoming port; in practice that is the single
    // port with the live USB-PD / MagSafe contract. No-op on desktops (no
    // battery controller) or when nothing is charging.
    private func applyChargerIdentity(
        to results: inout [PortState],
        chargerIdentity: ChargerIdentityInput?
    ) {
        guard let chargerIdentity else { return }
        let info = chargerIdentity.toChargerInfo()
        for i in results.indices where results[i].power?.direction == .incoming {
            results[i].charger = info
        }
    }

    // Normalise an HPM UUID to match the SMC DxUI form. One implementation,
    // shared with the contract path, so the two joins cannot drift apart.
    private func normalisedUUID(_ uuid: String) -> String {
        SMCContractAttribution.normalisedUUID(uuid)
    }

    // Stamp the stable HPM UUID and health data onto non-USB-C ports (MagSafe).
    // These ports are built from CC data and keyed by id = 100 + portNumber, so
    // we map back to the physical number to look up the HPM entry. No-op without HPM.
    private func stampMagSafeHPMData(_ ports: inout [PortState], hpmPorts: [HPMPortInput]) {
        guard !hpmPorts.isEmpty else { return }
        let magByNumber = Dictionary(
            hpmPorts.filter { $0.isMagSafe }.map { ($0.portNumber, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for i in ports.indices where ports[i].portType == .magSafe {
            guard let hpm = magByNumber[ports[i].id - 100] else { continue }
            ports[i].uuid = hpm.uuid
            ports[i].health = PortHealth(
                overcurrentCount: hpm.overcurrentCount,
                plugEventCount: hpm.plugEventCount,
                connectionCount: hpm.connectionCount,
                authorizationStatus: hpm.authorizationStatus,
                ldcmStatus: hpm.ldcmStatus,
                liquidDetected: hpm.liquidDetected,
                mitigationsActive: hpm.mitigationsActive
            )
        }
    }

    // Build port entries for non-USB-C connectors (MagSafe, etc.)
    // These only have CC data, no PHY or TB. They use IDs starting at
    // 100 to avoid colliding with USB-C socket IDs.
    // systemPowerIn is the machine's total DC-in, not a per-port figure, so only
    // the connector actually carrying it may show it.
    //
    // The two USB-C signals are kept apart because they are not equally strong,
    // and treating them as one blanks a MagSafe port that is unambiguously the
    // charger:
    //
    // - `usbCHoldsNodeContract`: macOS published a USB-C contract. It is saying
    //   USB-C is the port being fed, and it outranks anything here.
    // - `usbCHasSMCEvidence`: an SMC channel resolves to a connected USB-C port.
    //   Enough to stop a merely-attached MagSafe cable claiming the figure, but
    //   NOT enough to overrule a MagSafe port holding its own winning contract,
    //   because that contract is macOS's own answer about this connector while
    //   the SMC channel is only evidence about the other one.
    private func buildNonUSBCPorts(
        _ ccEntries: [CCInput],
        chargerData: [ChargerInput],
        chargingPower: ChargingPowerInput? = nil,
        usbCHoldsNodeContract: Bool = false,
        usbCHasSMCEvidence: Bool = false,
        smcContractPorts: Set<Int> = []
    ) -> [PortState] {
        ccEntries.map { cc in
            let portType: PortType = cc.portType.lowercased().contains("magsafe") ? .magSafe : .usbC

            // The contract macOS published for this connector, when it did.
            //
            // A WINNING option only. ChargerReader falls back to the highest
            // entry in PowerSourceOptions when there is no winning one, and
            // flags that it did; those volts and amps are what the adapter can
            // offer, not what the two of them agreed on. The view labels this
            // field "Contract", so filling it from the fallback would report a
            // capability as an agreement, which is the same class of mistake as
            // the measured-input values this replaced.
            let negotiated = chargerData.first {
                $0.portType != "USB-C" && $0.portNumber == cc.portNumber && $0.hasWinningContract
            }

            // Show the wattage whenever this connector is the one delivering,
            // NOT only while the battery happens to be charging.
            //
            // The old rule required `isCharging`, so sitting at 100% on MagSafe
            // showed a connected port with no power at all, even though the
            // charger was still carrying the machine's whole running load. That
            // is not an edge case: 312 of 318 corpus machines that are plugged
            // in and not charging still report a positive systemPowerIn, 4 W to
            // 41 W of it. Optimised charging pausing at 80% reads the same way.
            //
            // "Delivering" is simply that USB-C is not, which makes double
            // attribution impossible by construction rather than by
            // observation. Keying it on this connector's OWN contract as well
            // was tempting and wrong: a MagSafe contract only changes the answer
            // when USB-C is taking power too, and in that single case it hands
            // the same watts to two cards. It cannot even be justified as
            // defensive, because `totalWattsIn` sums every incoming port, so
            // the menu bar total would double with it.
            //
            // The 11 of 84 not-charging corpus machines whose MagSafe node
            // publishes no contract are covered here, not by a contract check:
            // nothing says USB-C is taking power, so MagSafe is the only
            // candidate and gets the figure.
            //
            // When the evidence says USB-C is taking power but no figure can be
            // attributed to it (an SMC contract on a machine where a connected
            // MagSafe makes the SMC path decline), both cards stay blank. That
            // is deliberate: the alternative is putting the machine's whole
            // draw against a MagSafe cable that is only plugged in, and a wrong
            // port is worse than no number.
            //
            // A winning contract on THIS connector overrides that SMC evidence,
            // because it is macOS answering about this very port. It cannot
            // double-count: the SMC path declines outright while a MagSafe port
            // is connected, so it never puts a figure on USB-C in this state.
            //
            // Why the battery state is not consulted at all: `ChargingStatus`
            // already carries charging / fullyCharged / onHoldForHealth /
            // notCharging, and the detail view shows it on this very card. The
            // answer to "why isn't it charging" belongs there, not smuggled in
            // by blanking the wattage.
            var power: PortPower?
            let deliveringOnItsOwnEvidence = negotiated != nil || smcContractPorts.contains(cc.portNumber)
            let deliversPower = !usbCHoldsNodeContract
                && (deliveringOnItsOwnEvidence || !usbCHasSMCEvidence)
            if cc.active, deliversPower, let cp = chargingPower, cp.systemPowerIn > 0 {
                power = PortPower(
                    watts: Double(cp.systemPowerIn) / 1000.0,
                    current: cp.systemCurrentIn,
                    voltage: cp.systemVoltageIn,
                    // The negotiated contract, when macOS published one. This
                    // used to repeat the measured input under the "Contract"
                    // label, which reported a measurement as an agreement. With
                    // no contract to show, 0 leaves the row hidden rather than
                    // relabelling the figure already displayed beside it.
                    configuredVoltage: negotiated?.voltage ?? 0,
                    configuredCurrent: negotiated?.maxCurrent ?? 0,
                    vconnCurrent: 0,
                    vconnPower: 0,
                    vconnMaxCurrent: 0,
                    direction: .incoming,
                    // `negotiated` is filtered to hasWinningContract above, so
                    // when it is present it is macOS's own answer, not a guess.
                    contractIsEstimated: false
                )
            }

            return PortState(
                id: 100 + cc.portNumber,
                portType: portType,
                ccConnected: cc.active,
                power: power
            )
        }
    }

    private func buildPortState(
        portID: Int,
        phy: PhyInput?,
        tb: ThunderboltInput?,
        power: PowerInput?,
        ccActive: Bool
    ) -> PortState {
        let lane0 = parseLane(transport: phy?.lane0Transport, powerLevel: phy?.lane0PowerLevel, client: phy?.lane0Client)
        let lane1 = parseLane(transport: phy?.lane1Transport, powerLevel: phy?.lane1PowerLevel, client: phy?.lane1Client)
        let usb2Active = phy.map { !$0.usb2Transport.isEmpty } ?? false

        var tbLink: ThunderboltLinkState?
        if let tb, tb.currentLinkWidth > 0, tb.currentLinkSpeed > 0 {
            let gen = TBGeneration(speedCode: tb.currentLinkSpeed)
            let (tx, rx) = decodeLinkWidth(tb.currentLinkWidth)
            tbLink = ThunderboltLinkState(
                generation: gen,
                perLaneGbps: gen.perLaneGbps,
                txLanes: tx,
                rxLanes: rx
            )
        }

        var portPower: PortPower?
        if let pwr = power, pwr.watts > 0 {
            portPower = PortPower(
                watts: Double(pwr.watts) / 1000.0,
                current: pwr.current,
                voltage: pwr.adapterVoltage,
                configuredVoltage: pwr.configuredVoltage,
                configuredCurrent: pwr.configuredCurrent,
                vconnCurrent: pwr.vconnCurrent,
                vconnPower: pwr.vconnPower,
                vconnMaxCurrent: pwr.vconnMaxCurrent,
                direction: .outgoing,
                // Read straight from PowerOutDetails, macOS's own measurement.
                contractIsEstimated: false
            )
        }

        var state = PortState(
            id: portID,
            lane0: lane0,
            lane1: lane1,
            usb2Active: usb2Active,
            ccConnected: ccActive,
            thunderboltLink: tbLink,
            power: portPower
        )
        state.dpLinkRate = phy?.dpLinkRate ?? ""
        state.dpTunnelLinkRate = phy?.dpTunnel ?? ""
        return state
    }

    // Current Link Width is a bitmask, not a lane count.
    // From thunderbolt-fabric.md:
    //   0x1 = single lane (1 TX, 1 RX)
    //   0x2 = dual lane (2 TX, 2 RX)
    //   0x4 = asymmetric TX (3 TX, 1 RX) - TB5 only
    //   0x8 = asymmetric RX (1 TX, 3 RX) - TB5 only
    private func decodeLinkWidth(_ width: Int) -> (tx: Int, rx: Int) {
        switch width {
        case 0x1: return (1, 1)
        case 0x2: return (2, 2)
        case 0x4: return (3, 1)  // asymmetric TX
        case 0x8: return (1, 3)  // asymmetric RX
        default: return (1, 1)
        }
    }

    // Assembles a port's flat device list into a tree, pre-order (a device
    // is emitted before its children, and siblings keep enumeration order).
    // `devices` must already be scoped to a single port: this never
    // consults deviceData for any other port, so a locationID collision
    // across ports cannot make one port's tree pick up another's devices.
    private func buildDeviceTree(_ devices: [DeviceInput]) -> [USBDeviceInfo] {
        guard !devices.isEmpty else { return [] }

        let indexed = Array(devices.enumerated())
        let locationIDs = Set(devices.map(\.locationID))

        func isRoot(_ device: DeviceInput) -> Bool {
            guard let parentID = DeviceTree.parentLocationID(device.locationID) else { return true }
            return !locationIDs.contains(parentID)
        }

        func children(ofLocationID parentLocationID: Int) -> [(offset: Int, element: DeviceInput)] {
            indexed.filter { DeviceTree.parentLocationID($0.element.locationID) == parentLocationID }
        }

        func makeInfo(_ device: DeviceInput) -> USBDeviceInfo {
            let speed = device.speedCode > 0 ? USBSpeed(code: device.speedCode) : nil
            return USBDeviceInfo(
                productName: device.productName,
                vendorName: device.vendorName,
                serialNumber: device.serialNumber.isEmpty ? nil : device.serialNumber,
                speed: speed,
                usbVersion: formatBcdUSB(device.usbVersion),
                currentDraw: device.currentDraw,
                deviceClass: USBDeviceClass(code: device.deviceClass),
                hubDepth: DeviceTree.hubDepth(of: device, in: devices),
                viaName: DeviceTree.viaName(of: device, in: devices)
            )
        }

        // Tracks emitted array offsets, not locationIDs: duplicate
        // locationIDs within a slice must still each emit exactly once.
        var emitted = Set<Int>()
        var result: [USBDeviceInfo] = []

        func visit(_ offset: Int, _ device: DeviceInput) {
            guard !emitted.contains(offset) else { return }
            emitted.insert(offset)
            result.append(makeInfo(device))
            for (childOffset, childDevice) in children(ofLocationID: device.locationID) {
                visit(childOffset, childDevice)
            }
        }

        for (offset, device) in indexed where isRoot(device) {
            visit(offset, device)
        }

        return result
    }

    // bcdUSB is BCD-encoded: 0x0200 = 512 = USB 2.0, 0x0300 = 768 = USB 3.0,
    // 0x0310 = 784 = USB 3.1, 0x0320 = 800 = USB 3.2
    private func formatBcdUSB(_ bcd: Int) -> String {
        let major = bcd / 256
        let minor = (bcd % 256) / 16
        let patch = bcd % 16
        if patch > 0 {
            return "USB \(major).\(minor)\(patch)"
        }
        return "USB \(major).\(minor)"
    }

    private func parseLane(transport: String?, powerLevel: String?, client: String?) -> LaneState {
        let t = transport ?? ""
        let laneTransport: LaneTransport
        switch t.lowercased() {
        case "cio": laneTransport = .thunderbolt
        case "displayport": laneTransport = .displayPort
        case "usb3": laneTransport = .usb
        default: laneTransport = .idle
        }

        let power: PowerLevel = (powerLevel ?? "").lowercased() == "on" ? .on : .off

        return LaneState(
            transport: laneTransport,
            powerLevel: power,
            client: (client ?? "").isEmpty ? nil : client
        )
    }
}
