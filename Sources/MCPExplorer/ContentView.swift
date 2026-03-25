import SwiftUI

struct ContentView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("MCP Explorer")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                connectionStatusBadge
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List {
            Section("Connection") {
                NavigationLink(value: Tab.connection) {
                    Label("Server", systemImage: "network")
                }
            }

            if viewModel.connectionState.isConnected {
                Section("Discover") {
                    NavigationLink(value: Tab.tools) {
                        Label("Tools (\(viewModel.tools.count))", systemImage: "wrench")
                    }
                    NavigationLink(value: Tab.resources) {
                        Label("Resources (\(viewModel.resources.count))", systemImage: "doc")
                    }
                    NavigationLink(value: Tab.prompts) {
                        Label("Prompts (\(viewModel.prompts.count))", systemImage: "text.bubble")
                    }
                }

                Section("Monitor") {
                    NavigationLink(value: Tab.notifications) {
                        Label("Notifications (\(viewModel.notifications.count))", systemImage: "bell")
                    }
                }
            }
        }
        .navigationDestination(for: Tab.self) { tab in
            switch tab {
            case .connection: ConnectionView()
            case .tools: ToolsView()
            case .resources: ResourcesView()
            case .prompts: PromptsView()
            case .notifications: NotificationsView()
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        ConnectionView()
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch viewModel.connectionState {
        case .disconnected:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected(let server, _):
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text(server)
                    .font(.caption)
            }
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    enum Tab: Hashable {
        case connection
        case tools
        case resources
        case prompts
        case notifications
    }
}
