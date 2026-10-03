import Foundation

struct AppleSoftwareProvider: UpdateProvider {
    static let settingsURL = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    let id = "apple-software"
    let displayName = "Apple Software Update"
    let priority = 10

    struct AvailableUpdate: Equatable {
        var label: String
        var title: String
        var version: String?
        var isMacOS: Bool { title.hasPrefix("macOS") || label.hasPrefix("macOS") }
    }

    func detect(context: ProviderContext) async -> [UpdateItem] {
        [UpdateItem(
            id: "apple:macos", providerID: id, name: "macOS", category: .system,
            installedVersion: HostEnvironment.macOSVersion, source: "Apple", updateMethod: "Ajustes del Sistema › Actualización de software",
            requiresAdmin: true, path: "/usr/sbin/softwareupdate", architecture: context.architecture,
            notes: "La instalación de macOS requiere autorización y reinicio", deduplicationKey: "apple:softwareupdate",
            priority: priority, metadata: [MetadataKey.openURL: Self.settingsURL, MetadataKey.lock: "apple"]
        )]
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard var macOS = items.first(where: { $0.id == "apple:macos" }) else { return items }
        let result = await context.runner.run(Command(executable: "/usr/sbin/softwareupdate", arguments: ["--list"], timeout: 300))
        await context.logger.log(provider: displayName, "softwareupdate exit=\(result.exitCode) \(result.duration.formatted(.number.precision(.fractionLength(1))))s")
        guard result.succeeded else {
            macOS.status = .failed
            macOS.notes = result.combinedOutput
            return [macOS]
        }
        let updates = Self.parseAvailableUpdates(result.combinedOutput)
        if let system = updates.first(where: \.isMacOS) {
            macOS.status = .updateAvailable
            macOS.availableVersion = system.version
            macOS.notes = "\(system.title) · Instálalo desde Ajustes del Sistema (requiere reinicio)"
        } else if updates.isEmpty && !result.combinedOutput.localizedCaseInsensitiveContains("No new software available") {
            macOS.status = .unknown
            macOS.notes = "La salida de softwareupdate no pudo interpretarse con certeza"
        } else {
            macOS.status = .current
        }
        let components = updates.filter { !$0.isMacOS }.map { update in
            UpdateItem(
                id: "apple:label:\(update.label)", providerID: id, name: update.title, category: .system,
                availableVersion: update.version, status: .updateAvailable, source: "Apple",
                updateMethod: "softwareupdate (pide contraseña de administrador)", requiresAdmin: true,
                canUpdateAutomatically: true, notes: "macOS mostrará su propio diálogo de autorización",
                priority: priority, metadata: ["label": update.label, MetadataKey.lock: "apple"]
            )
        }
        return [macOS] + components
    }

    /// Non-macOS Apple updates (Command Line Tools, Safari…) are installed through macOS's own
    /// administrator prompt; ActuchosMac never sees the password.
    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let label = item.metadata["label"] else { return nil }
        let script = [
            "on run argv",
            "do shell script \"/usr/sbin/softwareupdate --install --no-scan \" & quoted form of (item 1 of argv) with administrator privileges",
            "end run"
        ]
        return await context.runner.run(Command(executable: "/usr/bin/osascript",
                                                arguments: script.flatMap { ["-e", $0] } + [label], timeout: 3600))
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        let result = await context.runner.run(Command(executable: "/usr/sbin/softwareupdate", arguments: ["--list"], timeout: 300))
        guard result.succeeded else { return [:] }
        let pending = Set(Self.parseAvailableUpdates(result.combinedOutput).map(\.label))
        var observed: [String: UpdateItem] = [:]
        for item in items {
            var fresh = item
            fresh.status = pending.contains(item.metadata["label"] ?? "") ? .updateAvailable : .current
            if fresh.status == .current { fresh.installedVersion = item.availableVersion }
            observed[item.id] = fresh
        }
        return observed
    }

    /// Parses `* Label: …` lines and the `Title: …, Version: …` line that follows each one.
    static func parseAvailableUpdates(_ output: String) -> [AvailableUpdate] {
        var updates: [AvailableUpdate] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label: ") {
                let label = String(line.dropFirst("* Label: ".count))
                updates.append(AvailableUpdate(label: label, title: label))
            } else if let range = line.range(of: "Title: "), !updates.isEmpty {
                let fields = line[range.upperBound...].components(separatedBy: ", ")
                updates[updates.count - 1].title = fields.first ?? updates[updates.count - 1].title
                updates[updates.count - 1].version = fields.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst("Version: ".count)) }
            }
        }
        return updates
    }
}

