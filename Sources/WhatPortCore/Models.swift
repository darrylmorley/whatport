import Foundation

// All domain model types for WhatPort.
// These are pure value types with no IOKit or UI dependencies.

// MARK: - Port State

public struct PortState: Identifiable, Sendable {
    public let id: Int
    // Stable per-physical-port identity from the HPM controller (the "UUID"
    // property). Nil on Macs without an HPM node (Intel, desktop front ports)
    // or when the roster falls back to port-number correlation. Internal join
    // key only, never shown in the UI. Distinguishes MagSafe from USB-C when
    // they share the same port number.
    public var uuid: String?
    public var portType: PortType
    public var lane0: LaneState
    public var lane1: LaneState
    public var usb2Active: Bool
    public var ccConnected: Bool
    public var thunderboltLink: ThunderboltLinkState?
    public var power: PortPower?
    // Identity of the charger supplying this port (incoming power only).
    // Nil unless a charger is attached and AppleSmartBattery reports details.
    public var charger: ChargerInfo?
    public var deviceName: String?
    public var usbSpeed: USBSpeed?
    // Full device tree behind this port, pre-order (parents before
    // children, siblings in enumeration order). Empty when nothing is
    // attached or the port carries no USB data.
    public var usbDevices: [USBDeviceInfo] = []
    public var cable: CableInfo?
    public var portStats: PortStatistics?
    // USB-PD port-controller lifetime reliability counters. Nil on machines
    // without a PortControllerInfo array (desktops) or on MagSafe ports,
    // which never carry a positional entry. See PDReliabilityReader.
    public var pdReliability: PDReliabilityCounters?
    public var thunderboltCapability: ThunderboltCapability?
    // Raw DP link rate from PHY, e.g. "5.40Gbps/lane (HBR2)". Empty when
    // no DisplayPort connection is active on this port. Fallback; prefer
    // liveTransports when available.
    public var dpLinkRate: String = ""
    // Raw DP tunnel link rate from PHY, when DisplayPort is tunnelled over
    // CIO rather than running native alt mode. Same format as dpLinkRate,
    // empty when no tunnelled DP connection is active.
    public var dpTunnelLinkRate: String = ""

    // Health signals from the HPM port-controller node.
    // Nil on machines without an HPM node or when health data is unavailable.
    public var health: PortHealth?

    // Live transport state from IOPortTransportState* services.
    // One entry per active transport on this port (USB3, DP, CIO).
    public var liveTransports: [LiveTransport] = []

    // What the port controller has actually set up on this connection, and
    // anything macOS negotiated but then blocked. Nil on Macs without an HPM
    // node (Intel, pre-M3, desktop front ports). The authoritative answer to
    // "why doesn't my dock's USB / display work".
    public var transports: PortTransports?

    // Display native resolution (from IOKit display data, if a display is connected)
    public var displayWidth: Int = 0
    public var displayHeight: Int = 0

    // A port is active if any data transport is running or something is
    // physically connected on the CC line (e.g. a charger).
    public var isActive: Bool {
        lane0.transport != .idle || lane1.transport != .idle || usb2Active || ccConnected
    }

    // macOS can leave IOThunderboltPort's Current Link Speed/Width populated
    // long after the device is unplugged (observed on real hardware: a
    // trained link surviving 20 days of idle uptime). isActive alone is not
    // enough corroboration: CC merely proves something is physically
    // connected, and a plain USB-C PD charger trips CC too, resurfacing the
    // stale link. Either a PHY lane trained as Thunderbolt or an active CIO
    // transport (IOPortTransportStateCIO, surfaced here as a .thunderbolt
    // LiveTransport) proves the link is real: both are torn down with the
    // connection, unlike IOThunderboltPort's lingering values. PHY, TB and
    // CIO are read non-atomically, so a genuine link can briefly show CIO
    // active before the lane catches up (or vice versa); accepting either
    // signal avoids a one-poll misclassification during that window.
    public var hasLiveThunderboltLink: Bool {
        guard thunderboltLink != nil else { return false }
        if lane0.transport == .thunderbolt || lane1.transport == .thunderbolt { return true }
        return liveTransports.contains { $0.kind == .thunderbolt }
    }

