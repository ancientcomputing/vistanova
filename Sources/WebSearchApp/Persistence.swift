// Persistence — everything the app remembers across launches, split by sensitivity:
//  - Secrets (remote-provider API keys) go through KeychainStore, never through JSON on disk.
//  - The Tavily MCP server's own PAT is persisted automatically by MCPServerManager/MCPPATStore
//    (see locallm/docs/mcp-tavily.md) — we only persist its non-secret shape (URL, tool list) so
//    `lab.mcp.restore(from:)` + `reconnect(id)` can bring the live connection back without the
//    user re-entering the key.
//  - Search history (topic threads) is plain JSON — nothing secret in a title or a URL.

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

// MARK: - App settings (non-secret) — selected model, remote-provider shapes, Tavily server shape

struct PersistedProviderDraft: Codable {
    var scheme: String
    var displayName: String
    var kind: String            // RemoteProviderKind.rawValue
    var baseURL: String
    var models: [String]
    var webSearchSupported: Bool
    var webSearchEnabled: Bool
    var maxSearches: Int
}

struct PersistedTavilyServer: Codable {
    var url: String
    var displayName: String
    var toolNames: [String]     // just tavily_search, kept as a list for forward-compat
    var estimatedTokens: Int
}

struct AppSettings: Codable {
    var selectedModel: String = "system"   // ModelID.rawValue
    var providers: [PersistedProviderDraft] = []
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

// MARK: - Keychain (remote-provider API keys only — Tavily's PAT is handled by the SDK itself)

enum KeychainStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "WebSearchApp") + ".remoteProviderKey" }

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
