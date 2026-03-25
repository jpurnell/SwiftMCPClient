import SwiftUI
import MCPClient

struct ToolsView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        HSplitView {
            // Tool list
            List(viewModel.tools, id: \.name, selection: Binding(
                get: { viewModel.selectedTool?.name },
                set: { name in
                    viewModel.selectedTool = viewModel.tools.first { $0.name == name }
                    viewModel.toolResult = nil
                    // Pre-populate arguments from schema
                    if let tool = viewModel.selectedTool {
                        viewModel.toolArgumentsJSON = defaultArguments(for: tool)
                    }
                }
            )) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.body.monospaced())
                    if let desc = tool.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 250)

            // Detail
            VStack(alignment: .leading, spacing: 0) {
                if let tool = viewModel.selectedTool {
                    toolDetail(tool)
                } else {
                    ContentUnavailableView(
                        "Select a Tool",
                        systemImage: "wrench",
                        description: Text("Choose a tool from the list to inspect and call it.")
                    )
                }
            }
            .frame(minWidth: 400)
        }
        .navigationTitle("Tools")
    }

    @ViewBuilder
    private func toolDetail(_ tool: MCPTool) -> some View {
        @Bindable var vm = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name)
                        .font(.title2.monospaced().bold())
                    if let desc = tool.description {
                        Text(desc)
                            .foregroundStyle(.secondary)
                    }
                }

                // Input Schema
                if let schema = tool.inputSchema {
                    GroupBox("Input Schema") {
                        Text(prettyJSON(schema))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Arguments editor
                GroupBox("Arguments (JSON)") {
                    TextEditor(text: $vm.toolArgumentsJSON)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                }

                // Call button
                HStack {
                    Button(action: { Task { await viewModel.callTool() } }) {
                        if viewModel.toolCallInProgress {
                            ProgressView()
                                .controlSize(.small)
                            Text("Calling...")
                        } else {
                            Label("Call Tool", systemImage: "play.fill")
                        }
                    }
                    .disabled(viewModel.toolCallInProgress)
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()
                }

                // Result
                if let result = viewModel.toolResult {
                    GroupBox(result.isError == true ? "Error Result" : "Result") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(result.content.enumerated()), id: \.offset) { _, content in
                                contentBlock(content)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(result.isError == true ? .red : .clear, lineWidth: 1)
                    )
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
    private func contentBlock(_ content: MCPContent) -> some View {
        switch content {
        case .text(let text, let annotations):
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                if let ann = annotations {
                    annotationBadge(ann)
                }
            }
        case .image(let data, let mimeType, _):
            VStack(alignment: .leading, spacing: 4) {
                Text("Image: \(mimeType)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let imageData = Data(base64Encoded: data),
                   let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                } else {
                    Text("(base64, \(data.count) chars)")
                        .font(.caption.monospaced())
                }
            }
        case .resource(let contents, _):
            resourceContentsBlock(contents)
        }
    }

    @ViewBuilder
    private func resourceContentsBlock(_ contents: MCPResourceContents) -> some View {
        switch contents {
        case .text(let uri, _, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(uri).font(.caption).foregroundStyle(.secondary)
                Text(text).font(.body.monospaced()).textSelection(.enabled)
            }
        case .blob(let uri, _, let base64):
            VStack(alignment: .leading, spacing: 2) {
                Text(uri).font(.caption).foregroundStyle(.secondary)
                Text("Binary: \(base64.count) chars base64")
                    .font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private func annotationBadge(_ ann: MCPAnnotations) -> some View {
        HStack(spacing: 4) {
            if let audience = ann.audience {
                ForEach(audience, id: \.self) { role in
                    Text(role.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            if let priority = ann.priority {
                Text("priority: \(priority, specifier: "%.1f")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func defaultArguments(for tool: MCPTool) -> String {
        guard case .object(let schema) = tool.inputSchema,
              case .object(let props) = schema["properties"] else {
            return "{}"
        }
        var args: [String: AnyCodableValue] = [:]
        for (key, _) in props {
            args[key] = .string("")
        }
        guard let data = try? JSONEncoder().encode(args),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return prettyFormatJSON(json)
    }

    private func prettyJSON(_ value: AnyCodableValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return string
    }

    private func prettyFormatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return result
    }
}
