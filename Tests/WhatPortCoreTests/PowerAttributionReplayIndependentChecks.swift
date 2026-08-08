import Foundation

// Independent re-derivations for PowerAttributionReplayTests (DAR-227): every
// headline count that sweep asserts is reproduced here by a mechanism that
// does not call the block parsers or *Reader.parse functions the main
// replay uses, so a bug shared between "the code" and "the test that checks
// the code" cannot hide behind agreement between two copies of itself.
//
// Both types below still call `ProbeCorpus.machines` / `machine.probe(_:)`
// for file I/O, and IndependentSMCFallbackCheck still calls
// `ProbeCorpus.smcKeys` (raw hex-string -> bytes) and `ProbeCorpus.roster`
// (the probe-35 UUID list): per corpus-test-coverage.md's own rule, "a sweep
// is only as independent as its loader," and reusing those two narrow,
// well-tested loaders keeps this file from re-deriving hex decoding and
// registry-path parsing that has nothing to do with power attribution. What
// neither type shares with the main replay is any block/dictionary parser
// (colonBlocks, colonProperties, equalsBlocks, smartBatteryProperties) or
// any *Reader.parse / SMCPowerReader.build* function.

// MARK: - Replay eligibility

// A looser, independent test of "does this machine have everything the
// snapshot builder needs": presence and non-truncation of each probe's
// marker text, found by substring search rather than by running
// ProbeCorpus's line-by-line block parsers over the whole capture.
//
// Factored out of IndependentReplayEligibilityCheck.count() so
// IndependentUSBCWinningNodeCheck can restrict its own scan to the same
// machines the main replay actually snapshots (see that type's comment for
// why the restriction matters).
fileprivate func isIndependentlyReplayEligible(_ machine: ProbeCorpus.Machine) -> Bool {
    guard let probe01 = machine.probe("01_walk_pd_tree.json"),
          probe01.contains("=== IOAccessoryManager["),
          probe01.contains("=== IOPortTransportStateCC[")
    else { return false }

    guard let probe35 = machine.probe("35_hpm_port_uuid.json"),
          probe35.contains("UUID=")
    else { return false }

    guard let probe17 = machine.probe("17_deep_property_dump.json"),
          probe17.utf8.count != 65536
    else { return false }

    guard let probe32 = machine.probe("32_smart_battery_full_keys.json"),
          probe32.utf8.count != 65536,
          probe32.contains("AppleSmartBattery (full property dump)")
    else { return false }

    guard let probe34 = machine.probe("34_smc_power_keys.json"),
          probe34.contains("raw=")
    else { return false }

    return true
}

enum IndependentReplayEligibilityCheck {
    static func count() -> Int {
        ProbeCorpus.machines.reduce(into: 0) { total, machine in
            if isIndependentlyReplayEligible(machine) { total += 1 }
        }
    }
}

// MARK: - DAR-223 SMC fallback upper bound

// A loose UPPER BOUND on how many machines the SMC-contract fallback could
// fire on: externally connected, no winning USB-C node contract, and a
// plausible contract that resolves by UUID to a USB-C roster port. It does
// not replicate every secondary gate SMCContractAttribution.resolve checks
// (ccConnected, "nothing already attributed", ambiguity when more than one
// candidate resolves), so production can only ever fire on a SUBSET of this
// count, never more. PowerAttributionReplayTests asserts exactly that
// direction of agreement rather than exact equality.
enum IndependentSMCFallbackCheck {
    private struct Contract {
        let uuid: String
        let powerMW: Int
        let voltageMV: Int
        let currentMA: Int
    }

