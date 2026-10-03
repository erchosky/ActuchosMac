import Foundation

/// Synthetic inventories for UI work and tests. Selected with `--demo` or `--demo=<scenario>`.
enum DemoScenario: String, CaseIterable, Sendable {
    case clean
    case developer
    case standard
    case manyUpdates = "many-updates"
    case failures
    case pyenv
    case homebrewNode = "homebrew-node"
    case multipleNode = "multiple-node"
    case mas
    case manualApps = "manual-apps"

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> DemoScenario? {
        guard let argument = arguments.first(where: { $0 == "--demo" || $0.hasPrefix("--demo=") }) else { return nil }
        guard let value = argument.split(separator: "=", maxSplits: 1).dropFirst().first else { return .developer }
        return DemoScenario(rawValue: String(value)) ?? .developer
    }
}

struct DemoProvider: UpdateProvider {
    let id = "demo"
    let displayName = "Datos simulados"
    let priority = 1
    let scenario: DemoScenario

    init(scenario: DemoScenario = .developer) { self.scenario = scenario }

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let macOS = UpdateItem(
            id: "demo:macos", providerID: id, name: "macOS", category: .system, installedVersion: "26.0", status: .current,
            source: "Apple", updateMethod: "Software Update", requiresAdmin: true, architecture: "arm64", priority: priority,
            metadata: [MetadataKey.openURL: AppleSoftwareProvider.settingsURL]
        )
        let firefox = UpdateItem(
            id: "demo:firefox", providerID: id, name: "Firefox", category: .applications, installedVersion: "141.0",
            availableVersion: "142.0", status: .updateAvailable, source: "Homebrew Cask", updateMethod: "brew upgrade --cask",
            canUpdateAutomatically: true, path: "/Applications/Firefox.app", architecture: "arm64 x86_64",
            signature: "Mozilla Corporation", priority: priority
        )
        let sparkleApp = UpdateItem(
            id: "demo:sparkle", providerID: id, name: "Editor de ejemplo", category: .applications, installedVersion: "3.1",
            availableVersion: "3.2", status: .updateAvailable, source: "Instalación directa",
            updateMethod: "Actualizador propio (Sparkle)", architecture: "arm64",
            notes: "Abre la aplicación para instalar la actualización", priority: priority
        )
        let manual = UpdateItem(
            id: "demo:manual", providerID: id, name: "Aplicación manual", category: .unmanaged, installedVersion: "4.7",
            status: .unmanaged, source: "DMG", updateMethod: "Sin método seguro", architecture: "arm64", signature: "Firmada",
            notes: "No se reemplazará automáticamente", priority: priority
        )
        switch scenario {
        case .clean: return [macOS]
        case .standard: return [macOS, sparkleApp, manual]
        case .developer: return [macOS, firefox, sparkleApp, manual]
        case .manyUpdates:
            return [macOS, firefox, manual] + (1...12).map { index in
                UpdateItem(
                    id: "demo:update:\(index)", providerID: id, name: "Herramienta \(index)", category: .development,
                    installedVersion: "1.\(index).0", availableVersion: "1.\(index).1", status: .updateAvailable,
                    source: "Gestor simulado", updateMethod: "Provider simulado", canUpdateAutomatically: true,
                    architecture: HostEnvironment.architecture, priority: priority
                )
            }
        case .failures:
            var failure = firefox
            failure.status = .failed
            failure.canUpdateAutomatically = false
            failure.notes = "Fallo simulado del provider"
            return [macOS, failure, manual]
        case .pyenv:
            return [macOS, fixtureRuntime(id: "pyenv", name: "pyenv", version: "2.5.0", source: "pyenv")]
        case .homebrewNode:
            return [macOS, fixtureRuntime(id: "node-brew", name: "Node (activo en shell)", version: "24.1.0", source: "Homebrew")]
        case .multipleNode:
            return [
                macOS,
                fixtureRuntime(id: "node-nvm", name: "Node (activo en shell)", version: "22.4.1", source: "NVM"),
                fixtureRuntime(id: "node-brew", name: "Node (instalación adicional)", version: "24.1.0", source: "Homebrew")
            ]
        case .mas:
            var app = firefox
            app.source = "Mac App Store"
            app.updateMethod = "mas upgrade"
            return [macOS, app]
        case .manualApps:
            return [macOS, manual]
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        try? await Task.sleep(for: .milliseconds(300))
        return ProcessResult(command: "demo update \(item.id)", stdout: "Simulación completada", stderr: "",
                             exitCode: 0, duration: 0.3, timedOut: false)
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            var result = item
            result.installedVersion = item.availableVersion ?? item.installedVersion
            result.status = .updated
            return (item.id, result)
        })
    }

    private func fixtureRuntime(id value: String, name: String, version: String, source: String) -> UpdateItem {
        UpdateItem(
            id: "demo:\(value)", providerID: id, name: name, category: .development, installedVersion: version,
            status: .current, source: source, updateMethod: "Provider simulado", path: "~/fixtures/\(value)",
            architecture: HostEnvironment.architecture, notes: "Fixture sintético", priority: priority
        )
    }
}
