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
        }
        .defaultSize(width: 1000, height: 700)
    }
}
