import SwiftUI
import WhatPortCore

// Central registry for Pro plugin slots.
//
// The host app (WhatPort) reads from the registry. Plugin code
// (WhatPortPlugins) writes to it during bootstrapPlugins().
// In the public OSS build, bootstrapPlugins() is an empty function
// so all arrays stay empty and the app runs as free-tier.

@MainActor
public final class PluginRegistry {
    public static let shared = PluginRegistry()
    private init() {}

    // Async work to run at app launch (e.g. licence bootstrap, StoreKit load)
    public private(set) var launchHooks: [() async -> Void] = []
    public func register(launchHook: @escaping () async -> Void) {
        launchHooks.append(launchHook)
    }

    // Hooks that receive PortManager to attach recorders, observers, etc.
    public private(set) var portManagerHooks: [(PortManager) -> Void] = []
    public func register(portManagerHook: @escaping (PortManager) -> Void) {
        portManagerHooks.append(portManagerHook)
    }

    // Teardown hooks called when the app terminates
    public private(set) var teardownHooks: [() -> Void] = []
    public func register(teardownHook: @escaping () -> Void) {
        teardownHooks.append(teardownHook)
    }

    // Footer buttons rendered between Quit and gear in the popover
    public private(set) var footerButtonBuilders: [(FooterContext) -> AnyView] = []
    public func register(footerButton: @escaping (FooterContext) -> AnyView) {
        footerButtonBuilders.append(footerButton)
    }

    // Extra sections appended to the Settings view
    public private(set) var settingsSections: [() -> AnyView] = []
    public func register(settingsSection: @escaping () -> AnyView) {
        settingsSections.append(settingsSection)
    }

    // Full-screen panels that replace the port list (e.g. ProUpsellView)
    // Returns (view, isShowing binding name) pairs
    public private(set) var panelBuilders: [(_ dismiss: @escaping () -> Void) -> AnyView] = []
    public func register(panel: @escaping (_ dismiss: @escaping () -> Void) -> AnyView) {
        panelBuilders.append(panel)
    }

    // Per-port detail cards contributed by plugins, rendered below the host
    // app's own device card in PortDetailView. Returns nil when the plugin
    // has nothing to show for this port (e.g. locked, or not enough devices
    // to be worth a card); the caller decides what to do when every builder
    // returns nil, including any "+N more" fallback of its own.
    public private(set) var deviceTreeBuilders: [(PortState) -> AnyView?] = []
    public func register(deviceTreeBuilder: @escaping (PortState) -> AnyView?) {
        deviceTreeBuilders.append(deviceTreeBuilder)
    }

    // Extra rows appended inside PortDetailView's Power section. Same contract
    // as deviceTreeBuilders: the closure owns its own gating and returns nil
    // when it has nothing to show, so the host renders nothing rather than an
    // empty row.
    public private(set) var powerRowBuilders: [(PortState) -> AnyView?] = []
    public func register(powerRowBuilder: @escaping (PortState) -> AnyView?) {
        powerRowBuilders.append(powerRowBuilder)
    }
}
