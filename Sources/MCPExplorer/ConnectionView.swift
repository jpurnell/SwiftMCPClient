import SwiftUI
import MCPClient

struct ConnectionView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        Form {
            Section("Transport") {
                Picker("Type", selection: $vm.transportType) {
                    ForEach(TransportType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                switch viewModel.transportType {
                case .httpSSE, .webSocket:
                    TextField("Server URL", text: $vm.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    #if os(macOS)
                        .textContentType(.URL)
                    #endif

                    if viewModel.transportType == .httpSSE {
                        Text("Example: https://mcp.example.com/sse")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Bearer Token (optional)", text: $vm.bearerToken)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()

                        Toggle("Trust self-signed certificates", isOn: $vm.trustSelfSignedCertificates)
                            .font(.callout)
                    } else {
                        Text("Example: wss://mcp.example.com/ws")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .stdio:
                    TextField("Command", text: $vm.stdioCommand)
                        .textFieldStyle(.roundedBorder)
                    TextField("Arguments (space-separated)", text: $vm.stdioArguments)
                        .textFieldStyle(.roundedBorder)
                    Text("Example: /usr/local/bin/my-mcp-server --port 3000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                statusRow
            }

            Section {
                HStack {
                    if viewModel.connectionState.isConnected {
                        Button("Disconnect", role: .destructive) {
                            Task { await viewModel.disconnect() }
                        }

                        Button("Ping") {
                            Task {
                                let ok = await viewModel.ping()
                                if ok {
                                    viewModel.lastError = nil
                                }
                            }
                        }

                        Button("Refresh") {
                            Task { await viewModel.discover() }
                        }
                    } else {
                        Button("Connect") {
                            Task { await viewModel.connect() }
                        }
                        .disabled(isConnectDisabled)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }

            if let caps = viewModel.serverCapabilities {
                Section("Server Capabilities") {
                    capabilityRow("Tools", available: caps.tools != nil,
                                  detail: caps.tools?.listChanged == true ? "listChanged" : nil)
                    capabilityRow("Resources", available: caps.resources != nil,
                                  detail: caps.resources?.subscribe == true ? "subscribe" : nil)
                    capabilityRow("Prompts", available: caps.prompts != nil,
                                  detail: caps.prompts?.listChanged == true ? "listChanged" : nil)
                    capabilityRow("Logging", available: caps.logging != nil, detail: nil)
                }
            }

            if let error = viewModel.lastError {
                Section("Last Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }

    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.connectionState {
        case .disconnected:
            Label("Disconnected", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .connected(let server, let version):
            Label("\(server) v\(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func capabilityRow(_ name: String, available: Bool, detail: String?) -> some View {
        HStack {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
            Text(name)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isConnectDisabled: Bool {
        switch viewModel.transportType {
        case .httpSSE, .webSocket:
            return viewModel.serverURL.isEmpty
        case .stdio:
            return viewModel.stdioCommand.isEmpty
        }
    }
}
