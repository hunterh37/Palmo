import Foundation
import AppKit
import FoundationModels

/// One chat message, persisted across launches so the assistant "remembers".
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    let text: String
    let date: Date
}

/// Palmo's brain: Apple's on-device foundation model. 100% local, free,
/// offline — nothing ever leaves the Mac. Keeps a persistent transcript.
@MainActor
final class AssistantEngine: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isThinking = false
    @Published var errorText: String?

    private let historyKey = "assistantHistory"
    private let maxStored = 60
    private var session: LanguageModelSession?

    init() { load() }

    /// Whether the on-device model can run right now.
    var modelStatus: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings so we can chat."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading — try again in a bit."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }

    private var instructions: String {
        """
        You are \(Brand.name), a cute, warm, delightful little assistant who \
        lives on the user's Mac. You are hand-shaped and love hand puns (use \
        them sparingly — at most one per reply). You are genuinely helpful, \
        concise, and cheerful. Keep replies short and conversational: a few \
        sentences unless the user asks for detail. The app you live in lets \
        the user control their Mac with hand gestures: pinch to click, fist \
        to scroll, open palm to summon an app menu, peace sign for a \
        screenshot, thumbs-up for play/pause. You run entirely on-device — \
        the user's data never leaves this Mac. Frontmost app right now: \
        \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown").
        """
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: trimmed, date: .now))
        save()
        errorText = nil
        isThinking = true
        Task { await complete(prompt: trimmed) }
    }

    /// One-tap: summarize whatever is on the clipboard, locally.
    func summarizeClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "There's no text on your clipboard."
            return
        }
        let snippet = String(clip.prefix(6000))
        send("Summarize this from my clipboard in a few bullet-free sentences:\n\n\(snippet)")
    }

    func clearHistory() {
        messages = []
        session = nil
        save()
    }

    private func complete(prompt: String) async {
        defer { isThinking = false }
        if let status = modelStatus {
            errorText = status
            return
        }
        do {
            if session == nil {
                session = LanguageModelSession(instructions: instructions)
            }
            guard let session else { return }
            let response = try await session.respond(to: prompt)
            let reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else {
                errorText = "I came up empty — try asking another way?"
                return
            }
            messages.append(ChatMessage(role: .assistant, text: reply, date: .now))
            save()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // Start fresh but keep the visible history.
                session = nil
                errorText = "That chat got long — I tidied my memory. Ask again!"
            case .guardrailViolation:
                errorText = "I can't help with that one."
            default:
                errorText = "The on-device model hiccuped: \(error.localizedDescription)"
            }
        } catch {
            errorText = "Something went wrong: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return }
        messages = decoded
    }

    private func save() {
        let tail = Array(messages.suffix(maxStored))
        if let data = try? JSONEncoder().encode(tail) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
