import SwiftUI
import WhatPortCore
import WhatPortAppKit

struct PortListView: View {
    // Compact base width. Widens with the font scale (only grows, never shrinks
    // below 320) so larger text gets room to breathe instead of truncating
    // sooner. AppDelegate uses the same formula for the popover's initial size.
    static let baseWidth: CGFloat = 320
    static func width(forScale scale: Double) -> CGFloat {
        baseWidth * max(1, scale)
    }

    var portManager: PortManager
    var footerContext: FooterContext
    @State private var selectedPortID: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Observed here so changing the slider re-renders this root and pushes the
    // new multiplier down through the whole popover/window tree via .environment.
    @ObservedObject private var fontScale = FontScaleStore.shared

    // Drives the "update available" banner at the top of the list.
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            if let panelIndex = footerContext.showingPanelIndex {
                pluginPanel(index: panelIndex)
                    .transition(pushTransition(edge: .trailing))
            } else if footerContext.showingSettings {
                settingsPanel
                    .transition(pushTransition(edge: .trailing))
            } else if let selectedID = selectedPortID,
               let port = portManager.ports.first(where: { $0.id == selectedID }) {
                detailView(port: port)
                    .transition(pushTransition(edge: .trailing))
            } else {
                listView
                    .transition(pushTransition(edge: .leading))
            }
        }
        .clipped()
        .frame(width: Self.width(forScale: fontScale.fontSize))
        // macOS 26 (Tahoe) renders NSPopover with a very translucent Liquid
        // Glass material. On a dark desktop the content bleeds through and is
        // hard to read (issue #1). Back the content with a thick material so
        // text stays legible while keeping a subtle frosted look.
        .background(.thickMaterial)
        .environment(\.fontScale, fontScale.fontSize)
    }

    // Push-style navigation: panels slide in from an edge with a fade, like a
    // NavigationStack push. Falls back to a plain fade when Reduce Motion is on.
    private func pushTransition(edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }

    // MARK: - Plugin panel (e.g. Pro upsell)

    @ViewBuilder
    private func pluginPanel(index: Int) -> some View {
        let panels = PluginRegistry.shared.panelBuilders
        if index < panels.count {
            panels[index]({
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.footerContext.dismissPanel()
                }
            })
            .frame(height: 420)
        }
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if portManager.confirmedPortDataTier == .thunderboltOnly {
                reducedDetailBanner
                Divider()
            }

            if let update = updates.available {
                UpdateBanner(update: update)
                Divider()
            }

            if portManager.ports.isEmpty {
                emptyState
                Spacer()
            } else {
                ScrollView {
                    portList
                }
            }
            Divider()
            footer
        }
        .frame(height: 420)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Ports")
                .scaledFont(.title3, weight: .semibold)
            Spacer()
            if portManager.portCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(portManager.activePortCount)/\(portManager.portCount) active")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                    if !headerPowerLabel.isEmpty {
                        Text(headerPowerLabel)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !systemWallPowerLabel.isEmpty {
                        Text(systemWallPowerLabel)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // Builds the power summary string for the header.
    // Shows "X W in", "X W out", or both joined by " · " when both directions are active.
    // Returns empty string when no power is flowing so the caller can hide the label.
    private var headerPowerLabel: String {
        let inWatts = portManager.totalWattsIn
        let outWatts = portManager.totalWattsOut
        switch (inWatts > 0, outWatts > 0) {
        case (true, true):
            return WattsFormat.string(inWatts) + " in \u{00B7} " + WattsFormat.string(outWatts) + " out"
        case (true, false):
            return WattsFormat.string(inWatts) + " in"
        case (false, true):
            return WattsFormat.string(outWatts) + " out"
        case (false, false):
            return ""
        }
    }

    // On an unplugged laptop the SMC DC-in rail (VD0R/ID0R/PDTR) does not
    // read exactly zero, it reads a few milliwatts. Desktop Macs (the only
    // intended audience for this line) idle far above that, so a 1 W floor
    // filters the ghost reading without hiding real wall power.
    private static let minimumWallPowerWatts = 1.0

    // Desktop Macs (Mac mini / Studio / Pro) have no battery controller, so
    // chargingStatus is always nil and headerPowerLabel's "X W in" never
    // fires for them even while genuinely drawing wall power. Gated on
    // chargingStatus == nil so a laptop, which already shows that figure via
    // headerPowerLabel, never displays it twice.
    private var systemWallPowerLabel: String {
        guard portManager.chargingStatus == nil,
              let watts = portManager.systemWallPowerWatts, watts >= Self.minimumWallPowerWatts
        else { return "" }
        return WattsFormat.string(watts) + " from wall"
    }

    // Reduced-detail note: this Mac's port controller doesn't publish the
    // HPM roster (Intel, or an Apple Silicon Mac without one), so the app is
    // running on the Thunderbolt socket roster alone. Kept quiet (footnote,
    // secondary) rather than a full banner: it's informational, not a warning.
    private var reducedDetailBanner: some View {
        Text("Reduced detail: this Mac doesn't report USB-C port-controller data.")
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if portManager.confirmedPortDataTier == .none {
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal")
                    .scaledFont(.title2)
                    .foregroundStyle(.tertiary)
                Text(portManager.thunderboltControllerPresentButSilent
                     ? "No ports reported"
                     : "No ports found on this Mac")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
                Text(portManager.thunderboltControllerPresentButSilent
                     ? "This Mac has a Thunderbolt controller, but it isn't publishing any ports right now."
                     : "WhatPort couldn't find any Thunderbolt or USB-C ports to monitor.")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal")
                    .scaledFont(.title2)
                    .foregroundStyle(.tertiary)
                Text("Scanning ports\u{2026}")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private var portList: some View {
        VStack(spacing: 4) {
            ForEach(portManager.ports) { port in
                PortRowView(
                    port: port,
                    isCharging: portManager.isCharging,
                    fullyCharged: portManager.fullyCharged,
                    lifecyclePhase: portManager.lifecyclePhases[port.id]
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedPortID = port.id
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()

            // Plugin footer buttons (Flight Recorder, etc.)
            ForEach(
                Array(PluginRegistry.shared.footerButtonBuilders.enumerated()),
                id: \.offset
            ) { _, builder in
                builder(footerContext)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    footerContext.showingSettings = true
                }
            } label: {
                Image(systemName: "gear")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Detail View

    private func detailView(port: PortState) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedPortID = nil
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .scaledFont(.body)
                    .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            PortDetailView(
                port: port,
                powerHistory: portManager.powerHistory[port.id] ?? [],
                powerMeteringAvailable: portManager.powerMeteringAvailable,
                isCharging: portManager.isCharging,
                fullyCharged: portManager.fullyCharged,
                chargingStatus: portManager.chargingStatus,
                acknowledged: portManager.recorder?.acknowledgedCounters(forPort: port.id),
                // Live tier, not the confirmed one: this hides the lane card,
                // and hiding it a snapshot early is harmless where showing a
                // lane state the snapshot has no PHY for would be a false
                // claim. The banner and empty state use the confirmed tier,
                // because those are wording rather than data.
                reducedDetail: portManager.portDataTier == .thunderboltOnly
            )
        }
        .frame(height: 560)
    }
    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        footerContext.showingSettings = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .scaledFont(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // Scroll the settings body so the pinned Back header above stays
            // tappable. Without this, a tall body - e.g. when the Pro Flight
            // Recorder plugin injects its licence / history / health-counter
            // sections - overflows the fixed 420pt panel, gets cut off by the
            // outer .clipped(), and pushes Back above the visible area with no
            // way to reach it.
            //
            // minHeight = the viewport height keeps SettingsView filling the
            // panel when its content is short (base build), so its trailing
            // Spacer still pins the About block to the bottom instead of
            // bunching it under the toggles. When the body is taller than the
            // viewport (Pro sections present), it simply scrolls.
            GeometryReader { proxy in
                ScrollView {
                    SettingsView()
                        .frame(minHeight: proxy.size.height)
                }
            }
        }
        .frame(height: 420)
    }
}

// MARK: - Port Row

struct PortRowView: View {
    let port: PortState
    var isCharging: Bool = false
    var fullyCharged: Bool = false
    var lifecyclePhase: PortLifecyclePhase? = nil
    @State private var isHovered = false
    // Drives the indicator dot's breathing opacity while a lifecycle phase is
    // active. Toggled once per phase start inside a repeatForever animation
    // (see protocolIndicator), not polled.
    @State private var isPulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            protocolIndicator
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(titleText)
                        .scaledFont(.body, weight: .semibold)
                        .foregroundStyle(port.isActive || lifecyclePhase != nil ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Show port number next to device name so you know which port
                    if port.deviceName != nil && port.isActive {
                        Text(portLabel)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summaryText)
                    .scaledFont(.subheadline)
                    .foregroundStyle(port.isActive ? .secondary : .tertiary)
                    .lineLimit(1)
                    // A plain String swap on Text is not animatable on its own; this
                    // is what makes the row-level .animation(value: lifecyclePhase)
                    // actually cross-fade Detecting/Negotiating/the real summary
                    // instead of snapping between them.
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            if let power = port.power {
                Text(WattsFormat.string(power.watts))
                    .scaledFont(.body, design: .rounded, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Image(systemName: "chevron.right")
                .scaledFont(.caption)
                .foregroundStyle(isHovered ? .tertiary : .quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            // A lifecycle phase counts as emphasised too: attach signals arrive
            // before the poll flips isActive, so without this the row sits dim
            // under a pulsing dot instead of reading as a live row.
            if port.isActive || lifecyclePhase != nil || isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowFill)
            }
        }
        .overlay {
            if port.isActive || lifecyclePhase != nil || isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 6)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        // Cross-fades the status text/dot when a lifecycle phase starts,
        // changes, or hands off to the normal connected rendering.
        .animation(.easeInOut(duration: 0.2), value: lifecyclePhase)
        .onAppear { updatePulse(for: lifecyclePhase) }
        .onChange(of: lifecyclePhase) { _, newPhase in
            updatePulse(for: newPhase)
        }
        // Reduce Motion can be toggled mid-phase (System Settings, or the
        // accessibility shortcut), so the pulse has to react to it directly,
        // not just at phase start.
        .onChange(of: reduceMotion) { _, _ in
            updatePulse(for: lifecyclePhase)
        }
    }

    // Starts (or stops) the indicator dot's breathing opacity for the
    // duration of a lifecycle phase. detecting -> negotiating leaves an
    // already-running pulse alone (no restart, no stacked animations); only
    // a genuine start or stop touches isPulsing.
    private func updatePulse(for phase: PortLifecyclePhase?) {
        guard phase != nil, !reduceMotion else {
            // repeatForever's stop/restart idiom is known-unreliable on some
            // SwiftUI versions when the property is just assigned outside an
            // animation block. A zero-duration animation deterministically
            // replaces the repeating animation on this property instead of
            // relying on transaction coalescing.
            withAnimation(.linear(duration: 0)) {
                isPulsing = false
            }
            return
        }
        guard !isPulsing else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }

    // Neutral gray cards. No protocol color in the fill.
    private var rowFill: Color {
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return Color.primary.opacity(0.04)
    }

    // When a device is connected, promote its name to the title line.
    // Falls back to the port label (Port 1, MagSafe, etc).
    private var titleText: String {
        if let device = port.deviceName, port.isActive {
            return device
        }
        return portLabel
    }

    private var portLabel: String {
        switch port.portType {
        case .magSafe: return "MagSafe"
        case .usbC: return "Port \(port.id)"
        }
    }

    private var protocolIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 12, height: 12)
            // Gated on !reduceMotion too so the dot snaps to fully opaque the
            // instant Reduce Motion is enabled, rather than waiting on
            // isPulsing's last animated value to settle.
            .opacity(lifecyclePhase != nil && !reduceMotion && isPulsing ? 0.4 : 1.0)
    }

    // A phase in progress overrides the committed protocol colour with a
    // neutral "working" tint, distinct from every committed state below.
    private var indicatorColor: Color {
        if lifecyclePhase != nil {
            return .cyan
        }
        switch port.primaryProtocol {
        case .thunderbolt: return .blue
        case .displayPort: return .orange
        case .usbOnly: return .green
        case .charging: return .yellow
        case .idle: return .gray.opacity(0.4)
        }
    }

    // Protocol and speed only. Device name is in the title now,
    // so this line stays short enough to fit without truncation.
    private var summaryText: String {
        if let phase = lifecyclePhase {
            switch phase {
            case .detecting: return "Detecting\u{2026}"
            case .negotiating: return "Negotiating\u{2026}"
            }
        }

        guard port.isActive else { return "Idle" }

        if let tb = port.thunderboltLink, port.hasLiveThunderboltLink {
            let lanes = formatLanes(tx: tb.txLanes, rx: tb.rxLanes)
            return "\(tb.generation.label) \(lanes), \(tb.totalGbps) Gbps"
        }

        if port.lane0.transport == .displayPort || port.lane1.transport == .displayPort {
            let dpLive = port.liveTransports.first { $0.kind == .displayPort }
            if let dp = dpLive, !dp.dataRate.isEmpty {
                let lanes = dp.laneCount > 0 ? ", \(dp.laneCount) lane\(dp.laneCount > 1 ? "s" : "")" : ""
                return "DP alt-mode, \(dp.dataRate)\(lanes)"
            }
            let dpLanes = [port.lane0, port.lane1].filter { $0.transport == .displayPort }.count
            return "DP alt-mode, \(dpLanes) lane\(dpLanes > 1 ? "s" : "")"
        }

        if port.lane0.transport == .usb || port.lane1.transport == .usb {
            let usbLive = port.liveTransports.first { $0.kind == .usb }
            if let usb = usbLive, !usb.dataRate.isEmpty {
                return "USB3, \(usb.dataRate)"
            }
            let speed = port.usbSpeed?.label ?? "5 Gbps"
            return "USB3, \(speed)"
        }

        if port.usb2Active {
            return "USB2, 480 Mbps"
        }

        if port.ccConnected {
            if port.primaryProtocol == .charging {
                if fullyCharged { return "Battery full" }
                if isCharging { return "Charging" }
                return "Charger connected"
            }
            // CC tripped but no device, protocol, or power: a bare cable is in
            // the port (e.g. the far end was unplugged first). Saying so stops
            // this reading as a stale device connection.
            return "Cable connected"
        }

        return "Active"
    }

    private func formatLanes(tx: Int, rx: Int) -> String {
        if tx == rx {
            return tx > 1 ? "dual-lane" : "single-lane"
        }
        return "\(tx)TX/\(rx)RX"
    }

}