    public var primaryProtocol: PortProtocol {
        if hasLiveThunderboltLink { return .thunderbolt }
        if lane0.transport == .displayPort || lane1.transport == .displayPort {
            return .displayPort
        }
        if lane0.transport == .usb || lane1.transport == .usb || usb2Active {
            return .usbOnly
        }
        if ccConnected {
            // MagSafe is charge-only: a connection is always a charger,
            // even when the battery is full and no live wattage is shown.
            if portType == .magSafe { return .charging }
            // USB-C: only a negotiated power contract makes it a charger.
            // A bare cable with nothing on the other end also trips the CC
            // line but carries no power and no data, so treat it as idle
            // rather than a phantom charger. Without this, an empty lead
            // reads as a charging port and inherits the system battery
            // state (e.g. "Battery Full").
            return power != nil ? .charging : .idle
        }
        return .idle
    }

    public init(
        id: Int,
        uuid: String? = nil,
        portType: PortType = .usbC,
        lane0: LaneState = .idle,
        lane1: LaneState = .idle,
        usb2Active: Bool = false,
        ccConnected: Bool = false,
        thunderboltLink: ThunderboltLinkState? = nil,
        power: PortPower? = nil,
        deviceName: String? = nil,
        usbSpeed: USBSpeed? = nil,
        cable: CableInfo? = nil,
        portStats: PortStatistics? = nil,
        thunderboltCapability: ThunderboltCapability? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.portType = portType
        self.lane0 = lane0
        self.lane1 = lane1
        self.usb2Active = usb2Active
        self.ccConnected = ccConnected
        self.thunderboltLink = thunderboltLink
        self.power = power
        self.deviceName = deviceName
        self.usbSpeed = usbSpeed
        self.cable = cable
        self.portStats = portStats
        self.thunderboltCapability = thunderboltCapability
    }

    // The device the free tier fronts. Hubs enumerate before anything behind
    // them, so "first" is nearly always the hub on a multi-port hub or dock;
    // prefer the first real device in tree order and fall back to a hub only
    // when hubs are all the port has.
    public var usbDevice: USBDeviceInfo? {
        usbDevices.first { $0.deviceClass != .hub } ?? usbDevices.first
    }

    // Stable identity for the event pipeline. usbDevice (above) is what the UI
    // fronts and can flip from hub to child as a tree enumerates over
    // successive polls; connect/disconnect matching must not key off that. The
    // tree's root enumerates first and stays put for the life of the
    // connection, so it is used here instead. displayWidth/displayHeight are
    // only ever populated alongside a display name, so their presence marks
    // the display branch and keeps its priority, matching deviceName's own
    // precedence. Falls back to deviceName when there is no tree to draw a
    // root from, so callers that only set deviceName still get a usable
    // identity. Nil when the port has no name at all.
    //
    // Known residual: with two independent roots on one port (a registry
    // anomaly), usbDevices.first is only as stable as IOKit's iteration
    // order, so the identity could still flip there. Accepted as rare on
    // top of rare; the coalescer's nil-leniency does not cover it.
    public var eventIdentityName: String? {
        if displayWidth != 0 || displayHeight != 0 { return deviceName }
        if let root = usbDevices.first { return root.productName }
        return deviceName
    }

    // "+N more" for the free tier: real devices beyond the fronted one.
    // Hubs are plumbing, not something the user plugged in, so they are
    // not counted.
    public var additionalDeviceCount: Int {
        guard usbDevice != nil else { return 0 }
        let realDevices = usbDevices.filter { $0.deviceClass != .hub }
        guard realDevices.count > 0 else { return 0 }
        // Once realDevices is non-empty, usbDevice is guaranteed non-hub: it
        // only resolves to a hub when every device on the port is a hub, and
        // that would make realDevices empty (guarded above). So usbDevice is
        // always one of realDevices here, and the count beyond it is simply
        // realDevices.count - 1.
        return max(0, realDevices.count - 1)
    }
}

