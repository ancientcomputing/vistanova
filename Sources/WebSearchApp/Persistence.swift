// Persistence — everything the app remembers across launches. Nothing here is a secret: the
// Tavily MCP server's own PAT is persisted automatically by MCPServerManager/MCPPATStore (see
// locallm/docs/mcp-tavily.md) — we only persist its non-secret shape (URL, tool list) so
// `lab.mcp.restore(from:)` + `reconnect(id)` can bring the live connection back without the user
// re-entering the key. Every model is local (Apple on-device or a downloaded MLX model), so
// there's no other credential to store. Search history (topic threads) is plain JSON.

import Foundation
import LocalLMLabSDKCore

// MARK: - Search history

struct SearchResultLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct SearchTurn: Codable, Identifiable, Hashable {
    var id = UUID()
    var query: String
    var links: [SearchResultLink]
    var timestamp: Date
}

struct TopicThread: Codable, Identifiable, Hashable {
    var id = UUID()
    var turns: [SearchTurn]
    var createdAt: Date

    var title: String { turns.first?.query ?? "" }
}

enum HistoryStore {
    static let maxThreads = 100

    static func load() -> [TopicThread] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TopicThread].self, from: data)) ?? []
    }

    /// Appends/updates `thread` and trims to `maxThreads`, oldest first out.
    static func save(_ threads: [TopicThread]) {
        let trimmed = threads.suffix(maxThreads)
        guard let data = try? JSONEncoder().encode(Array(trimmed)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var url: URL { AppPaths.supportDirectory.appendingPathComponent("history.json") }
}

// MARK: - App settings (non-secret) — selected model, Tavily server shape

struct PersistedTavilyServer: Codable {
    var url: String
    var displayName: String
    var toolNames: [String]     // just tavily_search, kept as a list for forward-compat
    var estimatedTokens: Int
}

struct AppSettings: Codable {
    var selectedModel: String = "system"   // ModelID.rawValue
    var tavilyServer: PersistedTavilyServer?
}

enum SettingsStore {
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var url: URL { AppPaths.supportDirectory.appendingPathComponent("settings.json") }
}

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "WebSearchApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
