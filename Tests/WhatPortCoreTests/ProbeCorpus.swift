import Foundation

// Loader for the WhatCable customer-probe corpus: ~780 real Macs, M1 through M5
// plus A18 Pro and Intel, macOS 14 through 27, each a directory of probe dumps.
//
// WhatPort's IOKit tests otherwise read live IOKit on whichever Mac runs the
// suite, in whatever state it happens to be in. That is one machine of hardware
// coverage, and it has already produced a false failure (PR #80). Replaying the
// corpus through the real parse functions is the only way to exercise hardware
// this repo does not own.
//
// The corpus is not in this repository and is not in git: it lives in the
// sibling whatcable-app working copy. Every sweep must therefore degrade to a
// skip when it is absent, never to a failure, or a fresh clone goes red for a
// reason that has nothing to do with the code.
enum ProbeCorpus {
    // The sibling repo's corpus, or an override for a checkout somewhere else.
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["WHATPORT_PROBE_CORPUS"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatPortCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // whatport
            .deletingLastPathComponent()   // personal
            .appendingPathComponent("whatcable-app/research/customer-probes")
    }()

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // One machine's directory.
    struct Machine {
        let name: String
        let url: URL

        // A probe's captured stdout, or nil when this machine did not run it.
        // Probe coverage is uneven: probes were added over time, so an older
        // machine simply lacks the later ones.
        func probe(_ fileName: String) -> String? {
            let url = url.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json["output"] as? String
        }

