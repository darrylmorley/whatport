import Foundation
import IOKit
import WhatPortCore

// Type-safe wrappers for IOKit registry property values.
//
// IOKit returns properties as CF types bridged to Any. These helpers
// safely cast to Swift types, returning sensible defaults on failure.
// Adapted from what-cable's IOKitHelpers.

func ioInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let i = value as? Int { return i }
    if let s = value as? String, let i = Int(s) { return i }
    return 0
}

// For unsigned 32-bit registry values whose bit pattern matters, e.g.
// locationID. NSNumber.intValue sign-extends an SInt32-boxed value with
// bit 31 set into a negative Int, which would corrupt bit arithmetic done
// on the value later; uint32Value preserves the unsigned magnitude.
func ioUInt32(_ value: Any?) -> Int {
    guard let n = value as? NSNumber else { return 0 }
    return Int(n.uint32Value)
}

func ioBool(_ value: Any?) -> Bool {
    if let n = value as? NSNumber { return n.boolValue }
    if let b = value as? Bool { return b }
    return false
}

func ioString(_ value: Any?) -> String {
    if let s = value as? String { return s }
    return ""
}

func ioDictionary(_ value: Any?) -> [String: Any] {
    if let dict = value as? [String: Any] { return dict }
    if let nsDict = value as? NSDictionary {
        var converted: [String: Any] = [:]
        for case let (key, val) as (String, Any) in nsDict {
            converted[key] = val
        }
        return converted
    }
    return [:]
}

func ioArray(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    if let nsArray = value as? NSArray { return nsArray.map { $0 } }
    return []
}

// Reads an IOKit array of strings (e.g. TransportsProvisioned), dropping any
// empty or non-string entries.
func ioStringArray(_ value: Any?) -> [String] {
    ioArray(value)
        .map { ioString($0) }
        .filter { !$0.isEmpty }
}

// Read all properties from an IOKit service as a Swift dictionary.
//
// IORegistryEntryCreateCFProperties fills an Unmanaged<CFMutableDictionary>.
// "Unmanaged" means Swift doesn't manage the memory automatically.
// takeRetainedValue() tells Swift to take ownership and release it later.
func ioProperties(_ service: io_service_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    let kr = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
    guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
    return dict as? [String: Any]
}

// Read a single property from an IOKit service.
//
// IORegistryEntryCreateCFProperty returns a single CF value (string, number, dict, etc.)
// wrapped in Unmanaged. We take retained ownership and bridge to Any.
func ioProperty(_ service: io_service_t, key: String) -> Any? {
    guard let cf = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    ) else { return nil }
    return cf.takeRetainedValue()
}

// Read a property from the parent entry in the IOService plane.
//
// Used to read "port-number" from the atc-phy device node, which is
// the parent of the AppleTypeCPhy driver instance. The parent holds
// device-tree properties (like physical port mapping) that the driver
// node itself doesn't expose.
//
// IORegistryEntryGetParentEntry returns a retained reference, so we
// release it in defer. "Retained" means IOKit has bumped the reference
// count for us, and we're responsible for calling IOObjectRelease when
// done - same pattern as malloc/free in C.
func ioParentProperty(_ service: io_service_t, key: String) -> Any? {
    var parent: io_registry_entry_t = 0
    let kr = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
    guard kr == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(parent) }
    return ioProperty(parent, key: key)
}

// Read a Data-encoded little-endian 32-bit integer.
//
// IOKit stores some device-tree integer properties as raw bytes rather
// than CFNumber. For example, "port-number" = <01000000> is the number 1
// stored as a 4-byte little-endian value. This helper reads those bytes
// and converts to a native Int.
func ioDataInt(_ value: Any?) -> Int? {
    guard let data = value as? Data, data.count >= 4 else { return nil }
    let raw = data.withUnsafeBytes { $0.load(as: UInt32.self) }
    return Int(UInt32(littleEndian: raw))
}

// Read a property from an ancestor N levels up in the IOService plane.
//
// Walks from the given service up through parent entries. Each
// IORegistryEntryGetParentEntry returns a retained reference that we
// release as we move on. The final ancestor is also released via defer.
//
// levels=1 is equivalent to ioParentProperty. levels=3 walks up three
// generations (e.g. USB device → USB port → XHCI → usb-drd).
func ioAncestorProperty(_ service: io_service_t, key: String, levels: Int) -> Any? {
    guard levels > 0 else { return ioProperty(service, key: key) }

    var previous: io_registry_entry_t = service
    var current: io_registry_entry_t = 0

    for i in 0..<levels {
        let kr = IORegistryEntryGetParentEntry(previous, kIOServicePlane, &current)
        // Release intermediate parents (but never the original service)
        if i > 0 { IOObjectRelease(previous) }
        guard kr == KERN_SUCCESS else { return nil }
        previous = current
    }

    defer { IOObjectRelease(current) }
    return ioProperty(current, key: key)
}

