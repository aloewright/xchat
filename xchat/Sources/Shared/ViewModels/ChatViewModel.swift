// ChatViewModel.swift
// xchat – Observable state for the chat UI

import Foundation
import Observation

// MARK: - ChatViewModel

@MainActor
@Observable
final class ChatViewModel {

    // ── Published state ───────────────────────────────────────────────────────
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var workerURL: String = ChatConfiguration.default.baseURL.absoluteString
    var userId: String = ChatConfiguration.default.userId
    var selectedToolkits: [String] = ChatConfiguration.default.toolkits
    var rubeEnabled: Bool = ChatConfiguration.default.rubeEnabled

    /// Mirrors `AuthService.shared.state`; updated by `syncAuthState()`.
    var authState: AuthState = .unauthenticated

    // ── Available toolkits (shown in settings) ────────────────────────────────
    let availableToolkits = [
        "hackernews", "gmail", "googlecalendar", "github",
        "slack", "notion", "linear", "jira", "figma"
    ]

    // ── Private state ─────────────────────────────────────────────────────────
    private var chatService: ChatService
    private var streamTask: Task<Void, Never>?

    // MARK: Init

    init() {
        self.chatService = ChatService()
        // Restore auth state from Keychain (AuthService reads it during init).
        Task { await syncAuthState() }
    }

    // MARK: Auth actions

    /// Initiates the Kinde PKCE sign-in flow.
    func login() {
        Task {
            authState = .authenticating
            do {
                try await AuthService.shared.login()
            } catch {
                errorMessage = error.localizedDescription
            }
            await syncAuthState()
        }
    }

    /// Signs the user out and clears the Keychain token.
    func logout() {
        Task {
            await AuthService.shared.logout()
            await syncAuthState()
            clearConversation()
        }
    }

    // MARK: Public chat actions

    /// Send the current `inputText` as a user message.
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        inputText = ""
        errorMessage = nil

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)

        startStream()
    }

    /// Cancel the in-flight streaming request.
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil

        // Mark any streaming message as done
        if let idx = messages.indices.last(where: { messages[$0].isStreaming }) {
            messages[idx].isStreaming = false
        }
        isLoading = false
    }

    /// Clear the conversation.
    func clearConversation() {
        cancelStream()
        messages.removeAll()
    }

    /// Apply updated worker URL and rebuild the service.
    func applyConfiguration() {
        guard let url = URL(string: workerURL), !workerURL.isEmpty else {
            errorMessage = "Invalid worker URL."
            return
        }
        let config = ChatConfiguration(
            baseURL: url,
            userId: userId.isEmpty ? "default" : userId,
            toolkits: selectedToolkits,
            rubeEnabled: rubeEnabled
        )
        Task {
            await chatService.setConfiguration(config)
        }
    }

    // MARK: Private

    /// Pulls the latest auth state from the AuthService actor.
    private func syncAuthState() async {
        authState = await AuthService.shared.state
    }

    private func startStream() {
        // Block streaming when the user is not signed in.
        guard case .authenticated = authState else {
            errorMessage = "Please sign in to start chatting."
            // Remove the placeholder user message we just added
            if messages.last?.role == .user {
                messages.removeLast()
            }
            isLoading = false
            return
        }

        isLoading = true

        // Add placeholder assistant message for streaming
        let assistantPlaceholder = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        messages.append(assistantPlaceholder)
        let assistantIndex = messages.count - 1

        streamTask = Task {
            // Build the configuration for this run
            let config = ChatConfiguration(
                baseURL: URL(string: workerURL) ?? ChatConfiguration.default.baseURL,
                userId: userId.isEmpty ? "default" : userId,
                toolkits: selectedToolkits,
                rubeEnabled: rubeEnabled
            )
            await chatService.setConfiguration(config)

            // Open the stream
            let stream = await chatService.stream(messages: Array(messages.dropLast()))

            do {
                for try await event in stream {
                    if Task.isCancelled { break }

                    switch event {
                    case .token(let chunk):
                        messages[assistantIndex].content += chunk

                    case .toolCall(let name, let args):
                        let tc = ToolCall(
                            name: name,
                            arguments: args,
                            status: .running
                        )
                        messages[assistantIndex].toolCalls.append(tc)

                    case .toolResult(let name, let result):
                        if let idx = messages[assistantIndex].toolCalls.firstIndex(
                            where: { $0.name == name && $0.status == .running }
                        ) {
                            messages[assistantIndex].toolCalls[idx].result = result
                            messages[assistantIndex].toolCalls[idx].status = .completed
                        }

                    case .warning(let msg):
                        // Surface warnings as a transient inline message
                        let warn = ChatMessage(
                            role: .system,
                            content: "⚠️ \(msg)"
                        )
                        messages.insert(warn, at: assistantIndex)

                    case .done:
                        break   // stream finished cleanly

                    case .error(let msg):
                        messages[assistantIndex].content = "Error: \(msg)"
                    }
                }
            } catch {
                if !Task.isCancelled {
                    messages[assistantIndex].content = "Connection error: \(error.localizedDescription)"
                }
            }

            // Finalise
            if !Task.isCancelled {
                messages[assistantIndex].isStreaming = false
            }
            isLoading = false
        }
    }
}

// MARK: - ChatService actor extension for runtime config updates

extension ChatService {
    func setConfiguration(_ config: ChatConfiguration) {
        self.configuration = config
    }
}
