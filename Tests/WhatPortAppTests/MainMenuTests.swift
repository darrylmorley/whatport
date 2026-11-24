import AppKit
import Testing
@testable import WhatPort

// The app starts in AppKit, so nothing supplies a main menu unless MainMenu
// builds it. Without the Edit menu's key equivalents, Cmd-C/V/X/A do nothing in
// text fields such as the licence key; without the Settings item, Cmd-, does
// nothing. These hold every item, its shortcut, its action, its target and the
// menu it sits in.
//
// Whether the app installs this menu at launch can't be unit tested (main()
// runs the app loop).
@MainActor
@Suite(.serialized) struct MainMenuTests {
    private enum Target {
        // nil target: the responder chain (text field, window, then NSApp)
        case firstResponder
        case delegate
    }

    private struct Expected {
        let menu: String
        let title: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let action: Selector
        let target: Target
    }

    private static let command: NSEvent.ModifierFlags = .command

    private static let expected: [Expected] = [
        Expected(menu: "WhatPort", title: "About WhatPort", key: "", modifiers: command, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: .firstResponder),
        Expected(menu: "WhatPort", title: "Check for Updates\u{2026}", key: "", modifiers: command, action: #selector(AppDelegate.checkForUpdates), target: .delegate),
        Expected(menu: "WhatPort", title: "Settings\u{2026}", key: ",", modifiers: command, action: #selector(AppDelegate.openSettings), target: .delegate),
        Expected(menu: "WhatPort", title: "Hide WhatPort", key: "h", modifiers: command, action: #selector(NSApplication.hide(_:)), target: .firstResponder),
        Expected(menu: "WhatPort", title: "Hide Others", key: "h", modifiers: [.command, .option], action: #selector(NSApplication.hideOtherApplications(_:)), target: .firstResponder),
        Expected(menu: "WhatPort", title: "Show All", key: "", modifiers: command, action: #selector(NSApplication.unhideAllApplications(_:)), target: .firstResponder),
        Expected(menu: "WhatPort", title: "Quit WhatPort", key: "q", modifiers: command, action: #selector(NSApplication.terminate(_:)), target: .firstResponder),
        Expected(menu: "Edit", title: "Undo", key: "z", modifiers: command, action: Selector(("undo:")), target: .firstResponder),
        Expected(menu: "Edit", title: "Redo", key: "z", modifiers: [.command, .shift], action: Selector(("redo:")), target: .firstResponder),
        Expected(menu: "Edit", title: "Cut", key: "x", modifiers: command, action: #selector(NSText.cut(_:)), target: .firstResponder),
        Expected(menu: "Edit", title: "Copy", key: "c", modifiers: command, action: #selector(NSText.copy(_:)), target: .firstResponder),
        Expected(menu: "Edit", title: "Paste", key: "v", modifiers: command, action: #selector(NSText.paste(_:)), target: .firstResponder),
        Expected(menu: "Edit", title: "Delete", key: "", modifiers: command, action: #selector(NSText.delete(_:)), target: .firstResponder),
        Expected(menu: "Edit", title: "Select All", key: "a", modifiers: command, action: #selector(NSText.selectAll(_:)), target: .firstResponder),
        Expected(menu: "Window", title: "Close", key: "w", modifiers: command, action: #selector(NSWindow.performClose(_:)), target: .firstResponder),
        Expected(menu: "Window", title: "Minimize", key: "m", modifiers: command, action: #selector(NSWindow.performMiniaturize(_:)), target: .firstResponder),
        Expected(menu: "Window", title: "Zoom", key: "", modifiers: command, action: #selector(NSWindow.performZoom(_:)), target: .firstResponder),
        Expected(menu: "Window", title: "Bring All to Front", key: "", modifiers: command, action: #selector(NSApplication.arrangeInFront(_:)), target: .firstResponder),
    ]

    /// Builds the menu, runs `body`, then clears the app-wide menus that
    /// `MainMenu.make` registers so no state leaks into other tests.
    private func withMenu(_ body: (NSMenu, AppDelegate) throws -> Void) rethrows {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        defer {
            app.windowsMenu = nil
            app.helpMenu = nil
            app.servicesMenu = nil
        }
        try body(MainMenu.make(target: delegate), delegate)
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.submenu?.title == title }?.submenu
    }

    @Test func topLevelMenusAreInOrder() {
        withMenu { menu, _ in
            #expect(menu.items.compactMap { $0.submenu?.title } == ["WhatPort", "Edit", "Window", "Help"])
        }
    }

    @Test func everyItemHasItsShortcutActionAndTarget() throws {
        try withMenu { menu, delegate in
            for item in Self.expected {
                let parent = try #require(submenu(item.menu, in: menu), "no \(item.menu) menu")
                let matches = parent.items.filter { $0.title == item.title }
                #expect(matches.count == 1, "\(item.menu) > \(item.title): \(matches.count) items")
                let found = try #require(matches.first, "no \(item.menu) > \(item.title)")

                #expect(found.keyEquivalent == item.key, "\(item.title) shortcut")
                if !item.key.isEmpty {
                    #expect(found.keyEquivalentModifierMask == item.modifiers, "\(item.title) modifiers")
                }
                #expect(found.action == item.action, "\(item.title) action")
                switch item.target {
                case .firstResponder:
                    #expect(found.target == nil, "\(item.title) must go to the first responder")
                case .delegate:
                    #expect(found.target === delegate, "\(item.title) must target the app delegate")
                }
            }
        }
    }

    // A shortcut used twice fires only the first match, so the second silently
    // never runs.
    @Test func noShortcutIsUsedTwice() {
        withMenu { menu, _ in
            let shortcuts = menu.items
                .compactMap(\.submenu)
                .flatMap(\.items)
                .filter { !$0.keyEquivalent.isEmpty }
                .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
            #expect(Set(shortcuts).count == shortcuts.count, "duplicates in \(shortcuts.sorted())")
        }
    }

    @Test func systemMenusAreRegistered() {
        withMenu { menu, _ in
            let app = NSApplication.shared
            #expect(app.windowsMenu === submenu("Window", in: menu))
            #expect(app.helpMenu === submenu("Help", in: menu))
            #expect(app.servicesMenu != nil)
        }
    }
}
