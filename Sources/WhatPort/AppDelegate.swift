import AppKit
import Combine
import SwiftUI
import WhatPortCore
import WhatPortIOKit
import WhatPortAppKit
import WhatPortPlugins

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var footerContext: FooterContext?
    private let portManager = PortManager()
    private let dataSource = LivePortDataSource()
    private var dataTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var statusItemMoveObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard. If another instance of this bundle is already
        // running, this process is a redundant launch - most commonly the
        // keep-alive LaunchAgent's RunAtLoad firing the instant the user enables
        // "Launch at Login" while the app is already up, which would otherwise add
        // a second menu-bar item. Exit before building any UI (and before any
        // plugin bootstrap) so the original instance keeps its single status item.
        // A clean exit also means KeepAlive (SuccessfulExit=false) won't relaunch.
        //
        // Elect the lowest-PID instance as the sole survivor: only terminate
        // when an older (lower-PID) instance exists. This way two launches
        // racing at the same instant can't each see the other and both quit,
        // which would leave zero running. The eldest always stays.
        //
        // Skip the guard if we can't identify our own bundle (dev/ad-hoc builds
        // with no Info.plist): querying runningApplications(withBundleIdentifier:)
        // for an empty string would match unrelated ID-less processes and make
        // the app self-terminate on every launch.
        let me = NSRunningApplication.current
        if let bundleID = me.bundleIdentifier, !bundleID.isEmpty {
            let elder = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me.processIdentifier }
                .min { $0.processIdentifier < $1.processIdentifier }
            if let elder, elder.processIdentifier < me.processIdentifier {
                NSApp.terminate(nil)
                return
            }
        }

        if let iconURL = Bundle.whatPortResources.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }

        // The Settings shortcut (Cmd+,) is wired through SwiftUI's command
        // system (see WhatPortApp) and routed back here. Quit (Cmd+Q) is
        // SwiftUI's standard menu item. Listen for the Settings command.
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Move any existing login-item users onto the keep-alive agent so the
        // overnight-survival behaviour applies without them re-toggling.
        LaunchAtLogin.migrateFromMainAppIfNeeded()

        // Register Pro plugins (no-op in the OSS build)
        bootstrapPlugins(registry: .shared)

        // Run plugin launch hooks (licence bootstrap, StoreKit, etc.)
        let registry = PluginRegistry.shared
        Task {
            for hook in registry.launchHooks {
                await hook()
            }
        }

        // Run plugin portManager hooks (attach recorder, observers, etc.)
        for hook in registry.portManagerHooks {
            hook(portManager)
        }

        startDataPipeline()
        registerForWake()

        // Start polling GitHub releases for a newer version (a silent check now,
        // then every 6h). Surfaces an in-popover banner when one is available;
        // the right-click "Check for Updates…" item triggers a manual,
        // alert-backed check.
        UpdateChecker.shared.start()

        // Menu-bar vs window/Dock mode. The toggle in Settings writes
        // AppSettings.windowMode; we apply the current value now and live-switch
        // whenever it changes.
        applyDisplayMode(windowMode: AppSettings.shared.windowMode)

        AppSettings.shared.$windowMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windowMode in
                self?.applyDisplayMode(windowMode: windowMode)
            }
            .store(in: &cancellables)

        // The port-count badge only redraws on a port snapshot (once a second),
        // so redraw it on toggle too and the change lands immediately.
        AppSettings.shared.$showPortCount
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBadge()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        dataTask?.cancel()
        lifecycleTask?.cancel()
        dataSource.stop()

        // Run plugin teardown hooks
        for hook in PluginRegistry.shared.teardownHooks {
            hook()
        }
    }

    // In window mode, closing the last window quits like a normal app. In menu
    // bar mode there is no window, so this never fires. During a window -> menu
    // bar switch the setting is already false when the window closes, so the
    // teardown-close doesn't quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppSettings.shared.windowMode
    }

    // MARK: - Display mode

    private func applyDisplayMode(windowMode: Bool) {
        if windowMode {
            tearDownMenuBar()
            NSApp.setActivationPolicy(.regular)
            setUpWindow()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            tearDownWindow()
            // Set the policy before creating the status item: creating it while
            // still .regular can place it incorrectly on some macOS versions.
            NSApp.setActivationPolicy(.accessory)
            setUpMenuBar()
        }
    }

    // One FooterContext, shared by whichever surface (popover or window) is up.
    private func makeFooterContext() -> FooterContext {
        if let footerContext { return footerContext }
        let context = FooterContext(portManager: portManager)
        context.dismissPopover = { [weak self] in
            self?.popover?.performClose(nil)
        }
        footerContext = context
        return context
    }

    @ViewBuilder
    private func surfaceContent() -> some View {
        PortListView(portManager: portManager, footerContext: makeFooterContext())
    }

    // MARK: - Menu bar mode

    private func setUpMenuBar() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                // image(forResource:) pairs MenuBarIcon.png with its @2x rep;
                // loading the 1x file by URL shipped blurry on Retina.
                if let image = Bundle.whatPortResources.image(forResource: "MenuBarIcon") {
                    image.isTemplate = true  // lets macOS handle light/dark mode
                    image.size = NSSize(width: 18, height: 18)
                    button.image = image
                }
                button.imagePosition = .imageLeading
                button.action = #selector(statusItemClicked)
                button.target = self
                // Left-click toggles the popover; right-click (or control-click)
                // shows the context menu. Both routed through one action.
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = item
            observeStatusItemMoves(window: item.button?.window)
            updateBadge()
        }

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            // Initial size only; the hosting controller resizes the popover to
            // the SwiftUI content. Seed the width from the current font scale so
            // it opens at the right width instead of flashing 320 then widening.
            popover.contentSize = NSSize(
                width: PortListView.width(forScale: FontScaleStore.shared.fontSize),
                height: 560
            )
            popover.contentViewController = NSHostingController(rootView: surfaceContent())
            popover.delegate = self
            self.popover = popover
        }
    }

    private func tearDownMenuBar() {
        if let popover, popover.isShown { popover.performClose(nil) }
        popover = nil
        stopObservingStatusItemMoves()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Window mode

    private func setUpWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: surfaceContent())
        let window = NSWindow(contentViewController: hosting)
        window.title = "WhatPort"
        // Not .resizable: the content is a fixed-width (320pt) popover layout
        // that doesn't reflow, so a fixed-size window is intentional.
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Don't deallocate on close: applicationShouldTerminateAfterLastWindowClosed
        // decides whether closing quits the app.
        window.isReleasedWhenClosed = false
        window.center()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func tearDownWindow() {
        mainWindow?.delegate = nil
        mainWindow?.close()
        mainWindow = nil
    }

    // MARK: - Data pipeline

    private func startDataPipeline() {
        let stream = dataSource.observePortUpdates()
        let lifecycleStream = dataSource.observeLifecycleEvents()

        dataTask = Task {
            await dataSource.start()

            for await snapshot in stream {
                let managerSnapshot = SnapshotAdapter.convert(snapshot)
                portManager.applySnapshot(managerSnapshot)
                updateBadge()
            }
        }

        // Lifecycle events are a second, separate stream (see
        // observeLifecycleEvents' doc comment): near-instant attach /
        // negotiating / contractEstablished / transportReady signals, fed
        // straight into the state machine PortManager already owns. start()
        // is idempotent (guarded internally), so calling it again here is
        // safe regardless of which of the two tasks runs first.
        lifecycleTask = Task {
            await dataSource.start()

            for await event in lifecycleStream {
                portManager.applyLifecycleSignal(SnapshotAdapter.convert(event))
            }
        }
    }

    private func updateBadge() {
        // No-op in window mode (no status item).
        guard let button = statusItem?.button else { return }
        let active = portManager.activePortCount
        let total = portManager.portCount

        // VoiceOver reads the title, so with the count hidden the status item
        // would be an unlabelled image. Label it explicitly either way.
        button.setAccessibilityLabel(
            total > 0 ? "WhatPort, \(active) of \(total) ports active" : "WhatPort"
        )

        guard AppSettings.shared.showPortCount else {
            button.title = ""
            return
        }

        if total > 0 {
            button.title = " \(active)/\(total)"
        } else {
            button.title = ""
        }
    }

    // Changing the title resizes the status item, and macOS then re-lays-out the
    // menu bar, sliding the item to its final spot a fraction of a second later.
    // An open popover keeps the anchor it was shown with, so it ends up beside
    // the icon instead of under it. Re-point it whenever the item's window
    // actually moves: that covers the port count being hidden or shown (the
    // toggle lives in the popover), the count changing width ("9/10" to "10/10"),
    // and any neighbouring menu bar item shifting ours along.
    private func observeStatusItemMoves(window: NSWindow?) {
        guard let window else { return }
        stopObservingStatusItemMoves()
        statusItemMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorPopover() }
        }
    }

    private func stopObservingStatusItemMoves() {
        guard let statusItemMoveObserver else { return }
        NotificationCenter.default.removeObserver(statusItemMoveObserver)
        self.statusItemMoveObserver = nil
    }

    private func reanchorPopover() {
        guard let popover, popover.isShown, let button = statusItem?.button else { return }
        popover.positioningRect = button.bounds
    }

    private func registerForWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dataSource.handleWake()
        }
    }

    // Single action for the status item: route left-click to the popover and
    // right-click (or control-click) to the context menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showPopover() {
        guard let popover, let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Reset to the port list when the popover is dismissed, so a later plain
    // left-click always opens to the list, not whatever settings panel was last
    // shown. (showingSettings lives on the shared FooterContext now.)
    func popoverDidClose(_ notification: Notification) {
        footerContext?.showingSettings = false
    }

    // MARK: - Status item context menu (right-click)

    private func showContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        // Close the popover first so the menu doesn't overlap it. Immediate
        // (not animated) so it's gone before the menu pops.
        if let popover, popover.isShown { popover.close() }

        let menu = NSMenu()
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "WhatPort on GitHub", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About WhatPort", action: #selector(openAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WhatPort", action: #selector(quitApp), keyEquivalent: "q").target = self

        // Temporarily attach the menu so it pops from the status item, then
        // detach so a plain left-click still toggles the popover.
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        makeFooterContext().showingSettings = true
        showPopover()
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AboutView.gitHubURL)
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.check(silent: false)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.title = "About WhatPort"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
