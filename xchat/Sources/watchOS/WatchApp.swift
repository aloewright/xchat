// WatchApp.swift
// xchat – watchOS app entry point & simplified UI

import SwiftUI

@main
struct xchatWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchChatView()
        }
    }
}

// MARK: - WatchChatView

/// Simplified chat interface optimised for the watch canvas.
struct WatchChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var isComposing = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.messages.isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            .navigationTitle("xchat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isComposing = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $isComposing) {
                composeSheet
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Tap compose to start")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Message list (condensed)

    private var messageList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.messages.filter { $0.role != .system }) { msg in
                    VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 3) {
                        Text(msg.role == .user ? "You" : "xchat")
                            .font(.caption2.bold())
                            .foregroundStyle(msg.role == .user ? Color.accentColor : .secondary)

                        Text(msg.content.isEmpty && msg.isStreaming ? "…" : msg.content)
                            .font(.caption)
                            .lineLimit(6)

                        if !msg.toolCalls.isEmpty {
                            Text("🔧 \(msg.toolCalls.count) tool\(msg.toolCalls.count == 1 ? "" : "s") used")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(
                        msg.role == .user
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                    )
                    .id(msg.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Compose sheet

    private var composeSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Ask something…", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { sendAndDismiss() }

                HStack {
                    Button("Cancel", role: .cancel) {
                        viewModel.inputText = ""
                        isComposing = false
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("Send") { sendAndDismiss() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .navigationTitle("New Message")
        }
    }

    private func sendAndDismiss() {
        isComposing = false
        viewModel.sendMessage()
    }
}

// MARK: - Preview

#Preview("Watch Chat") {
    WatchChatView()
}
