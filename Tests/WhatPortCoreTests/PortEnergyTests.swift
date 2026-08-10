import Foundation
import Testing
@testable import WhatPortCore

// Per-port session energy (DAR-290): the AccumulatedPower / AccumulatorCount
// pair from AppleSmartBattery.PowerOutDetails and its conversion to watt-hours.
// The Flight Recorder side lives in PortEnergyRecorderTests.

// MARK: - PortEnergy conversions

// The reference measurement the whole feature rests on: an iPad drawing
// ~15.2 W for 236 s read back as 3591137 mJ over 236 samples, which is 1.00 Wh
// both via the accumulator and via watts x seconds. If the 1 Hz tick were ever
// wrong, this is the test that would say so.
@Test func portEnergyConvertsTheMeasuredReferenceReading() {
    let energy = PortEnergy(millijoules: 3_591_137, sampleCount: 236)
    #expect(abs(energy.wattHours - 0.9975) < 0.001)
    #expect(abs(energy.averageWatts - 15.216) < 0.01)
    #expect(energy.duration == 236)
    // Cross-check: the same figure computed the other way round.
    #expect(abs(energy.wattHours - (energy.averageWatts * energy.duration / 3600)) < 0.0001)
}

@Test func portEnergyHandlesAZeroCount() {
    let energy = PortEnergy(millijoules: 0, sampleCount: 0)
    #expect(energy.wattHours == 0)
    #expect(energy.averageWatts == 0)   // must not divide by zero
    #expect(!energy.isAtCounterCap)
}

// AccumulatorCount is 16-bit. Past its ceiling the figure is a floor and the UI
// has to say so, so the flag trips before 65535 rather than at it: the firmware
// updates in ~60 s bursts, so a read can land ~60 short of the cap and the next
// one would already be over.
@Test func portEnergyFlagsTheSixteenBitCeiling() {
    #expect(!PortEnergy(millijoules: 1, sampleCount: 64_999).isAtCounterCap)
    #expect(PortEnergy(millijoules: 1, sampleCount: 65_000).isAtCounterCap)
    #expect(PortEnergy(millijoules: 1, sampleCount: 65_535).isAtCounterCap)
}

// MARK: - PortManager wiring

private func energyPowerInput(
    port: Int = 1,
    watts: Int = 15_000,
    accumulated: Int = 3_591_137,
    count: Int = 236
) -> PowerInput {
    PowerInput(
        portIndex: port,
        watts: watts,
        current: 2904,
        adapterVoltage: 5181,
        configuredVoltage: 5000,
        configuredCurrent: 3000,
        vconnCurrent: 17,
        accumulatedPowerMJ: accumulated,
        accumulatorCount: count
    )
}

private func energyPorts(_ power: [PowerInput]) -> [PortState] {
    let manager = PortManager()
    manager.applySnapshot(
        PortManagerSnapshot(
            phyData: [PhyInput(phyID: 0)],
            tbData: [ThunderboltInput(socketID: 1)],
            powerData: power
        )
    )
    return manager.ports
}

@Test func portManagerSurfacesTheEnergyAccumulator() {
    let energy = energyPorts([energyPowerInput()]).first { $0.id == 1 }?.energy
    #expect(energy?.sampleCount == 236)
    #expect(energy.map { abs($0.wattHours - 0.9975) < 0.001 } == true)
}

// A port can be attached and momentarily drawing nothing, which clears
// `power`. The session total is still the answer to "how much has this port
// given it", so it must not vanish with the live reading.
@Test func portManagerKeepsEnergyWhenThePortDropsToZeroWatts() {
    let port = energyPorts([energyPowerInput(watts: 0)]).first { $0.id == 1 }
    #expect(port?.power == nil)
    #expect(port?.energy?.sampleCount == 236)
}

// Desktops, Intel Macs, and any port macOS publishes no accumulator for.
@Test func portManagerLeavesEnergyNilWithoutAnAccumulator() {
    let ports = energyPorts([energyPowerInput(accumulated: 0, count: 0)])
    #expect(ports.first { $0.id == 1 }?.energy == nil)
}

// The registry value's width is undocumented. If it ever arrives sign-extended
// past bit 31, no figure is better than a negative "delivered" reading.
@Test func portManagerRejectsANegativeAccumulator() {
    let ports = energyPorts([energyPowerInput(accumulated: -1_000, count: 500)])
    #expect(ports.first { $0.id == 1 }?.energy == nil)
}

// The accumulator only counts power OUT. A port the correlation settled as
// incoming (a charger) must not carry an energy figure, whatever PowerOutDetails
// happened to hold for that index. Reachable in practice: a stale accumulator
// at 0 W leaves `power` nil, which is exactly the state the charger path claims.
@Test func portManagerDropsEnergyOnAnIncomingPort() {
    let manager = PortManager()
    manager.applySnapshot(
        PortManagerSnapshot(
            hpmPorts: [HPMPortInput(uuid: "AAAA-1", portNumber: 1, portType: "USB-C")],
            powerData: [energyPowerInput(watts: 0)],
            ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)],
            chargerData: [
                ChargerInput(
                    portType: "USB-C",
                    portNumber: 1,
                    maxWatts: 96_000,
                    voltage: 20_000,
                    maxCurrent: 4_800,
                    hasWinningContract: true
                )
            ],
            chargingPower: ChargingPowerInput(systemPowerIn: 60_000, systemVoltageIn: 20_000, systemCurrentIn: 3_000)
        )
    )
    let port = manager.ports.first { $0.power?.direction == .incoming }
    #expect(port != nil)
    #expect(port?.energy == nil)
}
