import SwiftUI
import MCPClient

struct ResourcesView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        HSplitView {
            // Resource list
            List(selection: Binding(
                get: { viewModel.selectedResource?.uri },
                set: { uri in
                    viewModel.selectedResource = viewModel.resources.first { $0.uri == uri }
                    viewModel.resourceContents = []
                }
            )) {
                if !viewModel.resources.isEmpty {
                    Section("Resources") {
                        ForEach(viewModel.resources, id: \.uri) { resource in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resource.name)
                                    .font(.body)
                                Text(resource.uri)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let desc = resource.description {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(resource.uri)
                        }
                    }
                }

                if !viewModel.resourceTemplates.isEmpty {
                    Section("Templates") {
                        ForEach(viewModel.resourceTemplates, id: \.uriTemplate) { template in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.body)
                                Text(template.uriTemplate)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let desc = template.description {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(minWidth: 250)

            // Detail
            VStack {
                if let resource = viewModel.selectedResource {
                    resourceDetail(resource)
                } else {
                    ContentUnavailableView(
                        "Select a Resource",
                        systemImage: "doc",
                        description: Text("Choose a resource to read its contents.")
                    )
                }
            }
            .frame(minWidth: 400)
        }
        .navigationTitle("Resources")
    }

    @ViewBuilder
    private func resourceDetail(_ resource: MCPResource) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(resource.name)
                        .font(.title2.bold())
                    Text(resource.uri)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let desc = resource.description {
                        Text(desc)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let mime = resource.mimeType {
                            Label(mime, systemImage: "doc.text")
                                .font(.caption)
                        }
                        if let size = resource.size {
                            Label(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                                  systemImage: "internaldrive")
                                .font(.caption)
                        }
                    }
                }

                // Read button
                HStack {
                    Button(action: { Task { await viewModel.readResource() } }) {
                        if viewModel.resourceReadInProgress {
                            ProgressView().controlSize(.small)
                            Text("Reading...")
                        } else {
                            Label("Read Resource", systemImage: "arrow.down.doc")
                        }
                    }
                    .disabled(viewModel.resourceReadInProgress)
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()
                }

                // Contents
                ForEach(Array(viewModel.resourceContents.enumerated()), id: \.offset) { _, contents in
                    GroupBox {
                        switch contents {
                        case .text(let uri, let mimeType, let text):
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(uri).font(.caption.monospaced())
                                    if let mime = mimeType {
                                        Text(mime).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(text)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        case .blob(let uri, let mimeType, let base64):
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(uri).font(.caption.monospaced())
                                    if let mime = mimeType {
                                        Text(mime).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text("Binary data: \(base64.count) chars base64")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
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
}
