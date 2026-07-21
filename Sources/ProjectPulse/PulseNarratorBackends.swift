import Foundation
import FoundationModels

// MARK: - On-device (Apple Foundation Models)

/// Narrates project status entirely on-device via Apple's foundation model —
/// the privacy-preserving path (nothing leaves the Mac). Structured output
/// through `@Generable`, mirroring `ReplyPresetEngine`. On any failure or when
/// the model is unavailable it returns `[:]`, so the caller falls back to
/// templates per project.
struct FoundationModelsNarrator: PulseNarrator {

    /// Whether the on-device model can run right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct Batch {
        @Guide(description: "One entry per project you were given, describing its status.")
        var projects: [Item]

        @Generable
        struct Item {
            @Guide(description: "The exact cwd path copied verbatim from the project this entry describes.")
            var cwd: String
            @Guide(description: "A warm status headline of at most 6 words. No trailing punctuation.")
            var headline: String
            @Guide(description: "One short sentence of detail about the project's current status.")
            var detail: String
        }
    }

    func narrate(_ facts: [ProjectFacts]) async -> [String: ProjectNarration] {
        guard Self.isAvailable, !facts.isEmpty else { return [:] }
        let session = LanguageModelSession(instructions: PulseNarrationIO.system)
        let prompt = PulseNarrationIO.userPrompt(for: facts)
        do {
            let response = try await session.respond(to: prompt, generating: Batch.self)
            var out: [String: ProjectNarration] = [:]
            for item in response.content.projects {
                let cwd = item.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
                let headline = item.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cwd.isEmpty, !headline.isEmpty else { continue }
                out[cwd] = ProjectNarration(
                    headline: headline,
                    detail: item.detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return out
        } catch {
            return [:]
        }
    }
}

// MARK: - Cloud (OpenRouter)

/// Narrates project status through OpenRouter. Sends project facts off-device,
/// so it's only selected when the user has picked it (or `auto` with no
/// on-device model). Returns `[:]` on any failure, falling back to templates.
struct OpenRouterNarrator: PulseNarrator {
    let apiKey: String
    let model: String
    var client = OpenRouterClient()

    func narrate(_ facts: [ProjectFacts]) async -> [String: ProjectNarration] {
        guard !apiKey.isEmpty, !facts.isEmpty else { return [:] }
        do {
            let content = try await client.complete(
                system: PulseNarrationIO.system,
                user: PulseNarrationIO.userPrompt(for: facts),
                model: model, apiKey: apiKey)
            return PulseNarrationIO.parse(content)
        } catch {
            return [:]
        }
    }
}

// MARK: - Factory

/// Resolves the narrator mode + environment (on-device availability, key
/// presence) into a concrete narrator. Pure and deterministic so it can be
/// unit-tested; always falls back to `TemplateNarrator`.
enum NarratorFactory {
    static func make(mode: PulseNarratorMode,
                     onDeviceAvailable: Bool,
                     apiKey: String,
                     model: String) -> PulseNarrator {
        let hasKey = !apiKey.isEmpty
        switch mode {
        case .onDevice:
            return onDeviceAvailable ? FoundationModelsNarrator() : TemplateNarrator()
        case .openRouter:
            return hasKey ? OpenRouterNarrator(apiKey: apiKey, model: model) : TemplateNarrator()
        case .auto:
            if onDeviceAvailable { return FoundationModelsNarrator() }
            if hasKey { return OpenRouterNarrator(apiKey: apiKey, model: model) }
            return TemplateNarrator()
        }
    }

    /// Convenience: build from live settings + current model availability.
    @MainActor
    static func make(from settings: AppSettings) -> PulseNarrator {
        make(mode: settings.pulseNarratorMode,
             onDeviceAvailable: FoundationModelsNarrator.isAvailable,
             apiKey: settings.openRouterKey,
             model: settings.openRouterModel)
    }
}