// Shared "has this port actually resolved to something live" predicate, used
// both by PortManager.applySnapshot (to reconcile the lifecycle machine) and
// applyLifecycleSignal (to suppress a stale repeat signal from regressing an
// already-connected port). Kept as one definition so the two call sites can't
// drift apart.
extension PortState {
    public var isLifecycleResolved: Bool {
        primaryProtocol != .idle || deviceName != nil
    }
}

// MARK: - Port Health

public enum HealthSeverity: Sendable, Equatable {
    case ok, warning, serious
}

// Health signals from the HPM port-controller node.
// Present only when the HPM layer is available (Apple Silicon, M1+).
public struct PortHealth: Sendable, Equatable {
    public var overcurrentCount: Int
    public var plugEventCount: Int
    public var connectionCount: Int
    public var authorizationStatus: String
    public var ldcmStatus: String
    // Liquid detection (LDCM, M3+). liquidDetected is the definitive wet flag;
    // mitigationsActive means macOS has restricted the port to limit damage.
    public var liquidDetected: Bool
    public var mitigationsActive: Bool

    // .serious when liquid has been detected or overcurrents recorded.
    // .warning when LDCM reports an error string.
    // .ok otherwise.
    public var severity: HealthSeverity {
        if liquidDetected { return .serious }
        if overcurrentCount > 0 { return .serious }
        if !ldcmStatus.isEmpty && ldcmStatus != "No Error" { return .warning }
        return .ok
    }

    public var isHealthy: Bool { severity == .ok }

    public init(
        overcurrentCount: Int = 0,
        plugEventCount: Int = 0,
        connectionCount: Int = 0,
        authorizationStatus: String = "",
        ldcmStatus: String = "",
        liquidDetected: Bool = false,
        mitigationsActive: Bool = false
    ) {
        self.overcurrentCount = overcurrentCount
        self.plugEventCount = plugEventCount
        self.connectionCount = connectionCount
        self.authorizationStatus = authorizationStatus
        self.ldcmStatus = ldcmStatus
        self.liquidDetected = liquidDetected
        self.mitigationsActive = mitigationsActive
    }
}

// MARK: - Lane State

public struct LaneState: Sendable, Equatable {
    public var transport: LaneTransport
    public var powerLevel: PowerLevel
    public var client: String?

    public static let idle = LaneState(transport: .idle, powerLevel: .off, client: nil)

    public init(transport: LaneTransport, powerLevel: PowerLevel, client: String?) {
        self.transport = transport
        self.powerLevel = powerLevel
        self.client = client
    }
}

public enum LaneTransport: Sendable, Equatable {
    case thunderbolt
    case displayPort
    case usb
    case idle
}

public enum PowerLevel: Sendable, Equatable {
    case on
    case off
}

// MARK: - Thunderbolt Link

public struct ThunderboltLinkState: Sendable, Equatable {
    public var generation: TBGeneration
    public var perLaneGbps: Int
    public var txLanes: Int
    public var rxLanes: Int
    public var totalGbps: Int
    public var deviceName: String?
    public var deviceVendor: String?

    public init(
        generation: TBGeneration,
        perLaneGbps: Int,
        txLanes: Int,
        rxLanes: Int,
        deviceName: String? = nil,
        deviceVendor: String? = nil
    ) {
        self.generation = generation
        self.perLaneGbps = perLaneGbps
        self.txLanes = txLanes
        self.rxLanes = rxLanes
        self.totalGbps = perLaneGbps * txLanes
        self.deviceName = deviceName
        self.deviceVendor = deviceVendor
    }
}

public enum TBGeneration: Sendable, Equatable {
    case tb3
    case tb4
    case tb5

