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
            // Apple on-device + downloadable MLX models (with a live progress bar and an "Add
            // from Hugging Face" field) — no cloud providers. show27OnlyModels is moot here since
            // the app already requires macOS 27.
            ModelPickerView(
                registry: model.lab.models,
                selection: Binding(
                    get: { model.selectedModel },
                    set: { newValue in
                        guard let newValue, newValue != model.selectedModel else { return }
                        model.selectedModel = newValue
                        model.persistSelectedModel()
                        model.endActiveThread()
                    }))
        }
        .sheet(isPresented: $showingTavilyReplace) {
            TavilySetupView(model: model)
        }
    }

    private var tavilySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tavily").font(AppFont.headline)
                Text(model.tavilyConnected ? "Connected" : "Not connected")
                    .font(AppFont.caption).foregroundStyle(.secondary)
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
