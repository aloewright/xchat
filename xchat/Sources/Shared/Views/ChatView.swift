// ChatView.swift
// xchat – Main chat interface (iOS & macOS)

import SwiftUI

// MARK: - ChatView

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                // ── Main chat interface ──────────────────────────────────────
                VStack(spacing: 0) {
                    messageList
                    Divider()
                    inputBar
                }
                .navigationTitle("xchat")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar { toolbarContent }
                .sheet(isPresented: $showSettings) {
                    SettingsView(viewModel: viewModel)
                }

                // ── Sign-in overlay ──────────────────────────────────────────
                // Covers the chat UI whenever the user is not authenticated.
                switch viewModel.authState {
                case .unauthenticated:
                    signInOverlay
                case .authenticating:
                    authProgressOverlay
                case .authenticated:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Sign-in overlay

    private var signInOverlay: some View {
        ZStack {
            Color(uiOrNSColorBackground)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                VStack(spacing: 10) {
                    Text("Welcome to xchat")
                        .font(.title2.bold())
                    Text("Sign in to start chatting with an AI assistant powered by Cloudflare Workers AI.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 320)

                Button {
                    viewModel.login()
                } label: {
                    Label("Sign in with Kinde", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let err = viewModel.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            }
            .padding(40)
        }
    }

    private var authProgressOverlay: some View {
        ZStack {
            Color(uiOrNSColorBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Signing in…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Cross-platform background color helper
#if os(macOS)
    private var uiOrNSColorBackground: NSColor { .windowBackgroundColor }
#else
    private var uiOrNSColorBackground: UIColor { .systemBackground }
#endif

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        welcomeCard
                            .id("welcome")
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.content) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Welcome card

    private var welcomeCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: true)

            VStack(spacing: 8) {
                Text("xchat")
                    .font(.title2.bold())
                Text("Powered by Cloudflare Workers AI & Composio tools.\nAsk anything — I can search HackerNews and more.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                suggestionChip("Top HN stories today")
                suggestionChip("Who is pg on HN?")
            }
        }
        .padding(32)
        .frame(maxWidth: 400)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            viewModel.inputText = text
            viewModel.sendMessage()
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message xchat…", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)
                .onSubmit {
                    // Shift+Return = new line, plain Return = send (macOS)
#if os(macOS)
                    viewModel.sendMessage()
#endif
                }
                .submitLabel(.send)
#if os(iOS)
                .onSubmit { viewModel.sendMessage() }
#endif

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isLoading {
            Button(action: viewModel.cancelStream) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: viewModel.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AnyShapeStyle(.tertiary)
                        : AnyShapeStyle(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                viewModel.clearConversation()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(viewModel.messages.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }

        // Sign Out — only shown when authenticated
        if case .authenticated = viewModel.authState {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.logout()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String? = nil
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Worker Endpoint") {
                    TextField("https://xchat-worker.…workers.dev", text: $viewModel.workerURL)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                }

                Section("Identity") {
                    TextField("User ID", text: $viewModel.userId)
                        .autocorrectionDisabled()
                }

                Section("Active Toolkits") {
                    ForEach(viewModel.availableToolkits, id: \.self) { kit in
                        Toggle(kit, isOn: Binding(
                            get: { viewModel.selectedToolkits.contains(kit) },
                            set: { on in
                                if on {
                                    viewModel.selectedToolkits.append(kit)
                                } else {
                                    viewModel.selectedToolkits.removeAll { $0 == kit }
                                }
                            }
                        ))
                    }
                    Text("Most toolkits beyond hackernews require OAuth setup via the Composio dashboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Rube MCP") {
                    Toggle("Enable Rube Tools", isOn: $viewModel.rubeEnabled)
                    Text("Loads additional tools from rube.app/mcp. The worker must have RUBE_ENABLED=true for this to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Connection") {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "network")
                            Spacer()
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isTesting)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("✓") ? Color.green : Color.red)
                    }
                }
            }
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.applyConfiguration()
                        dismiss()
                    }
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        viewModel.applyConfiguration()

        // Re-create service to pick up new config
        let service = ChatService(configuration: ChatConfiguration(
            baseURL: URL(string: viewModel.workerURL) ?? ChatConfiguration.default.baseURL,
            userId: viewModel.userId,
            toolkits: viewModel.selectedToolkits,
            rubeEnabled: viewModel.rubeEnabled
        ))
        let ok = await service.checkHealth()
        testResult = ok ? "✓ Worker is reachable" : "✗ Worker unreachable — check URL and deployment"
        isTesting = false
    }
}

// MARK: - Preview

#Preview("Chat") {
    ChatView()
}

#Preview("Settings") {
    SettingsView(viewModel: ChatViewModel())
}