    // Maps IOKit "Current Link Speed" register values to generation.
    // Lower value = faster. From thunderbolt-fabric.md research:
    // 0x2 = Gen 4 / TB5 (40 Gbps/lane)
    // 0x4 = Gen 3 / TB4 (20 Gbps/lane)
    // 0x8 = Gen 2 / TB3 (10 Gbps/lane)
    //
    // This is for "Current Link Speed" only, which is always a single code.
    // For "Supported Link Speed" (a bitmask) use init(supportedSpeedMask:),
    // and for static port capability prefer init(thunderboltVersion:).
    public init(speedCode: Int) {
        switch speedCode {
        case 0x2: self = .tb5
        case 0x4: self = .tb4
        case 0x8: self = .tb3
        default: self = .tb4
        }
    }

    // Maps the IOKit "Thunderbolt Version" controller constant to generation.
    // From thunderbolt-fabric.md research:
    // 64 = Type7 (TB5), 32 = Type5 (TB4), 16 = Intel Type3/Type4 (TB3)
    // This is the most stable capability signal: it is present even when the
    // port is idle, unlike the negotiated link/supported-speed fields.
    // Returns nil for unknown values so callers can fall back.
    public init?(thunderboltVersion: Int) {
        switch thunderboltVersion {
        case 64: self = .tb5
        case 32: self = .tb4
        case 16: self = .tb3
        default: return nil
        }
    }

    // Maps the IOKit "Supported Link Speed" bitmask to the highest generation.
    // Unlike "Current Link Speed", this field ORs together every speed the
    // controller supports (e.g. 0x4 | 0x8 = 12 for a TB4 controller,
    // 0x2 | 0x4 | 0x8 = 14 for TB5). We pick the fastest bit that is set.
    // Returns nil when no known bit is set so callers can fall back.
    public init?(supportedSpeedMask: Int) {
        if supportedSpeedMask & 0x2 != 0 { self = .tb5 }
        else if supportedSpeedMask & 0x4 != 0 { self = .tb4 }
        else if supportedSpeedMask & 0x8 != 0 { self = .tb3 }
        else { return nil }
    }

    public var label: String {
        switch self {
        case .tb3: return "TB3"
        case .tb4: return "TB4"
        case .tb5: return "TB5"
        }
    }

    public var perLaneGbps: Int {
        switch self {
        case .tb3: return 10
        case .tb4: return 20
        case .tb5: return 40
        }
    }
}

// MARK: - Port Power

// Which way power is flowing across the port, from the Mac's point of view.
//   .incoming - a charger or powered dock is delivering power INTO the Mac.
//   .outgoing - the Mac is sourcing power OUT to a bus-powered device.
// Summing the two is meaningless (they are opposite directions), so the UI
// reports them separately rather than as one total.
public enum PowerDirection: Sendable, Equatable {
    case incoming
    case outgoing
}

public struct PortPower: Sendable, Equatable {
    public var watts: Double
    public var current: Int
    public var voltage: Int
    public var configuredVoltage: Int
    public var configuredCurrent: Int
    public var vconnCurrent: Int
    // Power and max current sourced over VConn to an active (powered) cable's
    // e-marker chip. Zero on a passive cable. Disclosed factually in the UI
    // (the cable is active) with no grading of cable quality; that judgement
    // is WhatCable's territory, not this app's.
    public var vconnPower: Int
    public var vconnMaxCurrent: Int
    public var direction: PowerDirection
    // True when the contract (voltage/current) shown was attributed rather
    // than read from a macOS-published node: the SMCContractAttribution
    // fallback on M1 Pro/Max/Ultra, or a charger node macOS published without
    // a winning contract. The wattage above is always a real measurement;
    // only the contract figures are in question when this is true.
    public var contractIsEstimated: Bool

    public init(
        watts: Double,
        current: Int,
        voltage: Int,
        configuredVoltage: Int,
        configuredCurrent: Int,
        vconnCurrent: Int,
        vconnPower: Int = 0,
        vconnMaxCurrent: Int = 0,
        direction: PowerDirection = .outgoing,
        contractIsEstimated: Bool = false
    ) {
        self.watts = watts
        self.current = current
        self.voltage = voltage
        self.configuredVoltage = configuredVoltage
        self.configuredCurrent = configuredCurrent
        self.vconnCurrent = vconnCurrent
        self.vconnPower = vconnPower
        self.vconnMaxCurrent = vconnMaxCurrent
        self.direction = direction
        self.contractIsEstimated = contractIsEstimated
    }
}

