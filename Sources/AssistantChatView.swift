import SwiftUI

/// The assistant chat window: Palmo's face up top, persistent conversation
/// below, composer at the bottom.
struct AssistantChatView: View {
    @ObservedObject var assistant: AssistantEngine
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            messageList
            Divider().opacity(0.4)
            composer
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 480, idealHeight: 620)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BuddyView(mood: assistant.isThinking ? .thinking : .idle)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.name.uppercased())
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(Brand.gradient)
                Text(assistant.isThinking ? "Thinking..." : "On-device • Private • Free")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                assistant.summarizeClipboard()
            } label: {
                Label("Summarize clipboard", systemImage: "doc.on.clipboard")
            }
            .controlSize(.small)
            .disabled(assistant.isThinking)
            if !assistant.messages.isEmpty {
                Button("Clear") { assistant.clearHistory() }
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if assistant.messages.isEmpty {
                        emptyState.padding(.top, 60)
                    }
                    ForEach(assistant.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                    if assistant.isThinking {
                        HStack {
                            ThinkingDots()
                                .padding(10)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .colorInvert()
                            Spacer()
                        }
                    }
                    if let err = assistant.errorText {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }
                }
                .padding(12)
            }
            .onChange(of: assistant.messages) { _, _ in
                if let last = assistant.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            BuddyView(mood: .happy).frame(width: 80, height: 80)
            Text("Hi! I'm \(Brand.name).")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text(assistant.modelStatus
                 ?? "Ask me anything — I run right here on your Mac, totally private.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 50) }
            Text(msg.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    msg.role == .user
                        ? AnyShapeStyle(Brand.gradient)
                        : AnyShapeStyle(Color.primary.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(msg.role == .user ? .white : .primary)
            if msg.role == .assistant { Spacer(minLength: 50) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message \(Brand.name)...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.tertiary)
                                                   : AnyShapeStyle(Brand.gradient))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isThinking)
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        assistant.send(text)
        focused = true
    }
}