private struct BrewOutdated: Decodable {
    struct Package: Decodable {
        let name: String
        let currentVersion: String?
        let pinned: Bool?
        enum CodingKeys: String, CodingKey { case name, pinned; case currentVersion = "current_version" }
    }
    let formulae: [Package]
    let casks: [Package]
}

struct HomebrewProvider: UpdateProvider {
    static let readOnlyEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_ANALYTICS": "1"
    ]
    let id = "homebrew"
    let displayName = "Homebrew"
    let priority = 20

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let brew = context.executable(named: "brew") else {
            await context.logger.log(provider: displayName, "Homebrew no está instalado; se omite")
            return []
        }
        async let formulas = context.runner.run(Command(executable: brew, arguments: ["list", "--formula", "--versions"], environment: Self.readOnlyEnvironment))
        async let casks = context.cachedRun(Self.caskListCommand(brew))
        async let leaves = context.runner.run(Command(executable: brew, arguments: ["leaves", "--installed-on-request"], environment: Self.readOnlyEnvironment))
        let (formulaResult, caskResult, leavesResult) = await (formulas, casks, leaves)
        let requested = Set(leavesResult.stdout.split(separator: "\n").map(String.init))
        var formulaItems = Self.parseInstalled(formulaResult.stdout, kind: "formula", providerID: id, priority: priority)
        if leavesResult.succeeded {
            for index in formulaItems.indices where !requested.contains(formulaItems[index].name) {
                formulaItems[index].source = "Homebrew Formula · dependencia"
            }
        }
        let items = formulaItems + Self.parseInstalled(caskResult.stdout, kind: "cask", providerID: id, priority: priority)
        await context.logger.log(provider: displayName, "\(items.count) paquetes instalados")
        return items
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard !items.isEmpty, let brew = context.executable(named: "brew") else { return items }
        var refreshNote: String?
        if context.policy.refreshHomebrewIndex {
            let refresh = await context.runner.run(Command(executable: brew, arguments: ["update", "--quiet"], environment: Self.readOnlyEnvironment, timeout: 300))
            await context.logger.log(provider: displayName, "brew update exit=\(refresh.exitCode)")
            if !refresh.succeeded { refreshNote = "No se pudo refrescar el índice de Homebrew; resultados según metadatos locales" }
        }
        let arguments = ["outdated", "--json=v2"] + (context.policy.includeGreedyCasks ? ["--greedy"] : [])
        let result = await context.runner.run(Command(executable: brew, arguments: arguments, environment: Self.readOnlyEnvironment, timeout: 180))
        await context.logger.log(provider: displayName, "brew outdated exit=\(result.exitCode)")
        guard let outdated = try? JSONDecoder().decode(BrewOutdated.self, from: Data(result.stdout.utf8)) else {
            return items.map { var item = $0; item.status = .failed; item.notes = result.combinedOutput; return item }
        }
        var packages: [String: BrewOutdated.Package] = [:]
        for formula in outdated.formulae { packages["formula:\(formula.name)"] = formula }
        for cask in outdated.casks { packages["cask:\(cask.name)"] = cask }
        return items.map { original in
            var item = original
            let key = "\(item.metadata["kind"] ?? ""):\(item.metadata["token"] ?? "")"
            if let package = packages[key] {
                item.availableVersion = package.currentVersion
                item.status = .updateAvailable
                if package.pinned == true {
                    item.notes = "Fijado con brew pin; no se actualiza automáticamente"
                } else {
                    item.canUpdateAutomatically = true
                }
            } else {
                item.status = .current
            }
            return refreshNote.map { item.appendingNote($0) } ?? item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let brew = context.executable(named: "brew"),
              let token = item.metadata["token"], let kind = item.metadata["kind"] else { return nil }
        let arguments = kind == "cask"
            ? ["upgrade", "--cask", token] + (context.policy.includeGreedyCasks ? ["--greedy"] : [])
            : ["upgrade", "--formula", token]
        await context.logger.log(provider: displayName, "brew \(arguments.joined(separator: " "))")
        return await context.runner.run(Command(executable: brew, arguments: arguments, environment: Self.readOnlyEnvironment, timeout: 3600))
    }

    static func caskListCommand(_ brew: String) -> Command {
        Command(executable: brew, arguments: ["list", "--cask", "--versions"], environment: readOnlyEnvironment)
    }

    static func parseInstalled(_ text: String, kind: String, providerID: String, priority: Int) -> [UpdateItem] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return nil }
            let token = parts[0]
            return UpdateItem(
                id: "brew:\(kind):\(token)", providerID: providerID, name: token,
                category: kind == "cask" ? .applications : .development,
                installedVersion: parts.dropFirst().joined(separator: ", "),
                source: "Homebrew \(kind == "cask" ? "Cask" : "Formula")",
                updateMethod: kind == "cask" ? "brew upgrade --cask" : "brew upgrade",
                architecture: HostEnvironment.architecture,
                deduplicationKey: "brew-\(kind):\(token)", priority: priority,
                metadata: ["kind": kind, "token": token, MetadataKey.lock: "homebrew"]
            )
        }
    }
}