// MARK: - Charger Identity

// One advertised power option from the charger's USB-PD menu.
public struct ChargerPDO: Sendable, Equatable {
    public var voltageMV: Int
    public var currentMA: Int

    public var watts: Double { Double(voltageMV) * Double(currentMA) / 1_000_000.0 }

    public init(voltageMV: Int, currentMA: Int) {
        self.voltageMV = voltageMV
        self.currentMA = currentMA
    }
}

// Identity of the charger / power adapter currently supplying the Mac, from
// AppleSmartBattery.AdapterDetails. Apple bricks report a full name and
// manufacturer; third-party PD chargers usually only report a generic
// description. `pdos` is the charger's full advertised menu, so we can show
// "supports up to 100W" even when little is being drawn. Laptop-only (no
// battery controller on desktops).
public struct ChargerInfo: Sendable, Equatable {
    public var name: String          // "96W USB-C Power Adapter" / "PD charger"
    public var manufacturer: String  // "Apple Inc." or empty
    public var maxWatts: Int         // watts (from AdapterDetails)
    public var pdos: [ChargerPDO]    // advertised voltage/current menu

    public var isApple: Bool { manufacturer.lowercased().contains("apple") }

    public init(
        name: String,
        manufacturer: String = "",
        maxWatts: Int = 0,
        pdos: [ChargerPDO] = []
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.maxWatts = maxWatts
        self.pdos = pdos
    }
}

// MARK: - Port Type (physical connector)

public enum PortType: Sendable, Equatable {
    case usbC
    case magSafe

    public var label: String {
        switch self {
        case .usbC: return "USB-C"
        case .magSafe: return "MagSafe"
        }
    }
}

// MARK: - USB Speed

public enum USBSpeed: Sendable, Equatable {
    case lowSpeed       // 1.5 Mbps
    case fullSpeed      // 12 Mbps
    case highSpeed      // 480 Mbps (USB 2.0)
    case superSpeed     // 5 Gbps (USB 3.0)
    case superSpeedPlus // 10 Gbps (USB 3.2 Gen 2)
    case superSpeed2x2  // 20 Gbps (USB 3.2 Gen 2x2)

    public init(code: Int) {
        switch code {
        case 0: self = .lowSpeed
        case 1: self = .fullSpeed
        case 2: self = .highSpeed
        case 3: self = .superSpeed
        case 4: self = .superSpeedPlus
        case 5: self = .superSpeed2x2
        default: self = .fullSpeed
        }
    }

    public var label: String {
        switch self {
        case .lowSpeed: return "1.5 Mbps"
        case .fullSpeed: return "12 Mbps"
        case .highSpeed: return "480 Mbps"
        case .superSpeed: return "5 Gbps"
        case .superSpeedPlus: return "10 Gbps"
        case .superSpeed2x2: return "20 Gbps"
        }
    }
}

// MARK: - USB Device Class

// bDeviceClass, but only the values reliable when read straight off the
// device descriptor. Class 0x00 means "look at each interface instead",
// which is a real ambiguity we cannot resolve without walking interface
// descriptors we do not read, so it and anything unmapped decode to nil
// rather than a guessed label.
public enum USBDeviceClass: Sendable, Equatable {
    case hub
    case audio
    case video
    case massStorage
    case smartCard
    case billboard
    case wireless
    case miscellaneous
    case vendorSpecific

    public init?(code: Int) {
        switch code {
        case 0x09: self = .hub
        case 0x01: self = .audio
        case 0x0E: self = .video
        case 0x08: self = .massStorage
        case 0x0B: self = .smartCard
        case 0x11: self = .billboard
        case 0xE0: self = .wireless
        case 0xEF: self = .miscellaneous
        case 0xFF: self = .vendorSpecific
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .hub: return "Hub"
        case .audio: return "Audio"
        case .video: return "Video"
        case .massStorage: return "Storage"
        case .smartCard: return "Smart card"
        case .billboard: return "Billboard"
        case .wireless: return "Wireless"
        case .miscellaneous: return "Miscellaneous"
        case .vendorSpecific: return "Vendor-specific"
        }
    }
}

