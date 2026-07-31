import Foundation

// Ties an SMC charging contract to the physical port receiving it, for the
// machines where macOS publishes that contract nowhere else.
//
// THE PROBLEM. M1 Pro, M1 Max and M1 Ultra never publish a USB-C
// IOPortFeaturePowerSource node. That node is the only thing ChargerReader
// reads, so on those machines a user charging a 14"/16" MacBook Pro over USB-C
// sees a connected port with no power at all, while the Mac draws 100 W.
//
// THE DATA. The contract is in the SMC all along, on the same D1..D4 channels
// the power-OUT figures use: DxMP / DxMV / DxMI, joined to a physical port by
// the DxUI controller UUID, which is the join applySMCPower already trusts.
//
// WHY IT IS TRUSTED. Measured by WhatCable across its customer-probe corpus:
// the DxUI join lands on a known HPM controller on 464 of 464 machines
// carrying both probes (190 of them M1 and M2, exactly the silicon that needs
// it), DxMV x DxMI = DxMP on 455 of 455 checks, and where a real node exists to
// compare against, 182 of 185 shared USB-C ports match on watts, volts and
// amps. WhatCable shipped this route in its 1.3.0 beta and testers on the
// affected hardware confirmed it holds.
//
// WHAT IT DOES NOT DO. It never attributes to MagSafe. Not because the SMC is
// silent there (it publishes MagSafe contract channels on 118 corpus machines,
// contrary to what this comment claimed at first) but because the node is
// macOS's own answer for MagSafe and outranks anything synthesized. Those
// channels are still read: `PortManager` uses them as evidence of which
// connector is being fed. Desktops publish none of these keys at all.
public enum SMCContractAttribution {

