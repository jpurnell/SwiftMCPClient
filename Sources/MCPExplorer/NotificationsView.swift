import SwiftUI
import MCPClient

struct NotificationsView: View {
    @Environment(MCPViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Live Notifications")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.notifications.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    viewModel.notifications.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if viewModel.notifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Server notifications will appear here as they arrive.\nProgress updates, log messages, and list changes are shown in real time.")
                )
            } else {
                List(viewModel.notifications) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        notificationIcon(entry.notification)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                                .font(.body.monospaced())
                                .textSelection(.enabled)

                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Notifications")
    }

    @ViewBuilder
    private func notificationIcon(_ notification: MCPNotification) -> some View {
        switch notification {
        case .progress:
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.blue)
        case .logMessage(let msg):
            Image(systemName: logIcon(msg.level))
                .foregroundStyle(logColor(msg.level))
        case .toolsListChanged:
            Image(systemName: "wrench")
                .foregroundStyle(.orange)
        case .resourcesListChanged:
            Image(systemName: "doc")
                .foregroundStyle(.purple)
        case .resourceUpdated:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.purple)
        case .promptsListChanged:
            Image(systemName: "text.bubble")
                .foregroundStyle(.teal)
        }
    }

    private func logIcon(_ level: MCPLogLevel) -> String {
        switch level {
        case .debug, .info, .notice: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error, .critical, .alert, .emergency: return "xmark.circle.fill"
        }
    }

    private func logColor(_ level: MCPLogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info, .notice: return .blue
        case .warning: return .orange
        case .error, .critical, .alert, .emergency: return .red
        }
    }
}
