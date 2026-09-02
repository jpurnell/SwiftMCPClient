import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct MCPExplorerApp: App {
    @State private var viewModel = MCPViewModel()

    init() {
        #if os(macOS)
        // A bare SwiftPM executable has no bundle, so macOS gives it no Dock icon and leaves
        // its window behind whatever was in front. Both are worth correcting when running
        // from `.build`, and neither is when running from `MCPExplorer.app` — a bundled app
        // that seizes focus on every launch is one that interrupts whatever you were doing,
        // and the bundle already supplies the Dock icon.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                // A session that survived the restart is restored before the user touches
                // anything. Silent when there is nothing to restore, which is most launches.
                .task { await viewModel.restoreRememberedSession() }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Discovery") {
                    Task { await viewModel.discover() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!viewModel.connectionState.isConnected)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
