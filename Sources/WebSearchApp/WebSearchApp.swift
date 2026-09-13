import SwiftUI
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

@main
@available(macOS 27, *)
struct WebSearchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("WebSearch") {
            ChatView(model: model)
                .frame(minWidth: 480, minHeight: 480)
        }
        Settings {
            SettingsScreen(model: model)
                .frame(width: 560, height: 640)
        }
    }
}

@available(macOS 27, *)
private struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var showingTavilyReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tavilySection
            Divider()
            AIModelsSettingsView(
                registry: model.lab.models,
                providers: $model.providers,
                onSave: { model.applyDraft($0) },
                onRemove: { model.removeDraft($0) },
                onTest: { await model.testDraft($0) })
        }
        .sheet(isPresented: $showingTavilyReplace) {
            TavilySetupView(model: model)
        }
    }

    private var tavilySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tavily").font(.headline)
                Text(model.tavilyConnected ? "Connected" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.tavilyConfigured {
                Button("Change Key…") { showingTavilyReplace = true }
                Button("Remove", role: .destructive) { model.removeTavily() }
            } else {
                Button("Connect…") { showingTavilyReplace = true }
            }
        }
        .padding(16)
    }
}
