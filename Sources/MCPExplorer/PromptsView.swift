import SwiftUI
import MCPClient

struct PromptsView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        HSplitView {
            // Prompt list
            List(viewModel.prompts, id: \.name, selection: Binding(
                get: { viewModel.selectedPrompt?.name },
                set: { name in
                    if let prompt = viewModel.prompts.first(where: { $0.name == name }) {
                        viewModel.selectPrompt(prompt)
                    }
                }
            )) { prompt in
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.name)
                        .font(.body.monospaced())
                    if let desc = prompt.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let args = prompt.arguments, !args.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(args, id: \.name) { arg in
                                Text(arg.name)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(arg.required == true ? .orange.opacity(0.15) : .gray.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 250)

            // Detail
            VStack {
                if let prompt = viewModel.selectedPrompt {
                    promptDetail(prompt)
                } else {
                    ContentUnavailableView(
                        "Select a Prompt",
                        systemImage: "text.bubble",
                        description: Text("Choose a prompt to fill its arguments and expand it.")
                    )
                }
            }
            .frame(minWidth: 400)
        }
        .navigationTitle("Prompts")
    }

    @ViewBuilder
    private func promptDetail(_ prompt: MCPPrompt) -> some View {
        @Bindable var vm = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.name)
                        .font(.title2.monospaced().bold())
                    if let desc = prompt.description {
                        Text(desc)
                            .foregroundStyle(.secondary)
                    }
                }

                // Arguments
                if let args = prompt.arguments, !args.isEmpty {
                    GroupBox("Arguments") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(args, id: \.name) { arg in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(arg.name)
                                            .font(.body.monospaced().bold())
                                        if arg.required == true {
                                            Text("required")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    if let desc = arg.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    TextField(arg.name, text: Binding(
                                        get: { viewModel.promptArguments[arg.name] ?? "" },
                                        set: { viewModel.promptArguments[arg.name] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospaced())
                                }
                            }
                        }
                    }
                }

                // Expand button
                HStack {
                    Button(action: { Task { await viewModel.getPrompt() } }) {
                        if viewModel.promptGetInProgress {
                            ProgressView().controlSize(.small)
                            Text("Expanding...")
                        } else {
                            Label("Expand Prompt", systemImage: "play.fill")
                        }
                    }
                    .disabled(viewModel.promptGetInProgress)
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()
                }

                // Result
                if let result = viewModel.promptResult {
                    if let desc = result.description {
                        Text(desc).font(.callout).foregroundStyle(.secondary)
                    }

                    ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role.rawValue.uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(message.role == .user ? .blue : .green)

                                messageContent(message.content)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let error = viewModel.lastError {
                    GroupBox("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func messageContent(_ content: MCPContent) -> some View {
        switch content {
        case .text(let text, _):
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
        case .image(_, let mimeType, _):
            Text("Image: \(mimeType)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .resource(let contents, _):
            switch contents {
            case .text(let uri, _, let text):
                VStack(alignment: .leading, spacing: 2) {
                    Text(uri).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(text).font(.body.monospaced()).textSelection(.enabled)
                }
            case .blob(let uri, _, _):
                Text(uri).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
