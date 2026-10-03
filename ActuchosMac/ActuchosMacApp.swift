import SwiftUI

@main
struct ActuchosMacApp: App {
    @StateObject private var store = UpdateStore()

    init() {
        UserDefaults.standard.register(defaults: PreferenceKey.defaults)
    }

    var body: some Scene {
        WindowGroup("ActuchosMac") {
            ContentView().environmentObject(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Buscar actualizaciones") { Task { await store.scan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
                Button("Actualizar todo") { Task { await store.updateAll() } }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(store.isBusy || store.automaticUpdateCount == 0)
                Button("Actualizar selección") { Task { await store.updateSelected() } }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(store.isBusy || store.selectedRunnableCount == 0)
                Divider()
                Button("Seleccionar todas las actualizaciones") { store.selectAllUpdates(in: store.selectedCategory) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(store.isBusy)
            }
        }

        Settings { SettingsView() }
    }
}

private struct SettingsView: View {
    @AppStorage(PreferenceKey.scanOnLaunch) private var scanOnLaunch = true
    @AppStorage(PreferenceKey.refreshHomebrewIndex) private var refreshHomebrew = true
    @AppStorage(PreferenceKey.includeGreedyCasks) private var greedyCasks = false
    @AppStorage(PreferenceKey.checkVendorFeeds) private var vendorFeeds = true
    @AppStorage(PreferenceKey.useCaskCatalog) private var caskCatalog = true
    @AppStorage(PreferenceKey.quitRunningApps) private var quitRunningApps = true
    @AppStorage(PreferenceKey.includeBetas) private var includeBetas = false
    @AppStorage(PreferenceKey.allowOllamaModelPulls) private var ollamaPulls = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Buscar actualizaciones al abrir la app", isOn: $scanOnLaunch)
            }
            Section("Aplicaciones") {
                Toggle("Consultar a los fabricantes (Sparkle, Electron, VS Code, GitHub…)", isOn: $vendorFeeds)
                Toggle("Usar el catálogo de Homebrew para apps instaladas a mano", isOn: $caskCatalog)
                Text("Las descargas solo se instalan si están firmadas por el mismo desarrollador que la app actual y Gatekeeper las acepta. La versión anterior va a la Papelera.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Cerrar y volver a abrir las apps abiertas al actualizarlas", isOn: $quitRunningApps)
                Toggle("Incluir versiones beta", isOn: $includeBetas)
            }
            Section("Homebrew") {
                Toggle("Refrescar el índice (brew update) antes de comprobar", isOn: $refreshHomebrew)
                Toggle("Incluir casks con actualizador propio (--greedy)", isOn: $greedyCasks)
            }
            Section("IA") {
                Toggle("Permitir volver a descargar modelos Ollama individualmente", isOn: $ollamaPulls)
                Text("Cada modelo puede ocupar varios GB. Nunca forman parte de Actualizar todo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Los cambios se aplican en la siguiente búsqueda.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