    // A standalone big-endian reducer, written fresh here rather than calling
    // SMCPowerReader.decodeBigEndianInt: the point of this file is that a
    // wiring mistake in the production seam (wrong key name, byte order
    // applied at the wrong call site) cannot hide behind both counts sharing
    // one decoder.
    private static func decodeBigEndian(_ bytes: [UInt8]?) -> Int? {
        guard let bytes, !bytes.isEmpty else { return nil }
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func decodeUUIDHex(_ bytes: [UInt8]?) -> String? {
        guard let bytes, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func contracts(fromKeys keys: [String: [UInt8]]) -> [Contract] {
        var result: [Contract] = []
        for index in 1...4 {
            guard let uuid = decodeUUIDHex(keys["D\(index)UI"]) else { continue }
            guard let powerMW = decodeBigEndian(keys["D\(index)MP"]), powerMW > 0 else { continue }
            result.append(Contract(
                uuid: uuid,
                powerMW: powerMW,
                voltageMV: decodeBigEndian(keys["D\(index)MV"]) ?? 0,
                currentMA: decodeBigEndian(keys["D\(index)MI"]) ?? 0
            ))
        }
        return result
    }

    // Re-cuts the AppleSmartBattery section the same way
    // isolatedSmartBatterySection does (stop at the AppleSmartBatteryManager
    // repeat), written fresh rather than calling it, then finds
    // "ExternalConnected =" by a plain line scan rather than the full
    // dictionary parse smartBatteryProperties does.
    private static func probe32ExternallyConnected(_ fullOutput: String) -> Bool {
        let section: Substring
        if let managerRange = fullOutput.range(of: "AppleSmartBatteryManager") {
            section = fullOutput[fullOutput.startIndex..<managerRange.lowerBound]
        } else {
            section = fullOutput[fullOutput.startIndex...]
        }
        for rawLine in section.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ExternalConnected =") {
                return trimmed.contains("true")
            }
        }
        return false
    }

    // A flat single-pass line scan with state reset on each "--- Class[N] ---"
    // header, rather than colonBlocks' recursive nested-dictionary builder.
    // True when some IOPortFeaturePowerSource block is parented to USB-C,
    // named "USB-PD", and its WinningPowerSourceOption dict carries a parsed
    // positive "Max Power (mW)" -- not merely present. A bare
    // "WinningPowerSourceOption: {" with an empty (or malformed/non-positive)
    // dict is not a winning contract; production's own gate
    // (ChargerReader.parse's `hasWinningContract: hasWinningContract &&
    // maxWatts > 0`) requires the same thing. Not observed to make a
    // difference on this corpus (every WinningPowerSourceOption block found
    // here does carry a positive Max Power), but the detector must match
    // production's rule rather than happen to agree with it by accident.
    //
    // Made non-private (rather than private to this type) so
    // IndependentUSBCWinningNodeCheck below can reuse the same scan for its
    // own independent re-derivation of the USB-C-node machine count.
    static func probe17HasWinningUSBCContract(_ output: String) -> Bool {
        var inPowerSourceBlock = false
        var isUSBC = false
        var isUSBPD = false
        var winningMaxPowerMW: Int?
        var found = false

        // Set while inside the WinningPowerSourceOption nested dict, cleared
        // at its closing brace (brace-depth tracked, same technique
        // ProbeCorpus.braceDelta uses, written fresh here rather than shared:
        // see this file's header on not calling ProbeCorpus's block parsers).
        // This keeps a "Max Power (mW)" line elsewhere in the block (there is
        // none today, since PowerSourceOptions is always the opaque
        // `<CFType 17>` placeholder in this corpus) from being mistaken for
        // the winning contract's own value.
        var inWinningOption = false
        var winningOptionDepth = 0

        func flush() {
            if inPowerSourceBlock && isUSBC && isUSBPD && (winningMaxPowerMW ?? 0) > 0 { found = true }
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--- ") {
                flush()
                inPowerSourceBlock = trimmed.contains("IOPortFeaturePowerSource[")
                isUSBC = false
                isUSBPD = false
                winningMaxPowerMW = nil
                inWinningOption = false
                winningOptionDepth = 0
                continue
            }
            guard inPowerSourceBlock else { continue }

            if inWinningOption {
                winningOptionDepth += braceDelta(in: String(rawLine))
                if winningOptionDepth <= 0 {
                    inWinningOption = false
                    continue
                }
                if trimmed.hasPrefix("Max Power (mW):") {
                    winningMaxPowerMW = intValue(afterPrefix: "Max Power (mW):", in: trimmed)
                }
                continue
            }

            if trimmed.hasPrefix("ParentPortTypeDescription: \"USB-C\"") { isUSBC = true }
            if trimmed.hasPrefix("PowerSourceName: \"USB-PD\"") { isUSBPD = true }
            if trimmed.hasPrefix("WinningPowerSourceOption: {") {
                inWinningOption = true
                winningOptionDepth = 1
            }
        }
        flush()

