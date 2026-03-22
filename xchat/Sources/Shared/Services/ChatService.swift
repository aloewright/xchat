// ChatService.swift
// xchat – Network layer: SSE streaming from the Cloudflare Worker

import Foundation

// MARK: - Configuration

struct ChatConfiguration {
    /// Base URL of the deployed (or local) Cloudflare Worker.
    /// Override this in Settings or via an environment variable.
    var baseURL: URL

    /// Composio user ID passed to the Worker for tool auth.
    var userId: String

    /// Toolkits to activate. Defaults to hackernews (requires no OAuth).
    var toolkits: [String]

    /// Whether to send rubeEnabled=true in the chat request body.
    /// The worker must also have RUBE_ENABLED=true for Rube tools to load.
    var rubeEnabled: Bool

    static let `default` = ChatConfiguration(
        baseURL: URL(string: "https://xchat-worker.YOUR_SUBDOMAIN.workers.dev")!,
        userId: "default",
        toolkits: ["hackernews"],
        rubeEnabled: false
    )
}

// MARK: - ChatService

/// Streams chat responses from the xchat Cloudflare Worker as `ServerEvent` values.
actor ChatService {
    var configuration: ChatConfiguration

    init(configuration: ChatConfiguration = .default) {
        self.configuration = configuration
    }


    // MARK: Public API

    /// Returns an `AsyncThrowingStream` that yields `ServerEvent` values in real time.
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<ServerEvent, Error> {
        let url = configuration.baseURL.appendingPathComponent("chat")
        let userId = configuration.userId
        let toolkits = configuration.toolkits
        let rubeEnabled = configuration.rubeEnabled

        let wireMessages = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { ChatRequest.WireMessage(role: $0.role.rawValue, content: $0.content) }

        let body = ChatRequest(
            messages: wireMessages,
            userId: userId,
            toolkits: toolkits.isEmpty ? nil : toolkits,
            rubeEnabled: rubeEnabled ? true : nil
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)
                    // Disable response caching for SSE
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw ChatError.invalidResponse
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw ChatError.httpError(http.statusCode)
                    }

                    // Parse SSE line by line
                    var eventName = "message"
                    var dataBuffer = ""

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Blank line = dispatch event
                            if !dataBuffer.isEmpty {
                                if let evt = ServerEvent.parse(event: eventName, data: dataBuffer) {
                                    continuation.yield(evt)
                                    if case .done = evt { break }
                                    if case .error = evt { break }
                                }
                            }
                            eventName = "message"
                            dataBuffer = ""
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataBuffer = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        }
                        // Ignore comment lines starting with ':'
                    }

                    continuation.finish()
                } catch let error as ChatError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatError.network(error))
                }
            }
        }
    }

    // MARK: Health check

    func checkHealth() async -> Bool {
        let url = configuration.baseURL.appendingPathComponent("health")
        guard let (_, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}

// MARK: - Errors

enum ChatError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:   return "Invalid server response."
        case .httpError(let c):  return "HTTP \(c) from server."
        case .network(let e):    return "Network error: \(e.localizedDescription)"
        case .decoding(let e):   return "Decoding error: \(e.localizedDescription)"
        }
    }
}
