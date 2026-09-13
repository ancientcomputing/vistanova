// AppModel — the app's one piece of real logic: connect Tavily over MCP, let the user pick any
// registered LOCAL model (Apple on-device, or a downloaded MLX open-weight model — no cloud
// providers; a search backend other than Tavily, e.g. Brave/Exa, is a config option for later,
// not built yet), and run searches as topic threads that stay conversational until the model
// itself decides the user has moved on.
//
// Conversational fine-tuning, in one paragraph: a topic thread owns one real `LanguageModelSession`
// (via `lab.makeSession`, tools = the enabled MCP tools = tavily_search). Every `send()` while
// that thread is open re-uses the SAME session, so the model sees prior turns and can narrow the
// tavily_search query using that context. Before reusing it, a small classification call (a
// separate, disposable session — never the thread's own, so classifying never pollutes its
// transcript) asks "is this a refinement or a new topic?". A new topic drops the old session
// entirely and starts a fresh one with no memory of it.

import Foundation
import Observation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKComponents
import LocalLMLabSDKInference

@Generable
struct WebPage {
    @Guide(description: "A short, descriptive title for the page")
    let title: String
    @Guide(description: "The page's full URL, starting with http:// or https://")
    let url: String
}

@Generable
struct SearchResults {
    @Guide(description: "Exactly 5 distinct web pages that cover the topic")
    let pages: [WebPage]
}

@Generable
struct TopicDecision {
    @Guide(description: "true if the new query continues/refines the current topic, false if it switches to an unrelated new topic")
    let isRefinement: Bool
}

@available(macOS 27, *)
@MainActor
@Observable
final class AppModel {
    let lab: LocalLMLab
    private let mlxProvider = MLXModelProvider()
    var selectedModel: ModelID = .system

    var threads: [TopicThread] = []
    var input: String = ""
    var isSearching = false
    var lastError: String?

    /// nil until Tavily has been added at least once (drives the blocking setup sheet).
    var tavilyConfigured = false
    var tavilyConnected = false

    private let tavilyURL = URL(string: "https://mcp.tavily.com/mcp/")!
    private var tavilyServerID: MCPServerID { MCPServerID(rawValue: tavilyURL.absoluteString) }

    /// The live session behind the currently-open topic thread, and which thread it belongs to.
    /// nil whenever there's no open thread (fresh launch, or the last turn started a new topic
    /// that hasn't run yet).
    private var activeSession: LanguageModelSession?
    private var activeSessionSupportsGuidedGeneration = false
    private var activeThreadID: UUID?

    /// Not every MLX model supports Apple's constrained/"guided" generation (the mechanism
    /// `@Generable` structured output relies on) — confirmed live: Qwen3-8B-4bit threw "The
    /// selected model does not support guided generation" on every search. Cache per model since
    /// `capabilityProbe` runs a real prompt + tool call to find out.
    private var guidedGenerationCache: [ModelID: Bool] = [:]