// MARK: - USB Device Info

public struct USBDeviceInfo: Sendable, Equatable {
    public var productName: String
    public var vendorName: String
    public var serialNumber: String?
    public var speed: USBSpeed?
    public var usbVersion: String    // "USB 3.2", "USB 2.0", etc.
    public var currentDraw: Int      // mA allocated by host
    public var deviceClass: USBDeviceClass?
    // Depth in the port's device tree (0 = directly attached).
    public var hubDepth: Int = 0
    // Product name of the enclosing hub or dock, nil at depth 0.
    public var viaName: String? = nil

    public init(
        productName: String,
        vendorName: String,
        serialNumber: String? = nil,
        speed: USBSpeed? = nil,
        usbVersion: String = "",
        currentDraw: Int = 0,
        deviceClass: USBDeviceClass? = nil,
        hubDepth: Int = 0,
        viaName: String? = nil
    ) {
        self.productName = productName
        self.vendorName = vendorName
        self.serialNumber = serialNumber
        self.speed = speed
        self.usbVersion = usbVersion
        self.currentDraw = currentDraw
        self.deviceClass = deviceClass
        self.hubDepth = hubDepth
        self.viaName = viaName
    }
}

// MARK: - Cable Info

public struct CableInfo: Sendable, Equatable {
    public var productType: String   // "Passive Cable", "Active Cable"
    public var pdRevision: Int       // USB PD Specification Revision (1, 2, 3)

    public init(productType: String, pdRevision: Int = 0) {
        self.productType = productType
        self.pdRevision = pdRevision
    }
}

// MARK: - Port Statistics

public struct PortStatistics: Sendable, Equatable {
    public var connectCount: Int
    public var overcurrentCount: Int
    public var enumerationFailureCount: Int
    public var addressFailureCount: Int
    public var linkErrorCount: Int
    public var remoteWakeCount: Int

    public init(
        connectCount: Int = 0,
        overcurrentCount: Int = 0,
        enumerationFailureCount: Int = 0,
        addressFailureCount: Int = 0,
        linkErrorCount: Int = 0,
        remoteWakeCount: Int = 0
    ) {
        self.connectCount = connectCount
        self.overcurrentCount = overcurrentCount
        self.enumerationFailureCount = enumerationFailureCount
        self.addressFailureCount = addressFailureCount
        self.linkErrorCount = linkErrorCount
        self.remoteWakeCount = remoteWakeCount
    }
}

// MARK: - PD Reliability Counters

// USB-PD port-controller lifetime reliability counters, read from
// AppleSmartBattery.PortControllerInfo (see PDReliabilityReader). USB-C
// only, joined positionally by physical port number.
public struct PDReliabilityCounters: Sendable, Equatable {
    public var attachCount: Int
    public var detachCount: Int
    // Two distinct hard-reset counters the controller keeps; they are not
    // additive (both fire for the same reset from different vantage
    // points), so consumers use effectiveHardResetCount rather than summing.
    public var hardResetCount: Int
    public var irqHardResetCount: Int
    public var shortDetectCount: Int
    public var dataRoleSwapFailCount: Int
    public var powerRoleSwapFailCount: Int
    public var i2cErrorCount: Int

    public var effectiveHardResetCount: Int { max(hardResetCount, irqHardResetCount) }

