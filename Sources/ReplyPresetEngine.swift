import Foundation
import FoundationModels

// MARK: - Model

/// A candidate reply generated on-device for a Claude session.
struct ReplyPreset: Identifiable, Equatable {
    enum Tier: Equatable {
        /// Fast, terse first wave.
        case quick
        /// Slower, more considered second wave.
        case considered
    }
    let id = UUID()
    var text: String
    var tier: Tier
}

/// Everything the on-device model needs to draft replies for a session.
struct ComposeContext {
    var sessionName: String
    var cwd: String
    /// Claude's most recent assistant message (from the hook).
    var lastMessage: String
    /// Truncated `git diff` for the session's working directory (may be empty).
    var diff: String
}

// MARK: - Engine

/// Drafts up to four short replies to a Claude session, entirely on-device via
/// Apple's foundation model. Runs in progressive rounds: a fast wave of two
/// terse options appears first, then a second wave of more considered options
/// the longer the user lingers. Nothing ever leaves the Mac.
@MainActor
final class ReplyPresetEngine: ObservableObject {
    @Published private(set) var presets: [ReplyPreset] = []
    @Published private(set) var isGenerating = false

    private var task: Task<Void, Never>?
    private let quickCount = 2
    private let consideredCount = 2

    /// Begin drafting for a session. Cancels any in-flight generation first.
    func start(context: ComposeContext) {
        cancel()
        presets = []
        isGenerating = true
        task = Task { [weak self] in await self?.run(context) }
    }

    /// Stop generating and clear state (e.g. compose was dismissed).
    func cancel() {
        task?.cancel()
        task = nil
        isGenerating = false
        if !presets.isEmpty { presets = [] }
    }

    /// Whether the on-device model can run right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: Generation

    @Generable
    struct ReplyBatch {
        @Guide(description: "Distinct, ready-to-send replies the developer could send back to Claude. Each is a complete message on its own, no numbering or preamble.")
        var replies: [String]
    }

    private func run(_ ctx: ComposeContext) async {
        defer { isGenerating = false }
        guard Self.isAvailable else { return }

        let session = LanguageModelSession(instructions: Self.instructions)

        // Round 1 — quick, terse.
        await generateRound(
            session: session, ctx: ctx, tier: .quick, count: quickCount,
            style: "Keep each reply very short and punchy — a quick decision or nudge, ideally under about 10 words (e.g. \"Yes, go ahead\", \"Run the tests first\", \"Use the second approach\").")
        if Task.isCancelled { return }

        // Round 2 — more considered (only if still composing).
        await generateRound(
            session: session, ctx: ctx, tier: .considered, count: consideredCount,
            style: "Make each reply more considered: one or two sentences that add a specific instruction, constraint, or follow-up question. These should feel more thoughtful than a quick yes/no.")
    }

    private func generateRound(session: LanguageModelSession, ctx: ComposeContext,
                               tier: ReplyPreset.Tier, count: Int, style: String) async {
        let existing = presets.map(\.text)
        let prompt = Self.prompt(ctx: ctx, count: count, style: style, avoid: existing)
        do {
            let response = try await session.respond(to: prompt, generating: ReplyBatch.self)
            if Task.isCancelled { return }
            let fresh = response.content.replies
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(count)
            for text in fresh where !presets.contains(where: { $0.text == text }) {
                presets.append(ReplyPreset(text: text, tier: tier))
            }
        } catch {
            // A failed round just yields fewer options — the user can still
            // pick from whatever landed, or dismiss.
        }
    }

    // MARK: Prompting

    private static let instructions = """
    You help a developer reply to Claude Code, an AI coding assistant running \
    in their terminal. Given Claude's latest message and the current code diff, \
    you draft short candidate replies the developer might send back. Write in \
    the developer's voice — direct, practical, first person. Never explain \
    yourself or add commentary; produce only the replies.
    """

    private static func prompt(ctx: ComposeContext, count: Int, style: String,
                               avoid: [String]) -> String {
        var parts: [String] = []
        parts.append("Project: \(ctx.sessionName) (\(ctx.cwd))")
        if !ctx.lastMessage.isEmpty {
            parts.append("Claude just said:\n\"\"\"\n\(ctx.lastMessage.prefix(3000))\n\"\"\"")
        }
        if !ctx.diff.isEmpty {
            parts.append("Current git diff (truncated):\n```\n\(ctx.diff.prefix(3000))\n```")
        }
        if !avoid.isEmpty {
            parts.append("Do NOT repeat or lightly reword these already-offered replies:\n- "
                         + avoid.joined(separator: "\n- "))
        }
        parts.append("Draft \(count) distinct replies the developer could send back now. \(style)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Context helpers

    /// Best-effort `git diff` for a working directory. Returns "" if not a git
    /// repo or on any failure. Runs off the main actor.
    nonisolated static func gitDiff(cwd: String) async -> String {
        guard !cwd.isEmpty else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", cwd, "diff", "--no-color"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: String(text.prefix(6000)))
            }
        }
    }
}
