import Foundation
import IOKit

// Reads connected USB device info from IOUSBHostDevice services.
//
// Each device is resolved to a physical port by walking up its IOService-plane
// ancestors: "UsbIOPort" is a registry path straight to the HPM port node, so
// it joins directly to the roster the rest of the app builds, and it can sit
// many levels above a device behind cascaded hubs. Where that isn't published
// (macOS 15), the device-tree "port-number" on a closer ancestor is the
// fallback. See the resolution comment in readUSBDevices() and
// PortStatsReader.physicalPortNumber(of:) for the fuller reasoning, including
// why UsbCPortNumber is not consulted at all.
//
// Device Speed values (from IOUSBHostFamily):
//   0 = Low Speed (1.5 Mbps)
//   1 = Full Speed (12 Mbps)
//   2 = High Speed (480 Mbps, USB 2.0)
//   3 = Super Speed (5 Gbps, USB 3.0)
//   4 = Super Speed Plus (10 Gbps, USB 3.2 Gen 2)
//   5 = Super Speed Plus (20 Gbps, USB 3.2 Gen 2x2)

public struct RawDeviceInfo: Sendable {
    public let portNumber: Int       // physical USB-C port
    public let productName: String
    public let vendorName: String
    public let speedCode: Int        // Device Speed enum value
    public let usbVersion: Int       // bcdUSB (e.g. 800 = USB 3.2)
    public let deviceClass: Int      // bDeviceClass (8 = storage, etc.)
    public let currentDraw: Int      // UsbPowerSinkAllocation in mA
    public let serialNumber: String  // kUSBSerialNumberString (hex-encoded)
}

public enum DeviceReader {
    public static func readUSBDevices() -> [RawDeviceInfo] {
        var results: [RawDeviceInfo] = []
        var seen = Set<Int>()

        withMatchingServices(className: "IOUSBHostDevice") { service in
            guard let props = ioProperties(service) else { return }

            let productName = ioString(props["USB Product Name"])
            guard !productName.isEmpty else { return }

            // Dedup by locationID (same device appears at multiple levels)
            let locationID = ioInt(props["locationID"])
            guard locationID > 0, !seen.contains(locationID) else { return }
            seen.insert(locationID)

            // Primary: "UsbIOPort" is a registry path straight to the HPM port
            // node, so it joins directly to the roster the rest of the app
            // builds. A device behind cascaded hubs can carry it many levels
            // up: corpus probe 38's deepest match sits at ancestor index 12,
            // which is walk level 13 here (probe 38 indexes from the parent,
            // this walk from the device itself; one hub tier is 3 registry
            // nodes), so 15 leaves two levels of headroom. This bound is
            // deliberately wider than
            // PortStatsReader's root-port walk (6), which starts much closer
            // to the HPM node.
            //
            // Fallback: the device-tree "port-number" on a usb-drd ancestor,
            // load-bearing on macOS 15, which publishes UsbIOPort nowhere.
            //
            // UsbCPortNumber is not consulted. It numbers ports sequentially
            // (1/2/3) and disagrees with the physical numbering (1/2/4) on
            // Macs that skip a port, which misattributed 60 of 1426 corpus
            // records. PortStatsReader.physicalPortNumber(of:) made the same
            // call for the same reason.
            //
            // When neither resolves, skip the device rather than record it
            // against a fabricated port 0: PortManager silently dropped those
            // records anyway, so this is the same outcome made explicit.
            guard let portNumber = ioFirstAncestorString(service, key: "UsbIOPort", maxLevels: 15)
                .flatMap(PortStatsReader.usbCPortNumber(fromPath:))
                ?? ioFirstAncestorDataInt(service, key: "port-number", maxLevels: 10),
                portNumber > 0
            else { return }

            if let device = parse(properties: props, portNumber: portNumber) {
                results.append(device)
            }
        }

        return results
    }

    // The device-info extraction rules, given one device's properties and the
    // physical port number the walk resolved from ancestor device-tree nodes.
    // Split out from the registry walk so recorded/synthetic properties can be
    // replayed through it directly.
    //
    // portNumber comes in rather than being read here because it lives on
    // ancestor nodes, not on the device itself.
    static func parse(properties: [String: Any], portNumber: Int) -> RawDeviceInfo? {
        let productName = ioString(properties["USB Product Name"])
        guard !productName.isEmpty else { return nil }

        return RawDeviceInfo(
            portNumber: portNumber,
            productName: productName,
            vendorName: ioString(properties["USB Vendor Name"]),
            // "Device Speed" (IOUSBHostDevice's own enum), not the differently
            // numbered "USBSpeed" BOS descriptor field. See
            // DeviceReaderTests.deviceReaderReadsDeviceSpeedNotBOSUSBSpeed.
            speedCode: ioInt(properties["Device Speed"]),
            usbVersion: ioInt(properties["bcdUSB"]),
            deviceClass: ioInt(properties["bDeviceClass"]),
            currentDraw: ioInt(properties["UsbPowerSinkAllocation"]),
            serialNumber: ioString(properties["kUSBSerialNumberString"])
        )
    }
}