        func chip(_ fileName: String) -> String {
            let url = url.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "" }
            return (json["chip"] as? String) ?? ""
        }
    }

    static var machines: [Machine] {
        guard isAvailable else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { Machine(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Probe 01: IOAccessoryManager blocks

    // One service the probe found by matching IOAccessoryManager, in the shape
    // HPMReader.parse takes: the properties it published, its registry name, and
    // the "@N" the probe recorded in its Description.
    struct AccessoryBlock {
        let entryName: String
        let portNumber: Int?
        let properties: [String: Any]
    }

    // Blocks are headed "=== IOAccessoryManager[N] ===" followed by indented
    // "Class:", "Name:" and "Properties:" sections. Parsed line by line rather
    // than by matching a pattern across the whole text: a regex window here has
    // twice silently picked up a neighbouring block's fields on this corpus.
    static func accessoryBlocks(in output: String) -> [AccessoryBlock] {
        var blocks: [AccessoryBlock] = []
        var inBlock = false
        var name = ""
        var description = ""
        var propertyLines: [String] = []

        func finish() {
            guard inBlock, !name.isEmpty else { return }
            blocks.append(AccessoryBlock(
                entryName: name,
                portNumber: portNumber(fromDescription: description),
                properties: properties(from: propertyLines)
            ))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("=== ") {
                finish()
                inBlock = line.hasPrefix("=== IOAccessoryManager[")
                name = ""
                description = ""
                propertyLines = []
                continue
            }
            guard inBlock else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Name:") {
                name = String(trimmed.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Description = ") {
                description = unquote(String(trimmed.dropFirst("Description = ".count)))
                propertyLines.append(line)
            } else {
                propertyLines.append(line)
            }
        }
        finish()

        return blocks
    }

    // "Port-USB-C@2" -> 2. The probe records the location as part of the
    // Description string; live code reads it from the service plane, where it is
    // rendered in hex, so parse it the same way.
    static func portNumber(fromDescription description: String) -> Int? {
        guard let at = description.lastIndex(of: "@") else { return nil }
        return Int(description[description.index(after: at)...], radix: 16)
    }

    // MARK: - Property-dump parsing

    // Turns the probe's indented property dump into the dictionary shape IOKit
    // would have handed the reader: scalars, string arrays, and nested
    // dictionaries.
    //
    // Nested dictionaries used to be skipped, on the grounds that nothing read
    // them. That was wrong twice over: PhyReader reads its whole lane map out
    // of one, and skipping them made that data invisible here, which is how
    // "the corpus cannot cover PhyReader" ended up written down as a fact. A
    // loader that quietly drops what it does not expect will hide the next one
    // too.
    static func properties(from lines: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.range(of: " = ") else { continue }

            let key = String(trimmed[trimmed.startIndex..<equals.lowerBound])
            let value = String(trimmed[equals.upperBound...])

            if value == "[" {
                var items: [String] = []
                while index < lines.count {
                    let itemLine = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if itemLine == "]" { break }
                    // "[0] "CC"" -> CC
                    guard let close = itemLine.firstIndex(of: "]") else { continue }
                    let item = itemLine[itemLine.index(after: close)...]
                        .trimmingCharacters(in: .whitespaces)
                    items.append(unquote(item))
                }
                result[key] = items
                continue
            }

            if value == "{" {
                // Collect the nested block by depth, then parse it the same
                // way. Depth tracking matters: a dictionary inside a dictionary
                // must not end the outer one early.
                // Depth is counted per brace rather than per line. Some values
                // are dumped as a CFBasicHash blob that spans several lines and
                // carries its own braces, including a bare "}" that closed the
                // enclosing dictionary early when this matched whole lines. It
                // cost the DisplayPort link rates on 88 machines, which read as
                // "the corpus does not record them".
                var nested: [String] = []
                var depth = 1
                while index < lines.count {
                    let inner = lines[index]
                    index += 1
                    depth += braceDelta(in: inner)
                    if depth <= 0 { break }
                    nested.append(inner)
                }
                result[key] = properties(from: nested)
                continue
            }

            result[key] = scalar(value)
        }

        return result
    }

    // Net brace depth a line contributes, ignoring braces inside a quoted
    // string so a value like "{unknown}" cannot unbalance the count.
    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle(); continue }
            guard !inQuotes else { continue }
            if character == "{" { delta += 1 }
            if character == "}" { delta -= 1 }
        }
        return delta
    }

    // "true" -> Bool, "3 (0x3)" -> Int, "\"USB-C\"" -> String, anything else
    // stays a string. Matches how ioBool / ioInt / ioString would read the
    // corresponding CF type.
    private static func scalar(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw.hasPrefix("\"") { return unquote(raw) }
        if let paren = raw.firstIndex(of: "("),
           let number = Int(raw[raw.startIndex..<paren].trimmingCharacters(in: .whitespaces)) {
            return number
        }
        if let number = Int(raw) { return number }
        return raw
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        return value
    }

    // MARK: - Probe 35: the HPM port roster

    struct RosterPort {
        let portType: String   // "USB-C" / "MagSafe 3"
        let portNumber: Int
        let uuid: String       // raw, with dashes, as the controller publishes it
    }

    // Lines are "[0] Port-USB-C@1        class=AppleHPMDeviceHALType3" followed
    // by an indented "UUID=... RID=... Address=...".
    static func roster(in output: String) -> [RosterPort] {
        var ports: [RosterPort] = []
        var pending: (type: String, number: Int)?

        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("Port-"),
                      let at = rest.firstIndex(of: "@") else { pending = nil; continue }
                let type = String(rest[rest.index(rest.startIndex, offsetBy: "Port-".count)..<at])
                let after = rest[rest.index(after: at)...]
                let digits = after.prefix { $0.isHexDigit }
                guard let number = Int(digits, radix: 16) else { pending = nil; continue }
                pending = (type, number)
                continue
            }

            guard let pending, trimmed.hasPrefix("UUID=") else { continue }
            let uuid = trimmed
                .dropFirst("UUID=".count)
                .prefix { !$0.isWhitespace }
            ports.append(RosterPort(portType: pending.type, portNumber: pending.number, uuid: String(uuid)))
        }

        return ports
    }

    // MARK: - Probe 01: AppleTypeCPhy blocks

    // The same walk records the PHY services, under chip-specific class names
    // ("AppleT8132TypeCPhy"), with the lane map nested inside.
    static func phyBlocks(in output: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var inBlock = false
        var propertyLines: [String] = []

        func finish() {
            guard inBlock, !propertyLines.isEmpty else { return }
            blocks.append(properties(from: propertyLines))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("=== ") {
                finish()
                // Header is "=== AppleT8132TypeCPhy[0] ===" and the class name
                // varies by chip, so match the family rather than a name.
                inBlock = line.contains("TypeCPhy[")
                propertyLines = []
                continue
            }
            if inBlock { propertyLines.append(line) }
        }
        finish()

        return blocks
    }

    // MARK: - Probe 29: IOThunderboltPort adapters

    // Blocks are headed '--- IOThunderboltPort[N] "IOThunderboltPort" ---'
    // followed by "  Key =     value" lines.
    //
    // Only the keys ThunderboltReader reads are pulled out, by searching the
    // block for each one by name. The alternative, parsing every line into
    // key/value pairs, is not safe on this format: the probe flattens nested
    // dictionaries inline, so a single line can read
    // "Hop Table =   Thunderbolt Version =     16 (0x10)" with two keys on it.
    // Asking for known keys sidesteps that entirely.
    static func thunderboltBlocks(in output: String) -> [[String: Any]] {
        let wanted = [
            "Description", "Socket ID", "Port Number",
            "Current Link Width", "Current Link Speed",
            "Supported Link Width", "Supported Link Speed",
            "Target Link Width", "Target Link Speed",
            "Link Bandwidth", "Thunderbolt Version", "Dual-Link Port",
        ]

        var blocks: [[String: Any]] = []
        var current: String?

        func finish() {
            guard let body = current else { return }
            var properties: [String: Any] = [:]
            for key in wanted {
                if let value = value(of: key, in: body) { properties[key] = value }
            }
            blocks.append(properties)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("--- IOThunderboltPort[") {
                finish()
                current = ""
                continue
            }
            // Any other block header ends this one.
            if line.hasPrefix("---") || line.hasPrefix("=== ") {
                finish()
                current = nil
                continue
            }
            if current != nil { current! += line + "\n" }
        }
        finish()

        return blocks
    }

    // Reads "  Socket ID =     "2"" or "  Link Bandwidth =     100 (0x64)".
    // Anchored on the key starting its line so "Link Width" cannot match inside
    // "Supported Link Width".
    private static func value(of key: String, in body: String) -> Any? {
        for line in body.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + " =") else { continue }
            let raw = String(trimmed.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return nil }
            return scalar(raw)
        }
        return nil
    }

    // MARK: - Probe 34: raw SMC key bytes

    // Lines are "  D1UI hex_ 16    raw=0011..", with "(read failed 0x...)" where
    // the key exists but would not read. Returns the raw bytes per key, which is
    // exactly what the SMC reader's key-reading closure hands back.
    static func smcKeys(in output: String) -> [String: [UInt8]] {
        var keys: [String: [UInt8]] = [:]

        for line in output.split(separator: "\n").map(String.init) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, fields[0].count == 4 else { continue }
            guard let raw = fields.first(where: { $0.hasPrefix("raw=") }) else { continue }

            let hex = raw.dropFirst("raw=".count)
            guard !hex.isEmpty, hex.count % 2 == 0 else { continue }
            var bytes: [UInt8] = []
            var cursor = hex.startIndex
            while cursor < hex.endIndex {
                let next = hex.index(cursor, offsetBy: 2)
                guard let byte = UInt8(hex[cursor..<next], radix: 16) else { bytes = []; break }
                bytes.append(byte)
                cursor = next
            }
            guard !bytes.isEmpty else { continue }
            keys[fields[0]] = bytes
        }

        return keys
    }
}
