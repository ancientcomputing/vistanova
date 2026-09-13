// AppModel — the app's one piece of real logic: connect Tavily over MCP, let the user pick any
// registered LOCAL model (Apple on-device, or a downloaded MLX open-weight model — no cloud
// providers; a search backend other than Tavily, e.g. Brave/Exa, is a config option for later,
// not built yet), and run searches as topic threads.
//
// Refinement, in one paragraph: an earlier version had the model itself decide whether a new
// query continued the current topic or started a fresh one, silently expanding an ambiguous
// follow-up ("last ceo") using the thread's earlier turns. Confirmed live that this fails exactly
// where it matters most — that exact query, inside a Yahoo thread, got grounded to Tim Cook
// instead, silently, with no way to notice short of reading the tiny subtitle. So there is no
// automatic grounding or topic classification anymore. The composer leaves each submitted query
// sitting in the box (editable) instead of clearing it — the user edits it directly ("last ceo" →
// "yahoo last ceo") or hits the clear button to start a genuinely new topic, and *that* explicit
// action, not a model guess, is what decides whether the next search extends `activeThreadID` or
// starts a new one. Every search is a fresh, stateless `LocalLMLabSession` — nothing here relies
// on conversational memory inside the model any more.

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

    /// The thread the next submitted query appends to. nil means the next submission starts a
    /// new thread — set that way by `clearForNewTopic()`, which is the ONLY thing that closes a
    /// thread now (no model classification involved).
    private var activeThreadID: UUID?

    /// Two independent things to know about a model before searching with it, both confirmed
    /// live to vary across MLX models: whether it reliably calls a tool at all (Qwen3-8B-4bit,
    /// Gemma, and Granite all answered "who founded Yahoo" from their own training data instead of
    /// calling tavily_search, despite being told not to), and separately, whether it supports
    /// Apple's constrained/"guided" generation that `@Generable` structured output relies on
    /// (Qwen3-8B-4bit: "The selected model does not support guided generation"). Both come from
    /// one `capabilityProbe` call (a real prompt + a trivial tool call), cached per model since
    /// that probe itself costs real inference time.
    private struct ModelSearchCapability { var toolCalling: Bool; var guidedGeneration: Bool }
    private var capabilityCache: [ModelID: ModelSearchCapability] = [:]

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
        if case .success = result {
            tavilyConnected = true
        } else {
            tavilyConnected = false
        }
    }

    // MARK: - Search

    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching, tavilyConnected else { return }
        // Left visible (but not editable — see ChatView's composer) after the turn finishes too,
        // success or failure — this app no longer clears the box for you. The user edits it
        // in place to refine, or hits the clear button to start a new topic; see this file's
        // top comment for why that replaced model-guessed refinement.
        lastError = nil
        isSearching = true
        defer { isSearching = false }

        do {
            let capability = await searchCapability(selectedModel)
            guard capability.toolCalling else {
                lastError = "This model doesn't reliably call tools, so it can't be trusted to actually search rather than answer from its own training data. Pick a different model in Settings."
                return
            }
            let (session, capture) = try makeSearchSession(supportsGuidedGeneration: capability.guidedGeneration)
            let (links, searchQuery) = try await search(query: query, using: session, capture: capture, supportsGuidedGeneration: capability.guidedGeneration)

            if let threadID = activeThreadID {
                appendTurn(query: query, searchQuery: searchQuery, links: links, toThreadID: threadID)
            } else {
                let thread = TopicThread(
                    turns: [SearchTurn(query: query, searchQuery: searchQuery, links: links, timestamp: Date())],
                    createdAt: Date())
                activeThreadID = thread.id
                threads.append(thread)
                HistoryStore.save(threads)
            }
        } catch {
            lastError = await GenerationErrorDescription.describe(error)
        }
    }

    /// The explicit "new topic" signal — the composer's clear button. Nothing else closes a
    /// thread; see this file's top comment.
    func clearForNewTopic() {
        input = ""
        activeThreadID = nil
        lastError = nil
    }

    /// Switching models mid-thread: the thread closes (a different model shouldn't silently
    /// inherit a thread it never saw), but unlike `clearForNewTopic()` the box keeps its text —
    /// the user didn't ask to abandon what they typed, just to answer it with a different model.
    func endActiveThread() {
        activeThreadID = nil
    }

    /// Apple's own models (on-device, PCC) always support tool calling and `@Generable` structured
    /// output; an MLX model needs a one-time real-prompt-plus-tool-call probe to find out either,
    /// since not all of them reliably do.
    private func searchCapability(_ id: ModelID) async -> ModelSearchCapability {
        guard id.scheme == "mlx" else { return ModelSearchCapability(toolCalling: true, guidedGeneration: true) }
        if let cached = capabilityCache[id] { return cached }
        let report = await mlxProvider.capabilityProbe(id)
        let capability = ModelSearchCapability(
            toolCalling: report.capabilities.contains(.toolCalling),
            guidedGeneration: report.capabilities.contains(.guidedGeneration))
        capabilityCache[id] = capability
        return capability
    }

    /// Deliberately a fresh, stateless session every call — no transcript carried over between
    /// searches. An earlier version reused one session per topic thread so the model could see
    /// prior turns, and separately explained the follow-up mechanic in its own instructions; the
    /// explaining backfired (the small on-device model started reasoning out loud about its own
    /// role instead of just searching: "I cannot fulfill this request because it involves a
    /// misunderstanding of my role"), and the reuse itself let a wrong guess happen silently
    /// (confirmed live: "last ceo" inside a Yahoo thread got grounded to Tim Cook). Refinement now
    /// happens in the composer, not the model — see this file's top comment.
    private func makeSearchSession(supportsGuidedGeneration: Bool) throws -> (LocalLMLabSession, SearchQueryCapture) {
        lab.models.route("chat", to: selectedModel)
        // The output-format line only gets added when guided generation isn't available: with it,
        // `@Generable` enforces the shape directly and an extra formatting instruction is just
        // more words for a small model to misread; without it, the model has no schema at all, so
        // the format has to be spelled out for parsePlainTextLinks to have anything reliable to
        // parse.
        let formatInstruction = supportsGuidedGeneration ? "" : """
             Respond with exactly 5 lines, one per result, each formatted exactly as \
            "Title — URL" and nothing else — no numbering, headers, or extra commentary.
            """
        let capture = SearchQueryCapture()
        let tool = TavilySearchTool(manager: lab.mcp, serverID: tavilyServerID, capture: capture)
        let session = try lab.makeSession(
            route: "chat",
            tools: [tool],
            instructions: """
            You are a web search engine. Given a query, call tavily_search exactly once, then \
            report back the 5 results tavily_search returned. Do not answer from your own \
            knowledge and do not add commentary beyond the requested titles and URLs.\(formatInstruction)
            """,
            includeMCPTools: false)
        return (session, capture)
    }

    /// Up to 2 full attempts, each running to completion (including cancelling its own event
    /// watcher) before the next starts — deliberately a loop, not recursion, so two attempts
    /// never watch `session.events` concurrently. Returns the links plus whatever query
    /// `TavilySearchTool` actually captured, so the UI can show what was really searched instead
    /// of just repeating the user's literal input.
    private func search(query: String, using session: LocalLMLabSession, capture: SearchQueryCapture, supportsGuidedGeneration: Bool) async throws -> (links: [SearchResultLink], searchQuery: String?) {
        var lastError: Error = SearchParseError.toolNotCalled
        for attempt in 0..<2 {
            do {
                let links = try await attemptSearch(query: query, using: session, supportsGuidedGeneration: supportsGuidedGeneration)
                return (links, await capture.query)
            } catch {
                lastError = error
                if attempt == 1 { throw error }
            }
        }
        throw lastError
    }

    private func attemptSearch(query: String, using session: LocalLMLabSession, supportsGuidedGeneration: Bool) async throws -> [SearchResultLink] {
        // Confirmed live: a model can answer a search query straight from its own training data
        // instead of calling tavily_search at all, despite explicit instructions not to (Qwen3,
        // Gemma, and Granite all did this for "who founded Yahoo?"). Watch the session's own
        // event stream for the tool actually starting, rather than trusting that a
        // plausible-looking response means it searched.
        var toolWasCalled = false
        let watcher = Task {
            for await event in session.events {
                if case .toolCallStarted(_, let name) = event, name == "tavily_search" {
                    toolWasCalled = true
                }
            }
        }
        defer { watcher.cancel() }

        if supportsGuidedGeneration {
            do {
                let response = try await session.languageModelSession.respond(to: query, generating: SearchResults.self)
                guard toolWasCalled else { throw SearchParseError.toolNotCalled }
                return response.content.pages.map { SearchResultLink(title: $0.title, url: $0.url) }
            } catch {
                // Apple's on-device guardrail can intercept a turn about a public figure/name
                // after the model already produced a fully valid SearchResults payload — the
                // session then throws instead of returning, but the JSON survives in the error's
                // own description (confirmed live: a "Muhammad Ali" search threw "The model
                // declined to respond: {...5 real results...}"). Recover it rather than dead-end
                // a turn that actually worked. (A recovered payload implies the tool did run —
                // those are Tavily's own real results embedded in the decline text.)
                if let recovered = await Self.recoverPages(from: error) { return recovered }
                throw error
            }
        } else {
            // No structured-output support on this model (see searchCapability(_:)) — a plain
            // response.content String, parsed leniently for (title, url) pairs rather than
            // relying on the model to hit an exact format every time.
            let response = try await session.languageModelSession.respond(to: query)
            let links = Self.parsePlainTextLinks(response.content)
            guard toolWasCalled, !links.isEmpty else {
                throw toolWasCalled ? SearchParseError.noResultsParsed(rawText: response.content) : SearchParseError.toolNotCalled
            }
            return links
        }
    }

    enum SearchParseError: LocalizedError {
        case noResultsParsed(rawText: String)
        case toolNotCalled
        var errorDescription: String? {
            switch self {
            case .noResultsParsed(let rawText):
                return "Couldn't find any links in the model's response: \(rawText)"
            case .toolNotCalled:
                return "The model answered from its own knowledge instead of searching. Try again, or pick a different model."
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

    private func appendTurn(query: String, searchQuery: String?, links: [SearchResultLink], toThreadID threadID: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].turns.append(SearchTurn(query: query, searchQuery: searchQuery, links: links, timestamp: Date()))
        HistoryStore.save(threads)
    }

    // MARK: - Persistence

    func persistSelectedModel() {
        var settings = SettingsStore.load()
        settings.selectedModel = selectedModel.rawValue
        SettingsStore.save(settings)
    }
}