    public init(
        attachCount: Int = 0,
        detachCount: Int = 0,
        hardResetCount: Int = 0,
        irqHardResetCount: Int = 0,
        shortDetectCount: Int = 0,
        dataRoleSwapFailCount: Int = 0,
        powerRoleSwapFailCount: Int = 0,
        i2cErrorCount: Int = 0
    ) {
        self.attachCount = attachCount
        self.detachCount = detachCount
        self.hardResetCount = hardResetCount
        self.irqHardResetCount = irqHardResetCount
        self.shortDetectCount = shortDetectCount
        self.dataRoleSwapFailCount = dataRoleSwapFailCount
        self.powerRoleSwapFailCount = powerRoleSwapFailCount
        self.i2cErrorCount = i2cErrorCount
    }
}

// MARK: - Thunderbolt Capability

// Port-level TB capability (always present for TB-capable ports,
// even when no device is connected and no link is active).
public struct ThunderboltCapability: Sendable, Equatable {
    public var supportedLinkSpeed: Int   // speed bitmask (12 = TB4, 14 = TB5)
    public var supportedLinkWidth: Int   // max width code (2 = dual-lane)
    public var thunderboltVersion: Int

    // Prefer the static "Thunderbolt Version" constant: it reports the
    // controller's true ceiling even when the port is idle. Fall back to the
    // supported-speed bitmask, then to TB4 as a last resort.
    public var maxGeneration: TBGeneration {
        TBGeneration(thunderboltVersion: thunderboltVersion)
            ?? TBGeneration(supportedSpeedMask: supportedLinkSpeed)
            ?? .tb4
    }

    // "Supported Link Width" is a bitmask: BIT(0)=0x1 single-lane, BIT(1)=0x2
    // dual-lane. A TB5 port reports 3 (0x1|0x2), meaning it supports both.
    // Pick the highest width bit that is set, same approach as init(supportedSpeedMask:).
    public var maxLanes: Int {
        if supportedLinkWidth & 0x2 != 0 { return 2 }
        return 1
    }

    public init(
        supportedLinkSpeed: Int = 0,
        supportedLinkWidth: Int = 0,
        thunderboltVersion: Int = 0
    ) {
        self.supportedLinkSpeed = supportedLinkSpeed
        self.supportedLinkWidth = supportedLinkWidth
        self.thunderboltVersion = thunderboltVersion
    }
}

// MARK: - Live Transport State

// Real-time link data from IOPortTransportState* services.
// One per active transport on a port. Updated on every snapshot.
public struct LiveTransport: Sendable, Equatable {
    public var kind: LaneTransport       // .usb, .displayPort, .thunderbolt
    public var dataRate: String          // "10 Gbps", "5.4 Gbps (HBR2)"
    public var generation: String        // "Gen 2", "USB 3.x" (USB only)
    public var laneCount: Int            // DP only; 0 otherwise
    public var maxLaneCount: Int         // DP only
    public var tunneled: Bool
    // macOS Transport Restriction Mode has blocked data on this link.
    // The link still reports a signaling speed, but no data flows until the
    // device is authorised. Surface this so a blocked port is not mistaken
    // for a healthy one. USB only; always false for DP/Thunderbolt.
    public var restricted: Bool
    // Number of displays driven over this link. DP only; 0 otherwise.
    // More than one means a daisy-chained or MST-hub setup.
    public var sinkCount: Int
    // Identity of a DisplayPort branch device (MST hub or protocol converter)
    // in the chain, e.g. "Dp1.2". Empty when the display connects directly.
    public var branchDevice: String
    // Downstream-facing port type when the chain converts to another standard,
    // e.g. "HDMI". Empty for native DisplayPort. DP only.
    public var dfpType: String

    public init(
        kind: LaneTransport,
        dataRate: String = "",
        generation: String = "",
        laneCount: Int = 0,
        maxLaneCount: Int = 0,
        tunneled: Bool = false,
        restricted: Bool = false,
        sinkCount: Int = 0,
        branchDevice: String = "",
        dfpType: String = ""
    ) {
        self.kind = kind
        self.dataRate = dataRate
        self.generation = generation
        self.laneCount = laneCount
        self.maxLaneCount = maxLaneCount
        self.tunneled = tunneled
        self.restricted = restricted
        self.sinkCount = sinkCount
        self.branchDevice = branchDevice
        self.dfpType = dfpType
    }
}

