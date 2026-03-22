// MessageBubble.swift
// xchat – Individual message bubble component (iOS & macOS)

import SwiftUI

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Tool calls (shown above the text content)
            if !message.toolCalls.isEmpty {
                ForEach(message.toolCalls) { tc in
                    ToolCallCard(toolCall: tc)
                }
            }

            // Main bubble
            if message.role == .system {
                systemBubble
            } else {
                chatBubble
            }

            // Timestamp
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: Subviews

    private var chatBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 0) {
                textContent
                if message.isStreaming {
                    typingIndicator
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .foregroundStyle(foregroundColor)
            .clipShape(BubbleShape(isUser: message.role == .user))

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var systemBubble: some View {
        Text(message.content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .frame(maxWidth: .infinity)
    }

    private var textContent: some View {
        Text(message.content.isEmpty && message.isStreaming ? " " : message.content)
            .font(.body)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var typingIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(0.6)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(i) * 0.2),
                        value: message.isStreaming
                    )
            }
        }
        .padding(.top, 4)
    }

    // MARK: Styling helpers

    private var bubbleBackground: AnyShapeStyle {
        if message.role == .user {
            AnyShapeStyle(Color.accentColor)
        } else {
#if os(macOS)
            AnyShapeStyle(
                Color(NSColor.controlBackgroundColor)
                    .shadow(.drop(color: .black.opacity(0.06), radius: 3, y: 2))
            )
#elseif os(watchOS)
            AnyShapeStyle(Color(white: 0.18))
#else
            AnyShapeStyle(
                Color(UIColor.systemBackground)
                    .shadow(.drop(color: .black.opacity(0.06), radius: 3, y: 2))
            )
#endif
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - BubbleShape

struct BubbleShape: Shape {
    let isUser: Bool
    private let radius: CGFloat = 18
    private let tailRadius: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)

        let tlR = isUser ? radius : tailRadius
        let trR = isUser ? tailRadius : radius
        let brR = radius
        let blR = radius

        path.move(to: CGPoint(x: tl.x + tlR, y: tl.y))
        path.addLine(to: CGPoint(x: tr.x - trR, y: tr.y))
        path.addQuadCurve(to: CGPoint(x: tr.x, y: tr.y + trR), control: tr)
        path.addLine(to: CGPoint(x: br.x, y: br.y - brR))
        path.addQuadCurve(to: CGPoint(x: br.x - brR, y: br.y), control: br)
        path.addLine(to: CGPoint(x: bl.x + blR, y: bl.y))
        path.addQuadCurve(to: CGPoint(x: bl.x, y: bl.y - blR), control: bl)
        path.addLine(to: CGPoint(x: tl.x, y: tl.y + tlR))
        path.addQuadCurve(to: CGPoint(x: tl.x + tlR, y: tl.y), control: tl)
        path.closeSubpath()
        return path
    }
}

// MARK: - ToolCallCard

struct ToolCallCard: View {
    let toolCall: ToolCall

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 20, height: 20)

                    Text(toolCall.name)
                        .font(.caption.monospaced())
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Arguments
                if !toolCall.arguments.isEmpty {
                    Label("Arguments", systemImage: "arrow.up.circle")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)

                    scrollableCode(
                        toolCall.arguments
                            .sorted(by: { $0.key < $1.key })
                            .map { "  \($0.key): \($0.value.displayString)" }
                            .joined(separator: "\n")
                    )
                }

                // Result
                if let result = toolCall.result {
                    Label("Result", systemImage: "arrow.down.circle")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)

                    scrollableCode(result.displayString)
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.4), lineWidth: 1)
        )
        .frame(maxWidth: 320, alignment: .leading)
    }

    @ViewBuilder
    private func scrollableCode(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .frame(maxHeight: 80)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .pending:  return .gray
        case .running:  return .blue
        case .completed: return .green
        case .failed:   return .red
        }
    }
}

// MARK: - Preview

#Preview("User bubble") {
    VStack {
        MessageBubble(message: ChatMessage(role: .user, content: "Hello! What's trending on Hacker News today?"))
        MessageBubble(message: ChatMessage(
            role: .assistant,
            content: "Let me check that for you.",
            toolCalls: [
                ToolCall(
                    name: "HACKERNEWS_GET_STORIES",
                    arguments: ["type": AnyCodable("top"), "count": AnyCodable(5)],
                    result: AnyCodable("[{\"title\": \"Swift 6 is out\", \"score\": 450}]"),
                    status: .completed
                )
            ]
        ))
    }
    .padding()
}