    // A single switch. Turning this off returns every affected port to the
    // no-data state it had before this existed:
    //
    //   defaults write app.whatport.whatport SMCContractDisabled -bool YES
    //
    // This is the one power path that can turn a fail-closed bug into a
    // fail-open one: everything else here either shows nothing or shows a
    // measurement, whereas this puts a negotiated figure against a port we
    // inferred. If a machine in the wild disagrees with it, the recovery is
    // flipping this, not unpicking the correlation, and a defaults key means
    // support can do that without shipping a build.
    //
    // Read-only, so it stays concurrency-safe. `resolve` takes the value as a
    // parameter defaulting to this rather than reading it directly: WhatCable's
    // version read a mutable global, and the test that flipped it off raced
    // every other test in its suite, which looked exactly like a logic bug.
    public static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "SMCContractDisabled")
    }

    // The label the SMC uses for a channel that is SOURCING power to a
    // peripheral rather than receiving it. A contract on such a channel is the
    // Mac's own output and must never be shown as an incoming charge.
    private static let outgoingLabel = "usb host"

    // USB-C's lowest rail is 5 V, but the SMC does not always report it as
    // exactly 5000: six machines in the probe corpus report a real 5 V contract
    // as 4750 mV, which is inside USB-PD's 5% tolerance. A 5000 floor rejected
    // all six, so a Mac charging slowly from a weak source (a phone charger, a
    // bus-powered hub, a display's low-power port) showed no power at all.
    //
    // 4500 clears the tolerance band while staying far above anything a partial
    // read produces: the corpus holds nothing at all between 0 and 4750.
    private static let minimumContractVoltageMV = 4_500

    // How far DxMV x DxMI may stray from DxMP before the channel is treated as
    // half-read.
    //
    // Every one of the 463 contracts in the probe corpus agrees exactly, to
    // 0.000%, which says DxMP is the firmware's own product rather than a third
    // measurement. So this is not a rounding allowance and the check is not
    // three readings corroborating each other, as a first version of this
    // comment claimed. What it catches is one of the three keys failing to read
    // or coming back stale, which breaks the identity: three separate kernel
    // round trips are made per channel and nothing makes them a snapshot.
    //
    // The band is for that case, not for rounding. Kept small because nothing
    // real sits near it, and a mid-renegotiation tick where the keys are
    // sampled a syscall apart is meant to decline for one poll rather than
    // publish a figure assembled from two different contracts.
    private static let contractConsistencyTolerance = 0.02

    // Power out on the same channel, above which the channel is the Mac
    // sourcing to a peripheral rather than being fed.
    //
    // Small but not zero: an idle channel can report a few milliwatts of noise.
    private static let outgoingPowerFloorWatts = 0.5

    // Resolve this tick's SMC contracts to at most one port.
    //
    // - Parameters:
    //   - contracts: the SMC contract channels read this tick.
    //   - ports: every port built so far, USB-C and MagSafe, with any power
    //     already attributed by the readers that outrank this one.
    //   - chargerNodes: every IOPortFeaturePowerSource macOS published,
    //     including bare nodes carrying no PDO.
    //   - externalConnected: whether the Mac reports external power.
    // - Returns: the port id and the contract to show on it, or nil when any
    //   gate fails. Naming the wrong port is worse than naming none, so every
    //   gate declines rather than guessing.
    public static func resolve(
        contracts: [SMCPortContractInput],
        ports: [PortState],
        chargerNodes: [ChargerInput],
        externalConnected: Bool,
        powerOut: [SMCPortPowerInput] = [],
        enabled: Bool = isEnabled
    ) -> (portID: Int, contract: SMCPortContractInput)? {
        guard enabled else { return nil }

        // GATE 1: nothing is charging, so there is no contract to describe.
        guard externalConnected else { return nil }

        // GATE 2: macOS has already answered somewhere, so stay quiet. This is
        // cross-port on purpose: without it, an M1 Pro charging on MagSafe with
        // a dock on USB-C would show the dock's contract as though the Mac were
        // charging from it. Three halves, and each covers a case the others
        // miss.
        //
        // A port already showing incoming power is the obvious one. A winning
        // USB-PD contract anywhere covers a port whose power has not been
        // attributed yet.
        //
        // The third exists because the first two leave a hole: `externalConnected`
        // is system-wide, and a MagSafe port only receives an incoming reading
        // while the battery is actively charging. Sit at 100% on MagSafe, or let
        // optimised charging pause at 80%, and neither of the first two fires,
        // so a USB-C peripheral's contract could become the sole candidate and
        // be presented as the Mac's charge.
        //
        // That case is caught by the incoming-power check itself, because the
        // non-USB-C ports are built and attributed BEFORE this runs: a MagSafe
        // port that is genuinely the one delivering already carries incoming
        // power by now, whatever the battery is doing.
        //
        // This deliberately no longer declines merely because a MagSafe port is
        // connected. It did, briefly, and that was too blunt in a common setup:
        // an M1 Pro charging through a USB-C dock with a MagSafe cable also
        // plugged into the wall left BOTH cards blank, silently disabling the
        // one path that machine has. A connected MagSafe that is not delivering
        // is just a cable.
        //
        // What makes that safe is the SMC's own behaviour: `DxMP` is only
        // populated for power coming IN. Across 449 corpus contract channels,
        // none was simultaneously sourcing power outward, so a channel carrying
        // a contract is a port being fed, not a peripheral being powered.
        let anyIncomingPower = ports.contains { $0.power?.direction == .incoming }
        guard !anyIncomingPower,
              !macOSDescribesCharging(chargerNodes: chargerNodes)
        else { return nil }

        // Ports macOS published a node for, bare or not. A bare node means
        // macOS is describing that port and simply has not settled on a
        // contract yet, which is mid-negotiation rather than this bug.
        let portsWithNode = Set(
            chargerNodes.filter { $0.portType == "USB-C" }.map(\.portNumber)
        )

        // The same channels' power-OUT readings, keyed by the join this file
        // already trusts, so a contract can be checked against its own channel.
        let powerOutByUUID = Dictionary(
            powerOut.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let candidates = contracts.compactMap { contract -> (portID: Int, contract: SMCPortContractInput)? in
            // GATES 3 and 4: a plausible charging contract, and not the Mac's
            // own output. See `isPlausibleIncomingContract`, which every caller
            // asking this question shares.
            guard isPlausibleIncomingContract(
                contract,
                powerOut: powerOutByUUID[contract.uuid]
            ) else { return nil }

            // GATE 5: the channel resolves to a port through the UUID join. No
            // guessing by channel index: the SMC D-index is not the physical
            // port number (verified on M5: D3 = USB-C@4, D4 = MagSafe@1).
            guard let port = ports.first(where: {
                guard let uuid = $0.uuid else { return false }
                return normalisedUUID(uuid) == contract.uuid
            }) else { return nil }

            // GATE 6: the port must be a connected USB-C port with nothing
            // already on it and no node of its own.
            guard port.portType == .usbC, port.ccConnected, port.power == nil else { return nil }
            guard !portsWithNode.contains(port.id) else { return nil }

            return (port.id, contract)
        }

        // Exactly one, or stay silent. Two candidates means the join is
        // ambiguous, and that is the misattribution this whole path is written
        // to avoid.
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    // True when macOS has already published a negotiated contract of its own,
    // anywhere on the machine.
    //
    // Split out so the IOKit layer can ask the same question BEFORE paying for
    // the SMC read, rather than reading data this layer is certain to discard.
    // One function, not two matching conditions: the first version of the read
    // gate restated this and immediately disagreed with it.
    //
    // Deliberately only the node-based half of gate 2. The connected-MagSafe
    // half needs live port state the reader does not have, and a read gate must
    // never skip a read the attribution might have used, so it stays the
    // narrower of the two. Reading occasionally more than strictly needed costs
    // a few kernel calls; reading less would cost the reading itself.
    public static func macOSDescribesCharging(chargerNodes: [ChargerInput]) -> Bool {
        chargerNodes.contains { $0.hasWinningContract }
    }

    // True when an SMC contract channel resolves to a connected USB-C port.
    //
    // This is evidence that USB-C is the connector taking power IN, and it is
    // needed even when the gates above decline to put a figure on that port.
    // On M1 Pro / Max / Ultra there is no USB-C node to look at, so without
    // this the only reading of "no USB-C contract anywhere" is "USB-C is not
    // charging", and a MagSafe cable that happens to be plugged in would claim
    // the machine's whole power-in figure while USB-C actually carried it.
    //
    // Deliberately not gated on `isEnabled`: the rollback switch exists to stop
    // this path PUTTING A FIGURE on a card, not to make the rest of the app
    // forget what the SMC plainly says about which port is fed.
    // A channel that looks like a real charge coming in: positive power, a
    // voltage at or above the floor, three figures that describe one contract,
    // and no sign the channel is the Mac sourcing power outward.
    //
    // Shared so every caller asking "is this channel evidence of a port being
    // fed" applies the same rules.
    //
    // `powerOut` is the same channel's DxJV / DxJI reading, when the caller has
    // it. Direction is the one thing worth being sure of here, and a label is
    // thin evidence for it: only 1 of 463 corpus contracts carries the "usb
    // host" label, so an outgoing channel is far more likely to be unlabelled
    // than labelled. A measured outgoing draw is not thin evidence. Nothing in
    // the corpus has both (0 of 463 contract channels report any power out), so
    // this rejects nothing real and closes the case the label cannot.
    public static func isPlausibleIncomingContract(
        _ contract: SMCPortContractInput,
        powerOut: SMCPortPowerInput? = nil
    ) -> Bool {
        guard contract.powerMW > 0, contract.voltageMV >= minimumContractVoltageMV else { return false }
        guard isInternallyConsistent(contract) else { return false }
        guard !contract.label.lowercased().contains(outgoingLabel) else { return false }
        guard !isSourcingPowerOut(powerOut) else { return false }
        return true
    }

    // Whether the channel is measurably feeding a peripheral.
    static func isSourcingPowerOut(_ powerOut: SMCPortPowerInput?) -> Bool {
        guard let powerOut else { return false }
        return powerOut.watts > outgoingPowerFloorWatts
    }

    // Whether DxMV x DxMI reproduces DxMP, which is what catches a channel
    // where one of the three keys failed to read or came back stale. See the
    // tolerance above for why this is not a rounding allowance.
    //
    // Self-guarding rather than relying on the caller's checks, so a direct
    // caller cannot divide by a zero wattage.
    static func isInternallyConsistent(_ contract: SMCPortContractInput) -> Bool {
        guard contract.powerMW > 0, contract.currentMA > 0 else { return false }
        let product = Double(contract.voltageMV) * Double(contract.currentMA) / 1000.0
        let stated = Double(contract.powerMW)
        return abs(product - stated) / stated <= contractConsistencyTolerance
    }

    public static func hasUSBCContractCandidate(
        contracts: [SMCPortContractInput],
        ports: [PortState],
        powerOut: [SMCPortPowerInput] = []
    ) -> Bool {
        let powerOutByUUID = Dictionary(
            powerOut.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return contracts.contains { contract in
            guard isPlausibleIncomingContract(
                contract,
                powerOut: powerOutByUUID[contract.uuid]
            ) else { return false }
            return ports.contains { port in
                guard let uuid = port.uuid else { return false }
                return normalisedUUID(uuid) == contract.uuid
                    && port.portType == .usbC
                    && port.ccConnected
            }
        }
    }

    // Normalise an HPM UUID to the SMC DxUI form: dashes stripped, lowercase
    // (e.g. "6230AF2D-EE59-..." -> "6230af2dee59...").
    public static func normalisedUUID(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