    init() {
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider(), mlxProvider]))
        let settings = SettingsStore.load()
        threads = HistoryStore.load()
        selectedModel = ModelID(settings.selectedModel) ?? .system

        if let tavily = settings.tavilyServer {
            tavilyConfigured = true
            Task { await reconnectTavily(shape: tavily) }
        }
    }

    var availableModels: [ModelID] {
        lab.models.knownModels.filter { lab.models.availability(for: $0).isAvailable }
    }

    // MARK: - Tavily (MCP)

    func connectTavily(apiKey: String) async -> String? {
        let result = await lab.mcp.addServer(
            url: tavilyURL, displayName: "Tavily", authType: .pat, patToken: apiKey)
        switch result {
        case .success(let state):
            enableOnlySearch(on: state)
            tavilyConfigured = true
            tavilyConnected = true
            var settings = SettingsStore.load()
            settings.tavilyServer = PersistedTavilyServer(
                url: tavilyURL.absoluteString, displayName: "Tavily",
                toolNames: ["tavily_search"], estimatedTokens: state.estimatedTokens)
            SettingsStore.save(settings)
            return nil
        case .failure(let error):
            return "\(error)"
        }
    }

    func removeTavily() {
        lab.mcp.removeServer(tavilyServerID)
        tavilyConfigured = false
        tavilyConnected = false
        var settings = SettingsStore.load()
        settings.tavilyServer = nil
        SettingsStore.save(settings)
    }

    private func reconnectTavily(shape: PersistedTavilyServer) async {
        lab.mcp.restore(from: [(
            id: tavilyServerID, url: tavilyURL, displayName: shape.displayName,
            tools: [], estimatedTokens: shape.estimatedTokens, enabled: true,
            authType: .pat, manualClientID: nil, resources: []
        )])
        let result = await lab.mcp.reconnect(tavilyServerID)
        if case .success(let state) = result {
            enableOnlySearch(on: state)
            tavilyConnected = true
        } else {
            tavilyConnected = false
        }
    }

    private func enableOnlySearch(on state: MCPServerState) {
        for descriptor in state.tools {
            lab.mcp.setToolEnabled(server: state.id, tool: descriptor.name, enabled: descriptor.name == "tavily_search")
        }
    }

    // MARK: - Search

    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching, tavilyConnected else { return }
        input = ""
        lastError = nil
        isSearching = true
        defer { isSearching = false }

        var continuesActiveThread = false
        if activeSession != nil {
            continuesActiveThread = await classify(query: query)
        }

        do {
            let links: [SearchResultLink]
            if continuesActiveThread, let session = activeSession, let threadID = activeThreadID {
                links = try await search(query: query, using: session, supportsGuidedGeneration: activeSessionSupportsGuidedGeneration)
                appendTurn(query: query, links: links, toThreadID: threadID)
            } else {
                let supportsGuided = await guidedGenerationSupported(selectedModel)
                let session = try makeSearchSession(supportsGuidedGeneration: supportsGuided)
                activeSession = session
                activeSessionSupportsGuidedGeneration = supportsGuided
                links = try await search(query: query, using: session, supportsGuidedGeneration: supportsGuided)
                let thread = TopicThread(
                    turns: [SearchTurn(query: query, links: links, timestamp: Date())],
                    createdAt: Date())
                activeThreadID = thread.id
                threads.append(thread)
                HistoryStore.save(threads)
            }
        } catch {
            lastError = await GenerationErrorDescription.describe(error)
        }
    }

    /// Ends the current topic thread early so the very next `send()` always starts fresh — used
    /// when the model's own classification can't run (e.g. mid-turn failure) or the user wants
    /// an explicit reset.
    func endActiveThread() {
        activeSession = nil
        activeSessionSupportsGuidedGeneration = false
        activeThreadID = nil
    }

    /// Apple's own models (on-device, PCC) always support `@Generable` structured output; an MLX
    /// model needs a one-time real-prompt probe to find out, since not all of them do.
    private func guidedGenerationSupported(_ id: ModelID) async -> Bool {
        guard id.scheme == "mlx" else { return true }
        if let cached = guidedGenerationCache[id] { return cached }
        let report = await mlxProvider.capabilityProbe(id)
        let supported = report.capabilities.contains(.guidedGeneration)
        guidedGenerationCache[id] = supported
        return supported
    }

    private func classify(query: String) async -> Bool {
        guard let threadID = activeThreadID,
              let thread = threads.first(where: { $0.id == threadID }) else { return false }
        let previousQueries = thread.turns.map(\.query).joined(separator: "; ")
        do {
            lab.models.route("classify", to: selectedModel)
            let session = try lab.makeSession(
                route: "classify",
                instructions: "You judge whether a new search query continues the same topic as previous queries, or switches to something unrelated.",
                includeMCPTools: false)
            let prompt = """
            Previous queries in this topic, oldest first: \(previousQueries)
            New query: "\(query)"
            Is the new query a refinement/continuation of the same topic, or a switch to a different topic?
            """
            let response = try await session.languageModelSession.respond(to: prompt, generating: TopicDecision.self)
            return response.content.isRefinement
        } catch {
            // Can't classify — safest default is to treat it as a new topic rather than risk
            // silently merging two unrelated searches into one thread.
            return false
        }
    }

    private func makeSearchSession(supportsGuidedGeneration: Bool) throws -> LanguageModelSession {
        lab.models.route("chat", to: selectedModel)
        // Deliberately plain otherwise — an earlier version explained the follow-up/refinement
        // mechanic in the instructions themselves, which backfired: the small on-device model
        // started reasoning out loud about its own role and conversational obligations instead
        // of just searching (confirmed live: a query got refused with "I cannot fulfill this
        // request because it involves a misunderstanding of my role"). The session already
        // carries earlier turns in its own transcript — that's the actual mechanism refinement
        // runs on — so there's nothing to explain here; just tell it to search.
        //
        // The output-format line only gets added when guided generation isn't available: with it,
        // `@Generable` enforces the shape directly and an extra formatting instruction is just
        // more words for a small model to misread; without it, the model has no schema at all, so
        // the format has to be spelled out for parsePlainTextLinks to have anything reliable to
        // parse.
        let formatInstruction = supportsGuidedGeneration ? "" : """
             Respond with exactly 5 lines, one per result, each formatted exactly as \
            "Title — URL" and nothing else — no numbering, headers, or extra commentary.
            """
        let session = try lab.makeSession(
            route: "chat",
            instructions: """
            You are a web search engine. Given a query, call tavily_search exactly once with \
            max_results set to 5 and search_depth set to "basic", then report back the 5 results \
            tavily_search returned. Do not answer from your own knowledge and do not add \
            commentary beyond the requested titles and URLs.\(formatInstruction)
            """)
        return session.languageModelSession
    }

    private func search(query: String, using session: LanguageModelSession, supportsGuidedGeneration: Bool, isRetry: Bool = false) async throws -> [SearchResultLink] {
        if supportsGuidedGeneration {
            do {
                let response = try await session.respond(to: query, generating: SearchResults.self)
                return response.content.pages.map { SearchResultLink(title: $0.title, url: $0.url) }
            } catch {
                // Apple's on-device guardrail can intercept a turn about a public figure/name
                // after the model already produced a fully valid SearchResults payload — the
                // session then throws instead of returning, but the JSON survives in the error's
                // own description (confirmed live: a "Muhammad Ali" search threw "The model
                // declined to respond: {...5 real results...}"). Recover it rather than dead-end
                // a turn that actually worked.
                if let recovered = await Self.recoverPages(from: error) { return recovered }
                // No JSON to recover — a plain-text decline. These have been non-deterministic in
                // testing (the same query can succeed on a fresh attempt), so retry once before
                // surfacing the error.
                if !isRetry {
                    return try await search(query: query, using: session, supportsGuidedGeneration: true, isRetry: true)
                }
                throw error
            }
        } else {
            // No structured-output support on this model (see guidedGenerationSupported(_:)) — a
            // plain response.content String, parsed leniently for (title, url) pairs rather than
            // relying on the model to hit an exact format every time.
            let response = try await session.respond(to: query)
            let links = Self.parsePlainTextLinks(response.content)
            if !links.isEmpty { return links }
            if !isRetry {
                return try await search(query: query, using: session, supportsGuidedGeneration: false, isRetry: true)
            }
            throw SearchParseError.noResultsParsed(rawText: response.content)
        }
    }

    enum SearchParseError: LocalizedError {
        case noResultsParsed(rawText: String)
        var errorDescription: String? {
            switch self {
            case .noResultsParsed(let rawText):
                return "Couldn't find any links in the model's response: \(rawText)"
            }
        }
    }

    /// Extracts (title, url) pairs from an unstructured model response — used when the selected
    /// model has no guided-generation support to enforce a schema. Scans line by line for a URL
    /// and takes the text before it (minus numbering/bullets) as the title, rather than requiring
    /// the exact "Title — URL" format the instructions ask for, since a small model won't always
    /// hit it precisely.
    private static func parsePlainTextLinks(_ text: String) -> [SearchResultLink] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            guard let urlRange = line.range(of: #"https?://\S+"#, options: .regularExpression) else { return nil }
            let url = line[urlRange].trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}\"'"))
            var title = line[line.startIndex..<urlRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-–—|:) \t"))
            if title.isEmpty { title = url }
            return SearchResultLink(title: title, url: url)
        }
    }

    private struct RawPage: Decodable { let title: String; let url: String }
    private struct RawSearchResults: Decodable { let pages: [RawPage] }

    private static func recoverPages(from error: Error) async -> [SearchResultLink]? {
        let description = await GenerationErrorDescription.describe(error)
        if let strict = recoverPagesStrict(description) { return strict }
        return recoverPagesLeniently(description)
    }

    /// The common case: the embedded payload is valid JSON.
    private static func recoverPagesStrict(_ description: String) -> [SearchResultLink]? {
        guard let start = description.firstIndex(of: "{"),
              let end = description.lastIndex(of: "}"),
              start < end else { return nil }
        let json = description[start...end]
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawSearchResults.self, from: data) else { return nil }
        return decoded.pages.map { SearchResultLink(title: $0.title, url: $0.url) }
    }

    /// Confirmed live: the guardrail-declined path sometimes drops the quote(s) around a url
    /// value (`"url": https://…` instead of `"url": "https://…"`), inconsistently — sometimes
    /// missing the opening quote, sometimes both — which breaks strict JSON parsing outright.
    /// Pull (title, url) pairs out with a permissive regex instead of requiring well-formed JSON.
    private static func recoverPagesLeniently(_ description: String) -> [SearchResultLink]? {
        guard let regex = try? NSRegularExpression(
            pattern: #""title"\s*:\s*"([^"]*)"\s*,\s*"url"\s*:\s*"?(https?://[^\s",}]+)"?"#
        ) else { return nil }
        let ns = description as NSString
        let matches = regex.matches(in: description, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        return matches.map {
            SearchResultLink(title: ns.substring(with: $0.range(at: 1)), url: ns.substring(with: $0.range(at: 2)))
        }
    }

    private func appendTurn(query: String, links: [SearchResultLink], toThreadID threadID: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].turns.append(SearchTurn(query: query, links: links, timestamp: Date()))
        HistoryStore.save(threads)
    }

    // MARK: - Persistence

    func persistSelectedModel() {
        var settings = SettingsStore.load()
        settings.selectedModel = selectedModel.rawValue
        SettingsStore.save(settings)
    }
}
