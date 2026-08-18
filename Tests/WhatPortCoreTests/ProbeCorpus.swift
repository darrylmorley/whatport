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
// The corpus is not in this repository: it lives in the sibling whatx-research
// checkout, its own private repo shared by every app that replays it. Every
// sweep must therefore degrade to a skip when it is absent, never to a failure,
// or a fresh clone goes red for a reason that has nothing to do with the code.
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
            .appendingPathComponent("whatx-research/research/customer-probes")
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

    // MARK: - Probe 01: IOPortTransportStateCC / SOP' blocks

    // Same "=== ClassName[N] ===" + "Key = value" format accessoryBlocks
    // walks (see properties(from:)), just filtered to a different class. The
    // preamble lines ("Class:", "Name:", "Properties:") carry no " = " so
    // properties(from:) already skips them on its own; nothing extra is
    // needed to isolate the fields inside.
    static func equalsBlocks(in output: String, headerContains: String) -> [[String: Any]] {
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
                inBlock = line.contains(headerContains)
                propertyLines = []
                continue
            }
            if inBlock { propertyLines.append(line) }
        }
        finish()

        return blocks
    }

    // Each entry is one IOPortTransportStateCC service's own properties
    // (ParentBuiltInPortNumber, ParentPortTypeDescription, Active, ...).
    static func ccBlocks(in output: String) -> [[String: Any]] {
        equalsBlocks(in: output, headerContains: "IOPortTransportStateCC[")
    }

    // Each entry is one SOP' cable-plug service's own properties
    // (ComponentName, Metadata, Specification Revision, ...), the sibling of
    // the CC blocks above rather than a child inside them: probe 01 dumps
    // both kinds of service as flat top-level blocks.
    static func sopPrimeBlocks(in output: String) -> [[String: Any]] {
        equalsBlocks(in: output, headerContains: "IOPortTransportComponentCCUSBPDSOPp[")
    }

    // MARK: - Probe 17: colon-syntax property dump ("--- ClassName[N] ---" + "Key: value")

    // The same kind of block probe 01/29 dump, but rendered with "Key: value"
    // syntax (colon-space) instead of "Key = value". Kept as a separate
    // function rather than adding a separator parameter to properties(from:):
    // the two probes are different capture tools with different rendering,
    // and guessing per-line which separator applies is exactly the kind of
    // format-sniffing that has silently dropped data before (see
    // properties(from:)'s CFBasicHash note above).
    static func colonProperties(from lines: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.range(of: ": ") else { continue }

            let key = String(trimmed[trimmed.startIndex..<colon.lowerBound])
            let value = String(trimmed[colon.upperBound...])

            if value == "{" {
                var nested: [String] = []
                var depth = 1
                while index < lines.count {
                    let inner = lines[index]
                    index += 1
                    depth += braceDelta(in: inner)
                    if depth <= 0 { break }
                    nested.append(inner)
                }
                result[key] = colonProperties(from: nested)
                continue
            }

            if value == "[" {
                var items: [String] = []
                while index < lines.count {
                    let itemLine = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if itemLine == "]" { break }
                    guard let close = itemLine.firstIndex(of: "]") else { continue }
                    let item = itemLine[itemLine.index(after: close)...]
                        .trimmingCharacters(in: .whitespaces)
                    items.append(unquote(item))
                }
                result[key] = items
                continue
            }

            result[key] = scalar(value)
        }

        return result
    }

    // Blocks headed '--- ClassName[N] ---' (as opposed to probe 01/29's
    // "=== ClassName[N] ==="), with colon-syntax fields.
    static func colonBlocks(in output: String, matching headerContains: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var inBlock = false
        var propertyLines: [String] = []

        func finish() {
            guard inBlock, !propertyLines.isEmpty else { return }
            blocks.append(colonProperties(from: propertyLines))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("--- ") || line.hasPrefix("=== ") {
                finish()
                inBlock = line.contains(headerContains)
                propertyLines = []
                continue
            }
            if inBlock { propertyLines.append(line) }
        }
        finish()

        return blocks
    }

    // Each entry is one IOPortFeaturePowerSource service's own properties
    // (PowerSourceName, ParentBuiltInPortNumber, WinningPowerSourceOption,
    // ...), the node ChargerReader.parse reads. Guards the same 64KB pipe
    // truncation isolatedSmartBatterySection guards for probe 32: 41 of the
    // corpus's probe-17 captures are cut off mid-dump, and a truncated
    // capture must be dropped outright rather than silently under-report a
    // machine's charger nodes.
    static func chargerBlocks(inFullOutput output: String) -> [[String: Any]] {
        guard !isPipeTruncated(output) else { return [] }
        return colonBlocks(in: output, matching: "IOPortFeaturePowerSource[")
    }

    // True when a capture was cut off mid-dump by the 64KB pipe buffer. The
    // cap is a BYTE limit, not a grapheme-cluster count, so this compares
    // output.utf8.count, not output.count (matches isolatedSmartBatterySection's
    // own check for probe 32).
    static func isPipeTruncated(_ output: String) -> Bool {
        output.utf8.count == 65536
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

    // MARK: - Probe 32: AppleSmartBattery PortControllerInfo (PD reliability)

    // One entry of the PortControllerInfo array: the counters PDReliabilityReader
    // reads, plus its array offset (0-based; production code maps offset+1 to a
    // physical USB-C port number, see PDReliabilityReader).
    struct PortControllerEntry {
        let index: Int
        let attachCount: Int
        let detachCount: Int
        let hardResetCount: Int
        let irqHardResetCount: Int
        let shortDetectCount: Int
        let dataRoleSwapFailCount: Int
        let powerRoleSwapFailCount: Int
        let i2cErrorCount: Int
    }

    private static let portControllerWantedKeys: Set<String> = [
        "PortControllerAttachCount", "PortControllerDetachCount",
        "PortControllerHardResetCount", "PortControllerIrqCntHrdRst",
        "PortControllerShortDetectCount",
        "PortControllerDataRoleSwapFailCount", "PortControllerPwrRoleSwapFailCount",
        "PortControllerI2cErrCount",
    ]

    // Isolates the genuine AppleSmartBattery section of a probe-32 capture,
    // handling the two hazards specific to this probe. Shared by every
    // caller that needs the section text (not just the parsed entries), so
    // the truncation/section-cut rules live in exactly one place:
    //   - A capture cut off mid-dump by the 64KB pipe buffer reads back as
    //     exactly 65536 BYTES (the pipe's cap is a byte limit, not a
    //     grapheme-cluster count, so this must compare output.utf8.count,
    //     not output.count). Any such capture is dropped outright: a
    //     truncated array would otherwise silently under-count entries
    //     rather than fail loudly.
    //   - AppleSmartBatteryManager republishes the same key names further
    //     down the same capture (a second AppleSmartBattery-shaped dump
    //     under a different class). Cutting the text at its first
    //     occurrence keeps only the genuine AppleSmartBattery section, so
    //     its PortControllerInfo array is not read twice or read from the
    //     wrong section.
    // Returns nil for a truncated capture.
    static func isolatedSmartBatterySection(inFullOutput output: String) -> String? {
        guard output.utf8.count != 65536 else { return nil }
        guard let managerRange = output.range(of: "AppleSmartBatteryManager") else { return output }
        return String(output[output.startIndex..<managerRange.lowerBound])
    }

    // MARK: - Probe 32: full property dump (IsCharging / PowerTelemetryData / AdapterDetails)

    // Turns an already-isolated probe-32 AppleSmartBattery section into the
    // dictionary shape ioProperties() would hand PowerReader: scalars, plus
    // nested dictionaries for "Key =     Dict[N]:" values (arrays fold to
    // [Any], each item parsed the same way when it is itself a dict).
    //
    // Unlike properties(from:) (probes 01/29's "= {" / "= [" bracket syntax)
    // or colonProperties(from:) (probe 17's "Key: value"), this probe nests by
    // INDENTATION: a container's fields sit some fixed number of spaces
    // deeper than the "Key =     Dict[N]:" / "Array[N]:" line introducing
    // them. The child indent is measured from the first line that follows,
    // the same defensive approach portControllerEntries takes for its entry
    // indent, rather than assumed as a fixed number of spaces.
    static func smartBatteryProperties(inFullOutput output: String) -> [String: Any] {
        guard let section = isolatedSmartBatterySection(inFullOutput: output) else { return [:] }
        return smartBatteryProperties(inSection: section)
    }

    static func smartBatteryProperties(inSection section: String) -> [String: Any] {
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: {
            $0.contains("AppleSmartBattery (full property dump)")
        }) else { return [:] }

        guard let indent = nextNonBlankIndent(lines, from: headerIndex + 1) else { return [:] }
        let (dict, _) = smartBatteryDict(lines, from: headerIndex + 1, indent: indent)
        return dict
    }

    // The indent of the first non-blank line at or after `start`, or nil when
    // there is none (an empty dict/array, or end of input).
    private static func nextNonBlankIndent(_ lines: [String], from start: Int) -> Int? {
        for line in lines[start...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            return leadingSpaceCount(of: line)
        }
        return nil
    }

    // Parses one probe-32 dict's "Key =     value" fields, starting at line
    // `start`, all at exactly `indent` spaces. Stops (without consuming) at
    // the first line indented less than `indent`. Returns the dict and the
    // index of the first line not consumed, so a caller walking a sibling
    // list of dicts (an array's items) knows where to resume.
    private static func smartBatteryDict(
        _ lines: [String], from start: Int, indent: Int
    ) -> ([String: Any], Int) {
        var result: [String: Any] = [:]
        var index = start

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            let lineIndent = leadingSpaceCount(of: line)
            if lineIndent < indent { break }
            guard lineIndent == indent, let equals = trimmed.range(of: " = ") else {
                index += 1
                continue
            }

            let key = String(trimmed[trimmed.startIndex..<equals.lowerBound])
            // Probe 32 column-aligns values with extra padding spaces after
            // the "=" ("Key =     value"), unlike probe 01/29's single-space
            // "Key = value" properties(from:) parses, so the raw " = " split
            // above leaves leading whitespace on the value that must be
            // trimmed before checking for "Dict[" / "Array[" or handing it
            // to scalar().
            let valueString = String(trimmed[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
            index += 1

            if valueString.hasPrefix("Dict["), let childIndent = nextNonBlankIndent(lines, from: index),
               childIndent > indent {
                let (dict, next) = smartBatteryDict(lines, from: index, indent: childIndent)
                result[key] = dict
                index = next
            } else if valueString.hasPrefix("Array["), let childIndent = nextNonBlankIndent(lines, from: index),
                      childIndent > indent {
                let (array, next) = smartBatteryArray(lines, from: index, indent: childIndent)
                result[key] = array
                index = next
            } else {
                result[key] = scalar(valueString)
            }
        }

        return (result, index)
    }

    // Parses one probe-32 array's "[i]  value" items, the same way
    // smartBatteryDict parses a dict's fields. An item that is itself a dict
    // ("[i]             Dict[M]:") recurses; anything else (a scalar, or a
    // Data[N] hex blob such as BatteryData.RaTableRaw, which nothing here
    // reads) is kept as a single opaque line rather than parsed further.
    private static func smartBatteryArray(
        _ lines: [String], from start: Int, indent: Int
    ) -> ([Any], Int) {
        var items: [Any] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            let lineIndent = leadingSpaceCount(of: line)
            if lineIndent < indent { break }
            guard lineIndent == indent, trimmed.hasPrefix("["),
                  let close = trimmed.firstIndex(of: "]") else {
                index += 1
                continue
            }

            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            index += 1

            if rest.hasPrefix("Dict["), let childIndent = nextNonBlankIndent(lines, from: index),
               childIndent > indent {
                let (dict, next) = smartBatteryDict(lines, from: index, indent: childIndent)
                items.append(dict)
                index = next
            } else {
                items.append(scalar(rest))
            }
        }

        return (items, index)
    }

    // Parses a whole probe-32 capture's PortControllerInfo array, applying
    // isolatedSmartBatterySection's truncation guard and section cut first.
    static func portControllerEntries(inFullOutput output: String) -> [PortControllerEntry] {
        guard let section = isolatedSmartBatterySection(inFullOutput: output) else { return [] }
        return portControllerEntries(in: section)
    }

    // Parses "PortControllerInfo =     Array[N]:" and its "[i]  Dict[M]:"
    // entries out of one already-isolated AppleSmartBattery section.
    //
    // The array's entry headers ("[0]         Dict[63]:") sit at a fixed
    // indent, one level in from the array's own line; each entry's keys sit a
    // further level in. A nested array inside an entry (PortControllerPortPDO)
    // produces its own "[N]  value" lines much deeper still, so entries are
    // told apart from nested-array items by indent, not by the "[N]" syntax
    // alone: only a bracket line at exactly the entries' own indent starts a
    // new entry.
    static func portControllerEntries(in output: String) -> [PortControllerEntry] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let arrayLineIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("PortControllerInfo =")
        }) else { return [] }

        // Find the indent of the first entry header after the array line.
        // Skips blank lines only; the first non-blank, non-bracket line means
        // the array is empty (e.g. "Array[0]:" with nothing following it).
        var entryIndent: Int?
        for line in lines[(arrayLineIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("[") else { break }
            entryIndent = leadingSpaceCount(of: line)
            break
        }
        guard let entryIndent else { return [] }

        var entries: [PortControllerEntry] = []
        var currentIndex: Int?
        var currentValues: [String: Int] = [:]

        func finishEntry() {
            guard let currentIndex else { return }
            entries.append(PortControllerEntry(
                index: currentIndex,
                attachCount: currentValues["PortControllerAttachCount"] ?? 0,
                detachCount: currentValues["PortControllerDetachCount"] ?? 0,
                hardResetCount: currentValues["PortControllerHardResetCount"] ?? 0,
                irqHardResetCount: currentValues["PortControllerIrqCntHrdRst"] ?? 0,
                shortDetectCount: currentValues["PortControllerShortDetectCount"] ?? 0,
                dataRoleSwapFailCount: currentValues["PortControllerDataRoleSwapFailCount"] ?? 0,
                powerRoleSwapFailCount: currentValues["PortControllerPwrRoleSwapFailCount"] ?? 0,
                i2cErrorCount: currentValues["PortControllerI2cErrCount"] ?? 0
            ))
        }

        for line in lines[(arrayLineIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lineIndent = leadingSpaceCount(of: line)

            // Dedented below the entries' own indent: the array (and every
            // entry in it) has ended.
            if lineIndent < entryIndent { break }

            if lineIndent == entryIndent, trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let indexString = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
                guard let entryIdx = Int(indexString) else { continue }
                finishEntry()
                currentIndex = entryIdx
                currentValues = [:]
                continue
            }

            guard currentIndex != nil, let equals = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex..<equals.lowerBound])
            guard portControllerWantedKeys.contains(key) else { continue }
            currentValues[key] = intValue(String(trimmed[equals.upperBound...]))
        }
        finishEntry()

        return entries
    }

    private static func leadingSpaceCount(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    // "1 (0x1)" -> 1. Same numeric format properties(from:)'s scalar() parses,
    // duplicated locally (rather than reused) because scalar() also handles
    // strings/bools/nested structures this probe never needs here.
    private static func intValue(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let paren = trimmed.firstIndex(of: "("),
           let number = Int(trimmed[trimmed.startIndex..<paren].trimmingCharacters(in: .whitespaces)) {
            return number
        }
        return Int(trimmed) ?? 0
    }

    // "PortControllerInfo =     Array[2]:" -> 2. Used only to compare declared
    // array lengths against FedDetails for the congruence check; the entry
    // parser above walks the actual "[N]" headers instead, and both agree on
    // every corpus machine (2382 entries checked, 0 out of range).
    static func declaredArrayLength(ofKey key: String, in output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + " =") else { continue }
            guard let open = trimmed.range(of: "Array["), let close = trimmed[open.upperBound...].firstIndex(of: "]") else {
                return nil
            }
            return Int(trimmed[open.upperBound..<close])
        }
        return nil
    }
}
