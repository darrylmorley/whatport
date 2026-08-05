import Foundation
import IOKit

// Reads connected USB device info from IOUSBHostDevice services.
//
// Each USB device's parent is a USB port (AppleUSB30XHCIARMPort or
// AppleUSB20XHCIARMPort) which has "UsbCPortNumber" mapping directly
// to the physical USB-C port. One level up, no tree walking needed.
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

            // Prefer the device-tree "port-number" from the usb-drd node: it
            // is the true physical port (matching the HPM @N and the rest of
            // the port roster). The XHCI "UsbCPortNumber" numbers ports
            // sequentially (1/2/3) and disagrees with the physical numbering
            // (1/2/4) on Macs that skip a port, so a device on physical port 4
            // would otherwise be tied to a non-existent port 3 and dropped.
            // Fall back to UsbCPortNumber only when port-number isn't reachable.
            let portNumber = ioFirstAncestorDataInt(service, key: "port-number", maxLevels: 10)
                ?? ioInt(ioParentProperty(service, key: "UsbCPortNumber")).nonZero
                ?? 0

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

// Small helper to treat 0 as nil for optional chaining.
private extension Int {
    var nonZero: Int? { self != 0 ? self : nil }
}
