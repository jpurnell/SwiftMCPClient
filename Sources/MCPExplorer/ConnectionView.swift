import SwiftUI
import MCPClient

struct ConnectionView: View {
    @Environment(MCPViewModel.self) private var viewModel

    /// Whether the user has asked for state to be shown without relying on colour.
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

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
                case .httpSSE, .streamableHTTP, .webSocket:
                    TextField("Server URL", text: $vm.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif

                    if viewModel.transportType.usesHTTPCredentials {
                        Text("Example: \(viewModel.transportType.exampleURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        oauthRow

                        TextField("Bearer Token (optional)", text: $vm.bearerToken)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .disabled(viewModel.oauthState == .signedIn)
                            .help(viewModel.oauthState == .signedIn
                                  ? "Signed in with OAuth; the token is managed for you."
                                  : "Used only if you are not signed in with OAuth.")

                        Toggle("Trust self-signed certificates", isOn: $vm.trustSelfSignedCertificates)
                            .font(.callout)
                    } else {
                        Text("Example: \(viewModel.transportType.exampleURL)")
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

    /// Sign in, or say why it did not work.
    ///
    /// The failure text is specific on purpose: "this server does not advertise OAuth",
    /// "this server does not allow clients to register themselves" and "the server pointed
    /// sign-in at another host" have different remedies, and a single "sign-in failed" would
    /// hide which one applies.
    @ViewBuilder
    private var oauthRow: some View {
        HStack(spacing: 8) {
            switch viewModel.oauthState {
            case .signedOut, .failed:
                Button("Sign in with OAuth…") {
                    Task { await viewModel.signInWithOAuth() }
                }
                .disabled(viewModel.serverURL.isEmpty)

            case .awaitingBrowser:
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .signedIn:
                Label(viewModel.credentialsPersist ? "Signed in" : "Signed in (this session only)",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .help(viewModel.credentialsPersist
                          ? "The credential is stored, encrypted, and refreshed as needed."
                          : "Credential storage is unavailable, so this sign-in ends when the app quits.")
                Spacer()
                Button("Sign out") {
                    Task { await viewModel.signOutOfOAuth() }
                }
                .controlSize(.small)
            }
        }

        if case .failed(let reason) = viewModel.oauthState {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capabilityRow(_ name: String, available: Bool, detail: String?) -> some View {
        HStack {
            // The symbol already differs, so availability is never carried by colour alone.
            // When the user has asked to differentiate without colour, the tint is dropped
            // entirely rather than merely supplemented — green reads as meaningful whether
            // or not it is the only signal.
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .accessibilityLabel(available ? "\(name) available" : "\(name) unavailable")
                .foregroundStyle(differentiateWithoutColor
                                 ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(available ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)))
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
        case .httpSSE, .streamableHTTP, .webSocket:
            return viewModel.serverURL.isEmpty
        case .stdio:
            return viewModel.stdioCommand.isEmpty
        }
    }
}
