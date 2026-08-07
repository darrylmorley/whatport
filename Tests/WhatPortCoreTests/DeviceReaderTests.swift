import Testing
@testable import WhatPortIOKit

// DeviceReader.parse reads the device-level fields off IOUSBHostDevice
// properties. Split out from the registry walk so recorded/synthetic
// dictionaries can be replayed through it directly.

@Test func deviceReaderParsesCoreFields() throws {
    let properties: [String: Any] = [
        "USB Product Name": "Anker USB-C Hub",
        "USB Vendor Name": "Anker",
        "Device Speed": 4,
        "bcdUSB": 0x0320,
        "bDeviceClass": 0x09,
        "UsbPowerSinkAllocation": 900,
        "kUSBSerialNumberString": "ABC123"
    ]

    let device = try #require(DeviceReader.parse(properties: properties, portNumber: 2))

    #expect(device.portNumber == 2)
    #expect(device.productName == "Anker USB-C Hub")
    #expect(device.vendorName == "Anker")
    #expect(device.speedCode == 4)
    #expect(device.usbVersion == 0x0320)
    #expect(device.deviceClass == 0x09)
    #expect(device.currentDraw == 900)
    #expect(device.serialNumber == "ABC123")
}

@Test func deviceReaderReturnsNilWithoutAProductName() {
    #expect(DeviceReader.parse(properties: [:], portNumber: 1) == nil)
}

// IOUSBHostDevice publishes TWO differently-scoped speed enums with almost
// identical names: "Device Speed" (what DeviceReader must read; matches
// Models.USBSpeed's table) and "USBSpeed" (the BOS descriptor's own field,
// with a DIFFERENT numbering: 1=FS, 2=HS, 3=HS, 4=SS, 5=SSPlus). A dictionary
// carrying both, with different values, pins that the reader takes
// "Device Speed" and never falls back to the other one. A future refactor
// that swaps the property name would silently mislabel every SuperSpeed+
// device without this.
@Test func deviceReaderReadsDeviceSpeedNotBOSUSBSpeed() throws {
    let properties: [String: Any] = [
        "USB Product Name": "Test Device",
        "Device Speed": 3,   // SuperSpeed, 5 Gbps
        "USBSpeed": 5        // BOS field: would read as SuperSpeedPlus if used
    ]

    let device = try #require(DeviceReader.parse(properties: properties, portNumber: 1))
    #expect(device.speedCode == 3)
}

// Live: end-to-end over the real registry, the only automated coverage of
// readUSBDevices()'s ancestor walks (the corpus sweep exercises the path
// parser, not the walk). Two properties must hold on any Mac:
//   1. No fabricated ports. The resolver skips a device it cannot place, so
//      port 0 must never appear.
//   2. No wrong-card attribution. A resolved port within the roster's range
//      must be a port the roster actually has; the old sequential fallback
//      broke exactly this (device on physical port 4 filed under 3). Ports
//      beyond the roster's range are allowed: some machines wire extra ports
//      through discrete controllers (e.g. ASMedia) the HPM roster never
//      enumerates, and PortManager drops those joins harmlessly.
@Test func liveDevicePortsJoinTheRoster() {
    let devices = DeviceReader.readUSBDevices()

    for device in devices {
        #expect(device.portNumber > 0, "Fabricated port for \(device.productName)")
    }

    let usbCPorts = Set(HPMReader.readAll().filter { !$0.isMagSafe }.map(\.portNumber))
    guard let maxRosterPort = usbCPorts.max() else { return }

    for device in devices where device.portNumber <= maxRosterPort {
        #expect(
            usbCPorts.contains(device.portNumber),
            "\(device.productName) attributed to port \(device.portNumber), roster \(usbCPorts.sorted())"
        )
    }
}
