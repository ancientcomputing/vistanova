// AppModel — the app's one piece of real logic: connect Tavily over MCP, let the user pick any
// registered model (on-device or hosted, via LocalLMLab/Components/Remote), and run searches as
// topic threads that stay conversational until the model itself decides the user has moved on.
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
import LocalLMLabSDKRemote

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

    var providers: [RemoteProviderDraft] = [] {
        didSet { persistProviders(previousSchemes: Set(oldValue.map(\.scheme))) }
    }
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
    private var activeThreadID: UUID?

    init() {
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider()]))
        let settings = SettingsStore.load()
        threads = HistoryStore.load()
        selectedModel = ModelID(settings.selectedModel) ?? .system

        providers = settings.providers.compactMap { persisted in
            guard let kind = RemoteProviderKind(rawValue: persisted.kind) else { return nil }
            var draft = RemoteProviderDraft(
                scheme: persisted.scheme, displayName: persisted.displayName, kind: kind,
                baseURL: persisted.baseURL, apiKey: KeychainStore.get(account: persisted.scheme) ?? "",
                models: persisted.models,
                webSearchSupported: persisted.webSearchSupported,
                webSearchEnabled: persisted.webSearchEnabled,
                maxSearches: persisted.maxSearches)
            if let config = draft.makeConfig() {
                lab.models.replace(RemoteModelProvider(config))
                draft.configured = true
                draft.statusText = "\(config.models.count) model(s) available."
            }
            return draft
        }

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

    // MARK: - Provider config (Components' AIModelsSettingsView calls these)

    func applyDraft(_ draft: RemoteProviderDraft) {
        guard let idx = providers.firstIndex(where: { $0.scheme == draft.scheme }) else { return }
        var updated = draft
        if let config = draft.makeConfig() {
            lab.models.replace(RemoteModelProvider(config))
            updated.configured = true
            updated.statusText = "\(config.models.count) model(s) available."
        } else {
            lab.models.removeProvider(scheme: draft.scheme)
            updated.configured = false
            updated.statusText = "Enter an API key to enable."
        }
        providers[idx] = updated
    }

    func removeDraft(_ draft: RemoteProviderDraft) {
        lab.models.removeProvider(scheme: draft.scheme)
        if selectedModel.scheme == draft.scheme { selectedModel = .system }
    }

    func testDraft(_ draft: RemoteProviderDraft) async -> ProviderTestOutcome {
        guard let config = draft.makeConfig(), !config.models.isEmpty else {
            return .unableToRun("Add a model id and an API key first.")
        }
        let provider = RemoteModelProvider(config)
        var results: [ProviderTestOutcome.ModelResult] = []
        for model in config.models {
            guard let modelID = ModelID(scheme: config.scheme, rest: model.id) else {
                results.append(.init(modelId: model.id, ok: false, detail: "isn't a valid model id."))
                continue
            }
            let availability = await provider.probe(for: modelID)
            let detail: String
            switch availability {
            case .available: detail = "Available."
            case .needsCredential: detail = "The API key was rejected."
            case .unavailable(_, let d): detail = d
            default: detail = "Unknown status."
            }
            results.append(.init(modelId: model.id, ok: availability.isAvailable, detail: detail))
        }
        return ProviderTestOutcome(results: results)
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
                links = try await search(query: query, using: session)
                appendTurn(query: query, links: links, toThreadID: threadID)
            } else {
                let session = try makeSearchSession()
                activeSession = session
                links = try await search(query: query, using: session)
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
        activeThreadID = nil
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

    private func makeSearchSession() throws -> LanguageModelSession {
        lab.models.route("chat", to: selectedModel)
        let session = try lab.makeSession(
            route: "chat",
            instructions: """
            You are a web search engine. Given a query, call tavily_search exactly once with \
            max_results set to 5 and search_depth set to "basic", then report back the 5 results \
            tavily_search returned. If this is a follow-up to a previous query in the same \
            conversation, use that context to make the search more specific rather than repeating \
            the earlier search verbatim. Do not answer from your own knowledge and do not add \
            commentary beyond the requested titles and URLs.
            """)
        return session.languageModelSession
    }

    private func search(query: String, using session: LanguageModelSession) async throws -> [SearchResultLink] {
        do {
            let response = try await session.respond(to: query, generating: SearchResults.self)
            return response.content.pages.map { SearchResultLink(title: $0.title, url: $0.url) }
        } catch {
            // Apple's on-device guardrail can intercept a turn about a public figure/name after
            // the model already produced a fully valid SearchResults payload — the session then
            // throws instead of returning, but the JSON survives in the error's own description
            // (confirmed live: a "Muhammad Ali" search threw "The model declined to respond:
            // {...5 real results...}"). Recover it rather than dead-end a turn that actually
            // worked.
            if let recovered = await Self.recoverPages(from: error) { return recovered }
            throw error
        }
    }

    private struct RawPage: Decodable { let title: String; let url: String }
    private struct RawSearchResults: Decodable { let pages: [RawPage] }

    private static func recoverPages(from error: Error) async -> [SearchResultLink]? {
        let description = await GenerationErrorDescription.describe(error)
        FileHandle.standardError.write(Data("[recover] description=\(description)\n".utf8))
        guard let start = description.firstIndex(of: "{"),
              let end = description.lastIndex(of: "}"),
              start < end else {
            FileHandle.standardError.write(Data("[recover] no braces found\n".utf8))
            return nil
        }
        let json = description[start...end]
        guard let data = json.data(using: .utf8) else {
            FileHandle.standardError.write(Data("[recover] bad utf8\n".utf8))
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(RawSearchResults.self, from: data)
            return decoded.pages.map { SearchResultLink(title: $0.title, url: $0.url) }
        } catch {
            FileHandle.standardError.write(Data("[recover] decode failed: \(error)\n".utf8))
            return nil
        }
    }

    private func appendTurn(query: String, links: [SearchResultLink], toThreadID threadID: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].turns.append(SearchTurn(query: query, links: links, timestamp: Date()))
        HistoryStore.save(threads)
    }

    // MARK: - Persistence

    private func persistProviders(previousSchemes: Set<String>) {
        var settings = SettingsStore.load()
        settings.selectedModel = selectedModel.rawValue
        settings.providers = providers.map {
            PersistedProviderDraft(
                scheme: $0.scheme, displayName: $0.displayName, kind: $0.kind.rawValue,
                baseURL: $0.baseURL, models: $0.models,
                webSearchSupported: $0.webSearchSupported, webSearchEnabled: $0.webSearchEnabled,
                maxSearches: $0.maxSearches)
        }
        SettingsStore.save(settings)

        let currentSchemes = Set(providers.map(\.scheme))
        for draft in providers where !draft.apiKey.isEmpty {
            KeychainStore.set(draft.apiKey, account: draft.scheme)
        }
        for removedScheme in previousSchemes.subtracting(currentSchemes) {
            KeychainStore.delete(account: removedScheme)
        }
    }

    func persistSelectedModel() {
        var settings = SettingsStore.load()
        settings.selectedModel = selectedModel.rawValue
        SettingsStore.save(settings)
    }
}
