import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct MCPExplorerApp: App {
    @State private var viewModel = MCPViewModel()

    init() {
        #if os(macOS)
        // SwiftPM executables don't have an app bundle, so macOS won't
        // show a Dock icon or bring the window to front by default.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