struct MacAppStoreProvider: UpdateProvider {
    let id = "mas"
    let displayName = "Mac App Store"
    let priority = 30

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let mas = context.executable(named: "mas") else {
            return Self.storeAppCount() > 0 ? installHelper(context: context) : []
        }
        let result = await context.runner.run(Command(executable: mas, arguments: ["list"], timeout: 120))
        guard result.succeeded else { return [failureItem(output: result.combinedOutput)] }
        return result.stdout.split(separator: "\n").compactMap { parseLine($0) }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard let mas = context.executable(named: "mas"), items.contains(where: { $0.metadata["storeID"] != nil }) else { return items }
        let result = await context.runner.run(Command(executable: mas, arguments: ["outdated"], timeout: 180))
        guard result.succeeded else {
            return items.map { var item = $0; item.status = .failed; item.notes = "App Store: \(result.combinedOutput)"; return item }
        }
        var outdated: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            if let item = parseLine(line), let storeID = item.metadata["storeID"] { outdated[storeID] = item.installedVersion }
        }
        return items.map { original in
            var item = original
            if let storeID = item.metadata["storeID"], let available = outdated[storeID] {
                item.availableVersion = available
                item.status = .updateAvailable
                item.canUpdateAutomatically = true
            } else {
                item.status = .current
            }
            return item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        if item.id == "mas:install", let brew = context.executable(named: "brew") {
            return await context.runner.run(Command(executable: brew, arguments: ["install", "mas"],
                                                    environment: HomebrewProvider.readOnlyEnvironment, timeout: 900))
        }
        guard let mas = context.executable(named: "mas"), let storeID = item.metadata["storeID"] else { return nil }
        return await context.runner.run(Command(executable: mas, arguments: ["upgrade", storeID], timeout: 3600))
    }

    /// Accepts `497799835  Xcode  (16.0)` and `497799835 Xcode (15.4 -> 16.0)`.
    func parseLine<S: StringProtocol>(_ line: S) -> UpdateItem? {
        let text = String(line)
        let pattern = #"^\s*(\d+)\s+(.+?)\s+\(([^)]+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(match.range(at: 1), in: text),
              let nameRange = Range(match.range(at: 2), in: text),
              let versionRange = Range(match.range(at: 3), in: text) else { return nil }
        let storeID = String(text[idRange])
        let rawVersion = String(text[versionRange])
        return UpdateItem(
            id: "mas:\(storeID)", providerID: id, name: String(text[nameRange]).trimmingCharacters(in: .whitespaces),
            category: .applications, installedVersion: rawVersion.components(separatedBy: " -> ").last ?? rawVersion,
            source: "Mac App Store", updateMethod: "mas upgrade", priority: priority,
            metadata: ["storeID": storeID, MetadataKey.openURL: "macappstore://showUpdatesPage", MetadataKey.lock: "mas"]
        )
    }

    /// Without `mas`, offer to install it (through Homebrew) so App Store apps can be updated from here.
    private func installHelper(context: ProviderContext) -> [UpdateItem] {
        let hasBrew = context.executable(named: "brew") != nil
        return [UpdateItem(
            id: "mas:install", providerID: id, name: "Instalar mas (App Store desde ActuchosMac)", category: .applications,
            status: hasBrew ? .unknown : .intervention, source: "Herramienta opcional",
            updateMethod: hasBrew ? "brew install mas" : "Instala Homebrew y después mas",
            canUpdateAutomatically: hasBrew,
            notes: "Tienes \(Self.storeAppCount()) apps de la App Store. Con mas podrás actualizarlas desde aquí.",
            priority: priority,
            metadata: [MetadataKey.onDemand: hasBrew ? "true" : "false", MetadataKey.lock: "homebrew",
                       MetadataKey.openURL: "macappstore://showUpdatesPage"]
        )]
    }

    private static func storeAppCount() -> Int {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { FileManager.default.fileExists(atPath: "/Applications/\($0)/Contents/_MASReceipt/receipt") }.count
    }

    private func failureItem(output: String) -> UpdateItem {
        UpdateItem(id: "mas:error", providerID: id, name: "Mac App Store", category: .applications, status: .failed,
                   source: "mas", updateMethod: "mas", notes: output, priority: priority,
                   metadata: [MetadataKey.openURL: "macappstore://showUpdatesPage"])
    }
}
