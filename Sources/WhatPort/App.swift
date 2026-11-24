import AppKit

/// The app starts in AppKit, not SwiftUI's `App`. Every window WhatPort shows
/// (popover, Dock-mode window, About, Flight Recorder) is created by AppKit and
/// hosts its SwiftUI views itself, so a SwiftUI `App` would only add a required
/// but unused scene. Built with the macOS 27 SDK, that unused Settings scene
/// opened a blank window at every launch.
///
/// AppKit does not supply a main menu, so `MainMenu` builds one. Without its Edit
/// menu, Cmd-C/V/X/A stop working in text fields such as the licence key.
@main
enum WhatPortMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication holds its delegate weakly; keep it alive for the run.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.make(target: delegate)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