// MARK: - Port Transports

// Which transports the port controller has provisioned (set up) for the
// current connection, which it blocked, and - for a Thunderbolt/USB4 link -
// which protocols are tunnelled over it.
//
// `provisioned` / `unauthorized` come from the HPM port controller (M3+).
// `tunnelProvisioned` / `tunnelSupported` come from the CIO link (any TB link).
// Transport names are IOKit's own strings, e.g. "USB2", "USB3", "DP",
// "DisplayPort", "CIO", "PCIe".
public struct PortTransports: Sendable, Equatable {
    public var provisioned: [String]
    public var unauthorized: [String]
    public var tunnelProvisioned: [String]
    public var tunnelSupported: [String]

    // True when there is at least one transport fact worth showing.
    public var hasData: Bool {
        !provisioned.isEmpty || !unauthorized.isEmpty || !tunnelProvisioned.isEmpty
    }

    public init(
        provisioned: [String] = [],
        unauthorized: [String] = [],
        tunnelProvisioned: [String] = [],
        tunnelSupported: [String] = []
    ) {
        self.provisioned = provisioned
        self.unauthorized = unauthorized
        self.tunnelProvisioned = tunnelProvisioned
        self.tunnelSupported = tunnelSupported
    }
}

// MARK: - Charging Status

// The Mac's charging state when a charger is connected. Answers "why isn't my
// Mac charging?" without guessing: it is derived from reliable AppleSmartBattery
// fields (IsCharging, FullyCharged) plus the two NotChargingReason bits whose
// meaning is verified against the WhatCable corpus. Every other NotChargingReason
// value reports generically (.notCharging) rather than a guessed reason.
public enum ChargingStatus: Sendable, Equatable {
    case charging          // actively charging
    case fullyCharged      // battery is full
    case onHoldForHealth   // plugged in and capable, deliberately held below
                           // full (Optimized Battery Charging or an 80% limit)
    case notCharging       // plugged in, not charging, no reliably-known reason

    // NotChargingReason bits verified to mean "deliberate battery-health hold":
    // bit 24 (0x1000000) and bit 55. Across the corpus both appear only when the
    // Mac is plugged in, charge-capable, not full, and sitting at roughly 80%.
    // Higher bits and others are not reliably decoded and are treated generically.
    static let healthHoldMask: Int = (1 << 24) | (1 << 55)

    public init(isCharging: Bool, fullyCharged: Bool, notChargingReason: Int) {
        if isCharging {
            self = .charging
        } else if fullyCharged {
            self = .fullyCharged
        } else if (notChargingReason & ChargingStatus.healthHoldMask) != 0 {
            self = .onHoldForHealth
        } else {
            self = .notCharging
        }
    }
}

// MARK: - Protocol Classification

public enum PortProtocol: Sendable, Equatable, Codable {
    case thunderbolt
    case displayPort
    case usbOnly
    case charging
    case idle
}

// MARK: - Port Data Tier

// How much of the port roster this Mac actually reported, driven entirely by
// which correlate() roster branch resolved (see PortManager). Not an "is this
// Intel" flag: an HPM-less Apple Silicon Mac would report the same
// .thunderboltOnly tier as an Intel Mac, and the UI wording is written to stay
// true either way (see PortListView's reduced banner).
public enum PortDataTier: Sendable, Equatable {
    case unknown          // no snapshot applied yet
    case full             // roster from the HPM port-controller layer, or the PHY fallback
    case thunderboltOnly  // roster from Thunderbolt socket IDs only, no HPM data
    case none             // a snapshot arrived and no roster source had data

    // How much detail this tier can show, most first. Orders the tiers so
    // PortManager can tell an upgrade from a downgrade and hold the latter
    // back until a second snapshot agrees. `unknown` ranks last, so the first
    // snapshot of any kind reads as an upgrade and lands immediately.
    var detailRank: Int {
        switch self {
        case .full: return 0
        case .thunderboltOnly: return 1
        case .none: return 2
        case .unknown: return 3
        }
    }
}