// Walk up the IOService plane from `service` and return the first
// Data-encoded integer property found, within `maxLevels` steps (inclusive
// of `service` itself at level 0).
//
// Used to find the device-tree "port-number" that ties a USB device to its
// physical port. The depth varies: a device plugged straight into a Mac port
// finds it ~3 levels up, while a device behind a hub/dock finds it deeper
// (~6). A fixed-level walk misses the deeper case, so we search up to a
// generous bound and stop at the first match.
func ioFirstAncestorDataInt(_ service: io_service_t, key: String, maxLevels: Int) -> Int? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0...maxLevels {
        if let value = ioDataInt(ioProperty(current, key: key)) {
            return value
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}

// Walk up the IOService plane from `service` and return the first String
// property found, within `maxLevels` steps (inclusive of `service` itself at
// level 0).
//
// Used to find the device-tree "UsbIOPort" path that joins a USB device to
// its physical port node in the HPM roster. The depth varies: a device
// plugged straight into a Mac port finds it a few levels up, while a device
// behind cascaded hubs finds it much deeper. A fixed-level walk misses the
// deeper case, so we search up to a generous bound and stop at the first
// match.
func ioFirstAncestorString(_ service: io_service_t, key: String, maxLevels: Int) -> String? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0...maxLevels {
        if let value = ioProperty(current, key: key) as? String, !value.isEmpty {
            return value
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}

// Get the IOKit registry entry name for a service (e.g. "Port-USB-C@4").
//
// Unlike the class name, this is the node's name in the service plane.
// For HPM port-interface nodes it carries the "@N" physical port suffix.
func ioEntryName(_ service: io_service_t) -> String? {
    var buf = [CChar](repeating: 0, count: 128)
    let kr = IORegistryEntryGetName(service, &buf)
    guard kr == KERN_SUCCESS else { return nil }
    let len = buf.firstIndex(of: 0) ?? buf.count
    return String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// Get the IOKit location-in-plane for a service, parsed as a hex integer.
//
// The "@N" suffix that ioreg shows on a node (e.g. "Port-USB-C@4") is the
// node's location in the service plane, NOT part of its registry name. It is
// rendered as hex, matching how socket IDs and port indices are read.
func ioLocationInPlaneInt(_ service: io_service_t) -> Int? {
    var buf = [CChar](repeating: 0, count: 128)
    let kr = IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &buf)
    guard kr == KERN_SUCCESS else { return nil }
    let len = buf.firstIndex(of: 0) ?? buf.count
    let location = String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return Int(location, radix: 16)
}

// Walk the IOKit parent chain from `service` looking for an HPM power
// controller node (class "AppleHPMDevice" or a subclass like
// "AppleHPMDeviceHALType3" on M3+) and return its "UUID" property.
//
// The UUID is the stable per-physical-port identity. It lives only on the
// HPM controller node, never on the port-interface node itself, so callers
// that hold any descendant (interface, transport state, power source) can
// walk up to it. Distinct per physical port, including MagSafe vs USB-C when
// they share the same "@N" number.
//
// Returns nil if no HPM controller is found within `maxDepth` parent steps,
// or the controller carries no UUID. Depth default of 12 matches what-cable:
// large enough for deep subtrees (a power-source node sits ~4 levels below
// the HPM device), the interface node is a direct child.
func ioHPMControllerUUID(_ service: io_service_t, maxDepth: Int = 12) -> String? {
    var current = service
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }

    for _ in 0..<maxDepth {
        if let cls = ioClassName(current),
           cls == "AppleHPMDevice" || cls.hasPrefix("AppleHPMDeviceHAL") {
            if let uuid = ioProperty(current, key: "UUID") as? String, !uuid.isEmpty {
                return uuid
            }
            // Found the controller but no UUID. Stop walking.
            return nil
        }

        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}

// Get the IOKit class name for a service (e.g. "AppleT8132TypeCPhy").
func ioClassName(_ service: io_service_t) -> String? {
    var buf = [CChar](repeating: 0, count: 128)
    let kr = IOObjectGetClass(service, &buf)
    guard kr == KERN_SUCCESS else { return nil }
    let len = buf.firstIndex(of: 0) ?? buf.count
    return String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// Match IOKit services by class name and iterate them.
//
// This is the core IOKit pattern:
// 1. IOServiceMatching() creates a match dictionary for a class name
// 2. IOServiceGetMatchingServices() finds all matching services
// 3. IOIteratorNext() walks the results
//
// The closure receives each service. Services are released automatically
// after the closure returns (via defer + IOObjectRelease).
//
// The registry can mutate mid-walk (a device plugs or unplugs while we're
// reading it), which makes IOIteratorNext return 0 exactly as if the walk
// had finished, silently truncating the results. Collecting the service
// handles through IteratorWalkRetry catches that: an invalidated attempt's
// handles are released and the walk is retried, bounded so continuous
// plug/unplug activity can't loop forever.
func withMatchingServices(
    className: String,
    body: (io_service_t) -> Void
) {
    let matching = IOServiceMatching(className)
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
    guard kr == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }

    let services = IteratorWalkRetry.retry(
        isValid: { IOIteratorIsValid(iter) != 0 },
        reset: { IOIteratorReset(iter) },
        discard: { IOObjectRelease($0) },
        walk: { collectIteratorServices(iter) }
    )

    for service in services {
        defer { IOObjectRelease(service) }
        body(service)
    }
}

// Drain an iterator into an array of service handles.
private func collectIteratorServices(_ iter: io_iterator_t) -> [io_service_t] {
    var services: [io_service_t] = []
    while case let service = IOIteratorNext(iter), service != 0 {
        services.append(service)
    }
    return services
}
