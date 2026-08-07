import Foundation
import Testing
@testable import WhatPortIOKit

// Replays the port-number rules against the corpus.
//
// Every reader has to answer "which physical port is this?", and the sources
// disagree: the XHCI node's own UsbCPortNumber counts sequentially while the
// HPM roster numbers the connectors, so a Mac that skips a number has two
// different answers for the same port. Getting this wrong attributes a device,
// a charger or a set of lifetime counters to the wrong card.
//
// Skips when the corpus is absent (sibling working copy, not in git).
//
// What this sweep CANNOT cover: the "@N" is a service-plane location and is
// rendered in hex, but no machine in the corpus has more than six ports, so
// hex and decimal agree on every record here. Breaking the radix leaves this
// whole suite green. That rule is pinned by usbIOPortPathParsesTheLocationAsHex
// in PortStatsReaderTests instead, which uses paths no Mac has yet published.
@Suite("Port numbers — customer probe sweep")
struct PortNumberCorpusSweepTests {

    private struct XHCIRecord {
        let machine: String
        let node: String              // "usb-drd3-port-ss"
        let usbCPortNumber: Int?      // the XHCI node's own sequential number
        let usbIOPortPath: String?    // registry path to the HPM port node
    }

    // Probe 36 prints the root ports twice: once with usb-c-port-number, then
    // again with the UsbIOPort path. Parsed line by line under an explicit
    // section header, since the two halves interleave the same node names.
    private static func xhciRecords(in output: String, machine: String) -> [XHCIRecord] {
        var numbers: [String: Int] = [:]
        var paths: [String: String] = [:]
        var section = ""

        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("=== ") { section = line; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if section.contains("USB host-controller port"),
               let range = trimmed.range(of: "usb-c-port-number=") {
                let node = String(trimmed[trimmed.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let value = trimmed[range.upperBound...].prefix { $0.isNumber }
                numbers[node] = Int(value)
                continue
            }

            if section.contains("UsbIOPort"), let range = trimmed.range(of: "UsbIOPort=") {
                let node = String(trimmed[trimmed.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                paths[node] = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return Set(numbers.keys).union(paths.keys).sorted().map {
            XHCIRecord(machine: machine, node: $0, usbCPortNumber: numbers[$0], usbIOPortPath: paths[$0])
        }
    }

    private static func records() -> [(machine: ProbeCorpus.Machine, records: [XHCIRecord])] {
        ProbeCorpus.machines.compactMap { machine in
            guard let output = machine.probe("36_xhci_port_map.json") else { return nil }
            let parsed = xhciRecords(in: output, machine: machine.name)
            return parsed.isEmpty ? nil : (machine, parsed)
        }
    }

    @Test("UsbIOPort resolves to a port on the machine's own roster", .enabled(if: ProbeCorpus.isAvailable))
    func usbIOPortResolvesToARosterPort() throws {

        var resolved = 0
        var offRoster: [String] = []

        for (machine, records) in Self.records() {
            guard let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }
            let usbCPorts = Set(
                ProbeCorpus.roster(in: rosterOutput)
                    .filter { $0.portType == "USB-C" }
                    .map(\.portNumber)
            )
            guard !usbCPorts.isEmpty else { continue }

            for record in records {
                guard let path = record.usbIOPortPath,
                      let portNumber = PortStatsReader.usbCPortNumber(fromPath: path) else { continue }
                resolved += 1
                if !usbCPorts.contains(portNumber) {
                    offRoster.append("\(machine.name) \(record.node) -> port \(portNumber), roster \(usbCPorts.sorted())")
                }
            }
        }

        // The whole point of preferring UsbIOPort is that it is a path INTO the
        // HPM roster, so every resolution must land on a port that roster lists.
        try #require(resolved > 500, "Expected hundreds of resolutions, got \(resolved)")
        #expect(offRoster.isEmpty, "\(offRoster.count) resolved off-roster: \(offRoster.prefix(5))")
    }

    @Test("UsbCPortNumber disagrees often enough to be worth ignoring", .enabled(if: ProbeCorpus.isAvailable))
    func usbCPortNumberDisagreesOftenEnough() throws {

        var comparable = 0
        var disagreements = 0
        var machinesAffected: Set<String> = []

        for (_, records) in Self.records() {
            for record in records {
                guard let sequential = record.usbCPortNumber,
                      let path = record.usbIOPortPath,
                      let physical = PortStatsReader.usbCPortNumber(fromPath: path) else { continue }
                comparable += 1
                if sequential != physical {
                    disagreements += 1
                    machinesAffected.insert(record.machine)
                }
            }
        }

        // This is why readers resolve through UsbIOPort and never through
        // UsbCPortNumber. If a future corpus shows these always agreeing, the
        // reasoning in PortStatsReader needs revisiting rather than quietly
        // resting on a stale count.
        try #require(comparable > 500, "Expected hundreds of comparable records, got \(comparable)")
        #expect(disagreements > 0, "Expected UsbCPortNumber to disagree somewhere")
        #expect(
            machinesAffected.count >= 10,
            "Only \(machinesAffected.count) machines disagree, out of \(comparable) records"
        )
    }

    @Test("macOS 15 publishes no UsbIOPort, so the fallback is load-bearing", .enabled(if: ProbeCorpus.isAvailable))
    func macOS15PublishesNoUsbIOPort() throws {

        var byMajor: [String: (total: Int, resolved: Int)] = [:]

        for (machine, records) in Self.records() {
            guard let output = machine.probe("36_xhci_port_map.json") else { continue }
            // Only machines whose probe recorded the UsbIOPort section at all;
            // older probe runs predate it and would look like a macOS result.
            guard output.contains("UsbIOPort") else { continue }

            let version = machine.chip("36_xhci_port_map.json")
            _ = version
            let major = Self.macOSMajor(of: machine) ?? "?"

            for record in records {
                var entry = byMajor[major] ?? (0, 0)
                entry.total += 1
                if let path = record.usbIOPortPath,
                   PortStatsReader.usbCPortNumber(fromPath: path) != nil {
                    entry.resolved += 1
                }
                byMajor[major] = entry
            }
        }

        // The device-tree port-number walk exists solely because this is true.
        // If macOS 15 ever starts publishing UsbIOPort, the fallback becomes
        // dead code and should be reconsidered, not left to rot.
        let fifteen = try #require(byMajor["15"], "Expected macOS 15 machines in the corpus")
        #expect(fifteen.total > 20, "Expected macOS 15 records, got \(fifteen.total)")
        #expect(fifteen.resolved == 0, "macOS 15 resolved \(fifteen.resolved) of \(fifteen.total)")

        let twentySix = try #require(byMajor["26"], "Expected macOS 26 machines in the corpus")
        #expect(
            Double(twentySix.resolved) / Double(twentySix.total) > 0.95,
            "macOS 26 resolved \(twentySix.resolved) of \(twentySix.total)"
        )
    }

    @Test("Only a USB-C leaf resolves", .enabled(if: ProbeCorpus.isAvailable))
    func onlyAUSBCLeafResolves() throws {

        // A path is only a port number if it ends at a USB-C port node. Taking
        // the "@N" off any other leaf would hand back a number belonging to a
        // different connector, most obviously MagSafe, which shares numbering
        // with USB-C.
        #expect(PortStatsReader.usbCPortNumber(fromPath: "IOService:/x/Port-MagSafe 3@1") == nil)

        var checked = 0
        for (_, records) in Self.records() {
            for record in records {
                guard let path = record.usbIOPortPath else { continue }
                checked += 1
                let resolved = PortStatsReader.usbCPortNumber(fromPath: path)
                let endsAtUSBC = path.contains("/Port-USB-C@")
                #expect(
                    (resolved != nil) == endsAtUSBC,
                    "\(record.machine) \(record.node): \(path) resolved \(String(describing: resolved))"
                )
            }
        }
        try #require(checked > 500, "Expected hundreds of paths, got \(checked)")
    }

    @Test("Probe 38 device UsbIOPort resolves to a port on the machine's roster", .enabled(if: ProbeCorpus.isAvailable))
    func probe38UsbIOPortResolvesToARosterPort() throws {

        var exercised = 0
        var offRoster: [String] = []

        for machine in ProbeCorpus.machines {
            guard let deviceOutput = machine.probe("38_usb_device_tree.json") else { continue }
            let paths = Self.usbIOPortPaths(in: deviceOutput)
            guard !paths.isEmpty else { continue }

            guard let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }
            let usbCPorts = Set(
                ProbeCorpus.roster(in: rosterOutput)
                    .filter { $0.portType == "USB-C" }
                    .map(\.portNumber)
            )
            guard !usbCPorts.isEmpty else { continue }

            for path in paths {
                guard let portNumber = PortStatsReader.usbCPortNumber(fromPath: path) else { continue }
                exercised += 1
                if !usbCPorts.contains(portNumber) {
                    offRoster.append("\(machine.name) \(path) -> port \(portNumber), roster \(usbCPorts.sorted())")
                }
            }
        }

        // A floor, not a census pin: the corpus grows, and the count is only
        // here to catch the loader silently breaking (e.g. probe 38's format
        // changing under it and every block quietly matching nothing).
        try #require(exercised >= 100, "Expected at least 100 UsbIOPort resolutions, got \(exercised)")

        // Almost every resolution lands on the roster probe 35 built for the
        // same machine, but not quite all: a handful of machines attach
        // devices through a short "AppleARMPE/port-usb-c-N" path family that
        // parses to a valid port number but names a port the SPMI/I2C HPM bus
        // never enumerates, so it never reaches this machine's roster either.
        // That device is silently dropped by PortManager's port-number join,
        // same as an unresolved one, so it is not a misattribution, just a
        // port this app does not track. A ratio floor (not #expect(isEmpty))
        // is what keeps that legitimate case from making this sweep flaky
        // while still catching a real regression in the resolver.
        let onRosterRatio = Double(exercised - offRoster.count) / Double(exercised)
        #expect(
            onRosterRatio > 0.9,
            "Only \(exercised - offRoster.count) of \(exercised) resolved on-roster: \(offRoster.prefix(5))"
        )
    }

    // Probe 38 prints one device block per USB device, each with an
    // IOService-plane ancestor chain. "UsbIOPort=" appears on at most one
    // ancestor line per device (the port-interface node closest to the XHCI
    // root port), and the probe never puts a space in the path itself, so a
    // plain per-line scan is enough: no need to track block boundaries.
    private static func usbIOPortPaths(in output: String) -> [String] {
        var paths: [String] = []
        for line in output.split(separator: "\n").map(String.init) {
            guard let range = line.range(of: "UsbIOPort=") else { continue }
            let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            paths.append(path)
        }
        return paths
    }

    // The corpus records the OS version per probe file; the directory name
    // carries it too, and the two agree.
    private static func macOSMajor(of machine: ProbeCorpus.Machine) -> String? {
        let url = machine.url.appendingPathComponent("36_xhci_port_map.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["macos_version"] as? String
        else { return nil }
        return version.split(separator: ".").first.map(String.init)
    }
}
