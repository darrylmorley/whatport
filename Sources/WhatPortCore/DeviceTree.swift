import Foundation

// Pure USB topology helpers derived from locationID, the IOKit-assigned
// value that encodes a device's position in the USB hub tree. Operates only
// on DeviceInput, so WhatPortCore stays free of any IOKit dependency; this
// file must never import WhatPortIOKit.
//
// locationID layout (an undocumented Apple convention, stable since at least
// Snow Leopard but not guaranteed by any public API): the top byte (bits
// 31-24) is the bus/controller index, and the low 24 bits (bits 23-0) carry
// up to 6 hub-path nibbles, one per hop. A directly-attached (root) device
// has exactly one non-zero path nibble.
public enum DeviceTree {
    // Number of hub-path nibbles a locationID can carry. Bounds the walk in
    // hubDepth(of:in:) so malformed input cannot loop.
    private static let maxPathNibbles = 6

    // USB locationID encodes the topology path: the top byte is the
    // bus/controller, and each following nibble is a hub port hop.
    // Stripping the lowest-order non-zero nibble yields the parent's
    // locationID. Returns nil when the device is directly attached
    // (exactly one non-zero path nibble) or the locationID is malformed.
    public static func parentLocationID(_ locationID: Int) -> Int? {
        guard locationID > 0, locationID <= Int(UInt32.max) else { return nil }

        let hubPath = locationID & 0x00FF_FFFF
        guard hubPath != 0 else { return nil }

        // A valid path fills nibbles contiguously from the highest position
        // down. An internal zero nibble (e.g. 0x08201000, path 2-0-1) is not
        // a topology the encoding can produce; stripping the lowest nibble of
        // one would fabricate a parent that may collide with a real, wrong
        // hub. Treat it as malformed instead.
        var seenZero = false
        for shift in stride(from: (maxPathNibbles - 1) * 4, through: 0, by: -4) {
            let nibble = (hubPath >> shift) & 0xF
            if nibble == 0 {
                seenZero = true
            } else if seenZero {
                return nil
            }
        }

        for shift in stride(from: 0, to: maxPathNibbles * 4, by: 4) {
            guard (hubPath >> shift) & 0xF != 0 else { continue }
            let cleared = locationID & ~(0xF << shift)
            // Clearing the only non-zero nibble leaves an empty path: the
            // device was directly attached, so there is no parent.
            return (cleared & 0x00FF_FFFF) == 0 ? nil : cleared
        }
        return nil
    }

    // Number of resolvable ancestor hops for `device` within `all`
    // (0 = directly attached). Walks parentLocationID repeatedly and stops
    // as soon as no device in `all` matches, so an unplugged-mid-poll or
    // filtered-out ancestor cannot loop or overcount. Bounded by the 6
    // path nibbles a locationID can carry.
    public static func hubDepth(of device: DeviceInput, in all: [DeviceInput]) -> Int {
        let byLocationID = firstByLocationID(all)

        var depth = 0
        var current = device.locationID
        for _ in 0..<maxPathNibbles {
            guard let parentID = parentLocationID(current), byLocationID[parentID] != nil else {
                break
            }
            depth += 1
            current = parentID
        }
        return depth
    }

    // Product name of the device's immediate parent (the enclosing hub or
    // dock), if that parent is present in `all`. Nil for directly attached
    // devices, or when the parent's locationID is not in the list; the walk
    // never skips past a missing parent to a grandparent.
    public static func viaName(of device: DeviceInput, in all: [DeviceInput]) -> String? {
        guard let parentID = parentLocationID(device.locationID) else { return nil }
        return firstByLocationID(all)[parentID]?.productName
    }

    // Duplicate locationIDs in `all` are resolved deterministically: the
    // first occurrence wins.
    private static func firstByLocationID(_ devices: [DeviceInput]) -> [Int: DeviceInput] {
        Dictionary(devices.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
