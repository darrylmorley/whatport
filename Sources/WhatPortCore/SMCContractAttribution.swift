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
// WHAT IT CANNOT DO. It never reports MagSafe: the SMC has never carried a
// MagSafe contract in the corpus, so a MagSafe match here would be a join error
// rather than a discovery. And desktops publish none of these keys at all.
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

    // Every USB-C contract starts at 5 V, so anything below that is a
    // partially-populated channel rather than a charger.
    private static let minimumContractVoltageMV = 5_000

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
        // The signal is the MagSafe port being CONNECTED, not a MagSafe node
        // existing. The first version of this gate used node presence and was
        // wrong: on this M5, `IOPortFeaturePowerSource` with `PowerSourceName`
        // "USB-PD" is published under MagSafe 3 while `ConnectionActive` is No
        // and nothing is plugged into it. Keying on the node would decline on
        // every machine that publishes eagerly, which would quietly kill this
        // whole path the moment a future Pro/Max behaves like the M5 does.
        let anyIncomingPower = ports.contains { $0.power?.direction == .incoming }
        let magSafeConnected = ports.contains { $0.portType == .magSafe && $0.ccConnected }
        guard !anyIncomingPower,
              !magSafeConnected,
              !macOSDescribesCharging(chargerNodes: chargerNodes)
        else { return nil }

        // Ports macOS published a node for, bare or not. A bare node means
        // macOS is describing that port and simply has not settled on a
        // contract yet, which is mid-negotiation rather than this bug.
        let portsWithNode = Set(
            chargerNodes.filter { $0.portType == "USB-C" }.map(\.portNumber)
        )

        let candidates = contracts.compactMap { contract -> (portID: Int, contract: SMCPortContractInput)? in
            // GATE 3: a plausible charging contract.
            guard contract.powerMW > 0, contract.voltageMV >= minimumContractVoltageMV else { return nil }

            // GATE 4: not the Mac's own output. The label is empty on plenty of
            // genuine chargers so its absence proves nothing, but when it does
            // say "usb host" it is describing power going the other way.
            guard !contract.label.lowercased().contains(outgoingLabel) else { return nil }

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

    // Normalise an HPM UUID to the SMC DxUI form: dashes stripped, lowercase
    // (e.g. "6230AF2D-EE59-..." -> "6230af2dee59...").
    public static func normalisedUUID(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
