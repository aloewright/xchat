// Message.swift
// xchat – Shared data models

import Foundation

// MARK: - Chat Message

/// A single message in a conversation thread.
public struct ChatMessage: Identifiable, Equatable, Codable {
    public let id: UUID
    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var isStreaming: Bool
    public var timestamp: Date

    public enum Role: String, Codable, Equatable {
        case user
        case assistant
        case system
        case tool
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCalls: [ToolCall] = [],
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

// MARK: - Tool Call

/// Represents a single tool invocation and its result.
public struct ToolCall: Identifiable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var arguments: [String: AnyCodable]
    public var result: AnyCodable?
    public var status: Status

    public enum Status: String, Codable, Equatable {
        case pending
        case running
        case completed
        case failed
    }

    public init(
        id: UUID = UUID(),
        name: String,
        arguments: [String: AnyCodable] = [:],
        result: AnyCodable? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.status = status
    }
}

// MARK: - AnyCodable helper

/// Type-erased Codable value for heterogeneous JSON.
public struct AnyCodable: Codable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self)   { value = v; return }
        if let v = try? container.decode(Int.self)    { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? container.decode([AnyCodable].self) { value = v; return }
        value = ()  // null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool:   try container.encode(v)
        case let v as Int:    try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Structural equality via JSON round-trip
        guard let l = try? JSONEncoder().encode(lhs),
              let r = try? JSONEncoder().encode(rhs)
        else { return false }
        return l == r
    }

    /// Best-effort description for display.
    public var displayString: String {
        if let v = value as? String { return v }
        if let data = try? JSONEncoder().encode(self),
           let str = String(data: data, encoding: .utf8) { return str }
        return String(describing: value)
    }
}

// MARK: - Wire types (matches Worker JSON contract)

/// Request sent to the /chat endpoint.
struct ChatRequest: Encodable {
    let messages: [WireMessage]
    let userId: String
    let toolkits: [String]?
    let rubeEnabled: Bool?

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }
}

/// SSE events emitted by the Worker.
enum ServerEvent {
    case token(String)
    case toolCall(name: String, arguments: [String: AnyCodable])
    case toolResult(name: String, result: AnyCodable)
    case warning(String)
    case done(String)
    case error(String)

    static func parse(event: String, data: String) -> ServerEvent? {
        struct TokenPayload:     Decodable { let content: String? }
        struct ToolCallPayload:  Decodable { let name: String; let arguments: [String: AnyCodable]? }
        struct ToolResultPayload:Decodable { let name: String; let result: AnyCodable? }
        struct MessagePayload:   Decodable { let message: String? }
        struct DonePayload:      Decodable { let content: String? }

        guard let raw = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        switch event {
        case "token":
            if let p = try? decoder.decode(TokenPayload.self, from: raw) {
                return .token(p.content ?? "")
            }
        case "tool_call":
            if let p = try? decoder.decode(ToolCallPayload.self, from: raw) {
                return .toolCall(name: p.name, arguments: p.arguments ?? [:])
            }
        case "tool_result":
            if let p = try? decoder.decode(ToolResultPayload.self, from: raw) {
                return .toolResult(name: p.name, result: p.result ?? AnyCodable(""))
            }
        case "warning":
            if let p = try? decoder.decode(MessagePayload.self, from: raw) {
                return .warning(p.message ?? "")
            }
        case "done":
            if let p = try? decoder.decode(DonePayload.self, from: raw) {
                return .done(p.content ?? "")
            }
        case "error":
            if let p = try? decoder.decode(MessagePayload.self, from: raw) {
                return .error(p.message ?? "Unknown error")
            }
        default:
            break
        }
        return nil
    }
}