        return found
    }

    // Net brace depth a line contributes, ignoring braces inside a quoted
    // string. A local copy of ProbeCorpus.braceDelta's rule rather than a
    // shared call: this file's whole point is not depending on the parser
    // it is cross-checking.
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

    // "Max Power (mW): 86000 (0x14ff0)" -> 86000. Stops at the first space
    // after the prefix, so the parenthesised hex echo is dropped rather than
    // tripping Int's parse.
    private static func intValue(afterPrefix prefix: String, in trimmed: String) -> Int? {
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    static func count() -> (upperBound: Int, checked: Int) {
        var upperBound = 0
        var checked = 0

        for machine in ProbeCorpus.machines {
            guard let probe32 = machine.probe("32_smart_battery_full_keys.json"),
                  probe32.utf8.count != 65536,
                  probe32ExternallyConnected(probe32)
            else { continue }

            guard let probe17 = machine.probe("17_deep_property_dump.json"),
                  probe17.utf8.count != 65536,
                  !probe17HasWinningUSBCContract(probe17)
            else { continue }

            guard let probe34 = machine.probe("34_smc_power_keys.json") else { continue }
            let keys = ProbeCorpus.smcKeys(in: probe34)
            guard !keys.isEmpty else { continue }

            guard let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }
            let usbCUUIDs = Set(
                ProbeCorpus.roster(in: rosterOutput)
                    .filter { $0.portType == "USB-C" }
                    .map { $0.uuid.replacingOccurrences(of: "-", with: "").lowercased() }
            )
            guard !usbCUUIDs.isEmpty else { continue }

            checked += 1

            let plausible = contracts(fromKeys: keys).filter { contract in
                guard contract.voltageMV >= 4_500, contract.currentMA > 0 else { return false }
                let product = Double(contract.voltageMV) * Double(contract.currentMA) / 1000.0
                return abs(product - Double(contract.powerMW)) / Double(contract.powerMW) <= 0.02
            }
            if plausible.contains(where: { usbCUUIDs.contains($0.uuid) }) {
                upperBound += 1
            }
        }

        return (upperBound, checked)
    }
}

// MARK: - DAR-248 review fix: USB-C-winning-node machine count

// A genuine independent re-derivation of the "199 machines have a winning
// USB-C node contract" figure PowerAttributionReplayTests' own
// magSafeAndUSBCNeverBothClaimIncoming asserts as a floor. Restricted to the
// same five-probe eligibility gate the main replay requires
// (isIndependentlyReplayEligible above), not merely "every machine with a
// readable probe 17": production's `usbCNodeMachines` count is over
// `replayed`, the set that assembled a complete snapshot, and a raw count
// over every machine with any probe 17 at all runs well above that (334 of
// 1176 in this corpus, versus 199 of the 593 that are actually replayed), so
// comparing an unrestricted scan against the replay's count would not be
// checking the same population.
//
// Shares probe17HasWinningUSBCContract with IndependentSMCFallbackCheck
// (the fixed detector above): both need the same "does this probe 17 show a
// winning USB-C contract" answer, and duplicating that scan would risk the
// two copies drifting apart rather than one shared, once-fixed rule.
enum IndependentUSBCWinningNodeCheck {
    static func count() -> Int {
        var total = 0

        for machine in ProbeCorpus.machines {
            guard isIndependentlyReplayEligible(machine) else { continue }
            guard let probe17 = machine.probe("17_deep_property_dump.json") else { continue }
            if IndependentSMCFallbackCheck.probe17HasWinningUSBCContract(probe17) {
                total += 1
            }
        }

        return total
    }
}
