import Foundation

struct NVMProvider: UpdateProvider {
    let id = "nvm"
    let displayName = "Node / NVM"
    let priority = 40

    static func nvmDirectory(homeDirectory: String) -> String {
        ProcessInfo.processInfo.environment["NVM_DIR"] ?? "\(homeDirectory)/.nvm"
    }

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let nvmDirectory = Self.nvmDirectory(homeDirectory: context.homeDirectory)
        let versionsDirectory = "\(nvmDirectory)/versions/node"
        guard FileManager.default.fileExists(atPath: "\(nvmDirectory)/nvm.sh") else { return [] }
        let activeNodePath = await context.shell.path(for: "node") ?? ""
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory)) ?? [])
            .filter { $0.hasPrefix("v") && SemanticVersion($0) != nil }
            .sorted { SemanticVersion($0)! < SemanticVersion($1)! }
        return versions.map { version in
            let installed = String(version.dropFirst())
            let isActive = activeNodePath.contains("/\(version)/")
            let major = installed.split(separator: ".").first.map(String.init) ?? installed
            // The active item keeps a major-based id so it still matches after `nvm install <major>`.
            let itemID = isActive ? "nvm:active:\(major)" : "nvm:\(version)"
            return UpdateItem(
                id: itemID, providerID: id, name: isActive ? "Node (activo)" : "Node", category: .development,
                installedVersion: installed, source: "NVM", updateMethod: "nvm install <major>",
                path: context.locator.displayPath("\(versionsDirectory)/\(version)/bin/node"), architecture: context.architecture,
                notes: isActive ? "Versión que usa tu shell de inicio" : "Versión paralela conservada; no se comprueba",
                priority: priority, metadata: ["active": isActive ? "true" : "false", MetadataKey.lock: "node"]
            )
        }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard let active = items.first(where: { $0.metadata["active"] == "true" }),
              let installed = active.installedVersion,
              let major = installed.split(separator: ".").first.map(String.init), major.allSatisfy(\.isNumber) else {
            return items.map { var item = $0; item.status = .current; return item }
        }
        let script = #". "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1; nvm version-remote "$1""#
        let result = await context.runner.run(nvmCommand(script: script, arguments: [major], context: context, timeout: 120))
        let remote = result.stdout.split(separator: "\n").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "v \t")) } ?? ""
        return items.map { original in
            var item = original
            guard item.metadata["active"] == "true" else { item.status = .current; return item }
            if !result.succeeded || SemanticVersion(remote) == nil {
                item.status = .unknown
                item.notes = "No se pudo consultar la última \(major).x: \(result.combinedOutput)"
            } else if SemanticVersion.isNewer(remote, than: installed) {
                item.status = .updateAvailable
                item.availableVersion = remote
                item.canUpdateAutomatically = true
                item.metadata["major"] = major
            } else {
                item.status = .current
            }
            return item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let major = item.metadata["major"], major.allSatisfy(\.isNumber),
              let installed = item.installedVersion, installed.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let script = #". "$NVM_DIR/nvm.sh" >/dev/null 2>&1; nvm install "$1" --reinstall-packages-from="$2""#
        return await context.runner.run(nvmCommand(script: script, arguments: [major, installed], context: context, timeout: 1800))
    }

    /// NVM is a shell function: run a fixed script and pass inventory data only as positional arguments.
    private func nvmCommand(script: String, arguments: [String], context: ProviderContext, timeout: TimeInterval) -> Command {
        Command(executable: "/bin/bash", arguments: ["-c", script, "actuchosmac"] + arguments,
                environment: ["NVM_DIR": Self.nvmDirectory(homeDirectory: context.homeDirectory)], timeout: timeout)
    }
}

struct NodePackagesProvider: UpdateProvider {
    let id = "node-packages"
    let displayName = "npm / Corepack"
    let priority = 45

    private static let tools = [("npm", "npm"), ("corepack", "Corepack"), ("pnpm", "pnpm"), ("yarn", "Yarn")]

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let resolved = await context.shell.paths(for: Self.tools.map(\.0))
        let found = Self.tools.compactMap { tool, name -> (String, String, String)? in
            guard let path = resolved[tool] ?? context.executable(named: tool) else { return nil }
            return (tool, name, path)
        }
        return await concurrentMap(found, limit: 4) { tool, name, path in
            let result = await context.runner.run(Command(executable: path, arguments: ["--version"], timeout: 20))
            let isHomebrew = path.contains("/Cellar/") || path.contains("/homebrew/")
            return UpdateItem(
                id: "node-tool:\(tool)", providerID: id, name: name, category: .development,
                installedVersion: result.stdout.split(separator: "\n").first.map(String.init),
                status: result.succeeded ? .checking : .failed,
                source: isHomebrew ? "Homebrew" : path.contains("/.nvm/") ? "NVM / Corepack" : "PATH",
                updateMethod: isHomebrew ? "brew upgrade node" : tool == "pnpm" ? "corepack install --global" : "npm install --global",
                path: context.locator.displayPath(path),
                notes: result.succeeded ? nil : result.combinedOutput,
                priority: priority,
                metadata: ["tool": tool, "actualPath": path, "homebrew": isHomebrew ? "true" : "false", MetadataKey.lock: "node"]
            )
        }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        await concurrentMap(items, limit: 4) { item in await checkOne(item, context: context) }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let tool = item.metadata["tool"], let available = item.availableVersion,
              SemanticVersion(available) != nil, item.metadata["homebrew"] != "true" else { return nil }
        switch tool {
        case "npm", "corepack":
            guard let npm = siblingExecutable(named: "npm", item: item, context: context) else { return nil }
            return await context.runner.run(Command(executable: npm, arguments: ["install", "--global", "\(tool)@\(available)"], timeout: 1200))
        case "pnpm":
            guard let corepack = siblingExecutable(named: "corepack", item: item, context: context) else { return nil }
            return await context.runner.run(Command(executable: corepack, arguments: ["install", "--global", "pnpm@\(available)"], timeout: 600))
        default:
            return nil
        }
    }

    private func checkOne(_ original: UpdateItem, context: ProviderContext) async -> UpdateItem {
        var item = original
        guard item.status != .failed else { return item }
        guard let tool = item.metadata["tool"], let installed = item.installedVersion,
              let major = SemanticVersion(installed)?.components.first,
              let npm = siblingExecutable(named: "npm", item: item, context: context) else {
            item.status = .unknown
            return item
        }
        if tool == "yarn" && major < 2 {
            item.status = .intervention
            item.notes = "Yarn Classic detectado; la migración a Yarn moderno es manual"
            return item
        }
        if tool == "yarn" {
            item.status = .unknown
            item.notes = "Yarn moderno se fija por proyecto con Corepack"
            return item
        }
        let result = await context.runner.run(Command(executable: npm, arguments: ["view", "\(tool)@\(major)", "version", "--json"], timeout: 90))
        guard result.succeeded else {
            item.status = .unknown
            item.notes = result.combinedOutput
            return item
        }
        let data = Data(result.stdout.utf8)
        let versions = (try? JSONDecoder().decode([String].self, from: data))
            ?? (try? JSONDecoder().decode(String.self, from: data)).map { [$0] } ?? []
        guard let available = versions.compactMap({ value in SemanticVersion(value).map { ($0, value) } }).max(by: { $0.0 < $1.0 })?.1 else {
            item.status = .unknown
            return item
        }
        item.availableVersion = available
        if SemanticVersion.isNewer(available, than: installed) {
            item.status = .updateAvailable
            if item.metadata["homebrew"] == "true" {
                item.notes = "Pertenece a la fórmula node de Homebrew; se actualiza con ella"
            } else {
                item.canUpdateAutomatically = true
            }
        } else {
            item.status = .current
        }
        return item
    }

    private func siblingExecutable(named name: String, item: UpdateItem, context: ProviderContext) -> String? {
        if let actualPath = item.metadata["actualPath"] {
            let sibling = URL(fileURLWithPath: actualPath).deletingLastPathComponent().appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return context.executable(named: name)
    }
}

struct PythonProvider: UpdateProvider {
    let id = "python"
    let displayName = "Python"
    let priority = 50

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let candidates = Self.interpreters(context: context).filter { !Self.isHomebrew($0) }
        let items = await concurrentMap(candidates, limit: 4) { path -> UpdateItem? in
            let result = await context.runner.run(Command(executable: path, arguments: ["--version"], timeout: 15))
            guard result.succeeded else { return nil }
            let version = result.combinedOutput.replacingOccurrences(of: "Python ", with: "")
            let isSystem = path.hasPrefix("/usr/bin/") || path.contains("/CommandLineTools/") || path.contains("/Xcode")
            return UpdateItem(
                id: "python:\(path)", providerID: id, name: "Python \(version.split(separator: ".").prefix(2).joined(separator: "."))",
                category: .development, installedVersion: version, status: isSystem ? .current : .unknown,
                source: Self.source(path: path), updateMethod: isSystem ? "Software Update (Command Line Tools)" : "Gestor de origen",
                path: context.locator.displayPath(path), architecture: context.architecture,
                notes: isSystem ? "Se actualiza con las Command Line Tools / Xcode" : "Los entornos venv y dependencias de proyectos no se modifican",
                deduplicationKey: "runtime:python:\(path)", priority: priority
            )
        }
        return items.compactMap { $0 }
    }

    /// Every distinct Python 3 interpreter: PATH, Homebrew versioned binaries, pyenv, python.org, Command Line Tools.
    static func interpreters(context: ProviderContext) -> [String] {
        var candidates = context.locator.all("python3")
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            candidates += names.filter { $0.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil }
                .map { URL(fileURLWithPath: "\(directory)/\($0)").resolvingSymlinksInPath().path }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func isHomebrew(_ path: String) -> Bool {
        path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/")
    }

    static func source(path: String) -> String {
        if isHomebrew(path) { return "Homebrew" }
        if path.hasPrefix("/usr/bin/") || path.contains("/CommandLineTools/") || path.contains("/Xcode") { return "macOS / Apple" }
        if path.contains("/.pyenv/") { return "pyenv" }
        if path.hasPrefix("/Library/Frameworks/Python.framework/") { return "python.org" }
        return "Instalación global detectada"
    }
}

struct DotNetProvider: UpdateProvider {
    let id = "dotnet"
    let displayName = ".NET"
    let priority = 52

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let dotnet = context.executable(named: "dotnet", additionalPaths: ["/usr/local/share/dotnet/dotnet"]) else { return [] }
        async let sdkResult = context.runner.run(Command(executable: dotnet, arguments: ["--list-sdks"], timeout: 30))
        async let runtimeResult = context.runner.run(Command(executable: dotnet, arguments: ["--list-runtimes"], timeout: 30))
        async let ownershipResult = isHomebrewOwned(context: context)
        let (sdks, runtimes, homebrewOwned) = await (sdkResult, runtimeResult, ownershipResult)
        let source = homebrewOwned ? "Homebrew Cask" : "Instalador de Microsoft"
        let method = homebrewOwned ? "brew upgrade --cask dotnet-sdk" : "Instalador de Microsoft"
        let notes = homebrewOwned ? "La disponibilidad se comprueba en el proveedor Homebrew" : "Las versiones paralelas se conservan"

        var items = Self.parse(sdks.stdout).map { entry in
            UpdateItem(id: "dotnet:sdk:\(entry.version)", providerID: id, name: ".NET SDK \(entry.version.split(separator: ".").first ?? "")",
                       category: .development, installedVersion: entry.version, status: .unknown, source: source,
                       updateMethod: method, path: entry.path, architecture: context.architecture, notes: notes, priority: priority)
        }
        items += Self.parse(runtimes.stdout).map { entry in
            UpdateItem(id: "dotnet:runtime:\(entry.name):\(entry.version)", providerID: id, name: entry.name,
                       category: .development, installedVersion: entry.version, status: .unknown, source: source,
                       updateMethod: "Se actualiza con el SDK", path: entry.path, architecture: context.architecture,
                       notes: notes, priority: priority)
        }
        return items
    }

    /// Parses `8.0.100 [/usr/local/share/dotnet/sdk]` and `Microsoft.NETCore.App 8.0.0 [/path]`.
    static func parse(_ output: String) -> [(name: String, version: String, path: String?)] {
        output.split(separator: "\n").compactMap { line in
            let bracket = line.firstIndex(of: "[")
            let head = (bracket.map { line[..<$0] } ?? line[...]).split(separator: " ").map(String.init)
            let path = bracket.map { line[line.index(after: $0)...].trimmingCharacters(in: CharacterSet(charactersIn: "] ")) }
            switch head.count {
            case 1: return (".NET SDK", head[0], path)
            case 2...: return (head[0], head[1], path)
            default: return nil
            }
        }
    }

    private func isHomebrewOwned(context: ProviderContext) async -> Bool {
        guard let brew = context.executable(named: "brew") else { return false }
        let result = await context.cachedRun(HomebrewProvider.caskListCommand(brew))
        return result.stdout.split(separator: "\n").contains { $0.hasPrefix("dotnet") }
    }
}

struct OllamaProvider: UpdateProvider {
    static let fallbackDownload = URL(string: "https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip")!
    let id = "ollama"
    let displayName = "Ollama"
    let priority = 60

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let appPath = context.locator.applications(named: ["Ollama"]).first
        let bundled = appPath.map { ["\($0)/Contents/Resources/ollama"] } ?? []
        guard let ollama = context.executable(named: "ollama", additionalPaths: bundled) else { return [] }
        async let versionResult = context.runner.run(Command(executable: ollama, arguments: ["--version"], timeout: 20))
        async let listResult = context.runner.run(Command(executable: ollama, arguments: ["list"], timeout: 30))
        let (version, list) = await (versionResult, listResult)
        let installed = LatestRelease.firstVersion(in: version.combinedOutput)

        var metadata = [MetadataKey.lock: "ollama"]
        metadata[MetadataKey.appPath] = appPath
        var items = [UpdateItem(
            id: "ollama:app", providerID: id, name: "Ollama", category: .artificialIntelligence,
            installedVersion: installed, status: installed == nil ? .failed : .selfUpdating,
            source: appPath == nil ? "Binario local" : "Aplicación Ollama", updateMethod: "Actualizador propio de Ollama",
            path: context.locator.displayPath(appPath ?? ollama), architecture: context.architecture,
            notes: installed == nil ? version.combinedOutput : "Se actualiza desde la propia aplicación",
            deduplicationKey: "ollama:app", priority: priority, metadata: metadata
        )]

        let allowPulls = context.policy.allowOllamaModelPulls
        for line in list.stdout.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4 else { continue }
            let name = columns[0]
            let size = columns.firstIndex(where: { $0 == "GB" || $0 == "MB" }).map { "\(columns[$0 - 1]) \(columns[$0])" }
            items.append(UpdateItem(
                id: "ollama:model:\(name)", providerID: id, name: name, category: .artificialIntelligence,
                installedVersion: columns[1], status: .unknown, source: "Modelo Ollama", updateMethod: "ollama pull",
                canUpdateAutomatically: allowPulls,
                notes: "Tamaño local \(size ?? "desconocido"). Ollama no permite saber si hay versión nueva sin descargarla",
                priority: priority,
                metadata: ["model": name, MetadataKey.onDemand: allowPulls ? "true" : "false", MetadataKey.lock: "ollama"]
            ))
        }
        return items
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard context.policy.checkVendorFeeds,
              let index = items.firstIndex(where: { $0.id == "ollama:app" && $0.status == .selfUpdating }),
              let installed = items[index].installedVersion,
              let latest = await LatestRelease.gitHub("ollama/ollama", context: context) else { return items }
        var result = items
        guard SemanticVersion.isNewer(latest, than: installed) else {
            result[index].status = .current
            result[index].notes = "Comprobado contra las releases oficiales"
            return result
        }
        result[index].status = .updateAvailable
        result[index].availableVersion = latest
        if let appPath = result[index].appBundlePath {
            let entry = await context.caskCatalog()?.entry(forAppNamed: "Ollama.app")
            let download = entry.flatMap { entry in
                SemanticVersion.isNewer(CaskCatalog.marketingVersion(entry.version), than: installed)
                    ? URL(string: entry.url).map { DirectDownload(url: $0, sha256: entry.sha256) } : nil
            } ?? DirectDownload(url: Self.fallbackDownload)
            AppInstaller.prepare(&result[index], appPath: appPath, download: download)
        }
        result[index].notes = result[index].canUpdateAutomatically
            ? "Se descargará la release oficial y se verificará su firma" : "Abre Ollama para instalar la actualización"
        return result
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        if item.id == "ollama:app" { return item.canUpdateAutomatically ? await AppInstaller.install(item, context: context) : nil }
        guard let model = item.metadata["model"], model.range(of: #"^[A-Za-z0-9._:/-]+$"#, options: .regularExpression) != nil,
              let ollama = context.executable(named: "ollama", additionalPaths: ["/Applications/Ollama.app/Contents/Resources/ollama"]) else { return nil }
        return await context.runner.run(Command(executable: ollama, arguments: ["pull", model], timeout: 7200))
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        let fresh = await detect(context: context)
        var result: [String: UpdateItem] = [:]
        for item in items {
            result[item.id] = item.id == "ollama:app" ? AppInstaller.observe(item) : fresh.first { $0.id == item.id }
        }
        return result
    }
}

struct EditorProvider: UpdateProvider {
    let id = "editors"
    let displayName = "Editores"
    let priority = 65

    private struct Definition: Sendable {
        let appName: String
        let cli: String
        /// Channel of Microsoft's VS Code update service, when the editor uses it.
        var vscodeQuality: String?
    }

    private static let definitions = [
        Definition(appName: "Visual Studio Code", cli: "code", vscodeQuality: "stable"),
        Definition(appName: "Visual Studio Code - Insiders", cli: "code-insiders", vscodeQuality: "insider"),
        Definition(appName: "Cursor", cli: "cursor"),
        Definition(appName: "Windsurf", cli: "windsurf"),
        Definition(appName: "VSCodium", cli: "codium"),
        Definition(appName: "Antigravity", cli: "antigravity")
    ]

    func detect(context: ProviderContext) async -> [UpdateItem] {
        var items: [UpdateItem] = []
        for definition in Self.definitions {
            guard let appPath = context.locator.applications(named: [definition.appName]).first else { continue }
            let bundledCLI = "\(appPath)/Contents/Resources/app/bin/\(definition.cli)"
            let cliPath = FileManager.default.isExecutableFile(atPath: bundledCLI) ? bundledCLI : context.executable(named: definition.cli)
            let version = Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            var metadata = [MetadataKey.appPath: appPath, "appName": definition.appName]
            metadata["vscodeQuality"] = definition.vscodeQuality
            items.append(UpdateItem(
                id: "editor:\(definition.appName)", providerID: id, name: definition.appName, category: .editors,
                installedVersion: version, status: .selfUpdating, source: "Aplicación macOS", updateMethod: "Actualizador propio",
                path: context.locator.displayPath(appPath), architecture: CodeSignature.architectures(ofBundleAt: appPath),
                signature: CodeSignature.info(forAppAt: appPath).authority,
                notes: "Se actualiza desde el propio editor", priority: priority, metadata: metadata
            ))
            guard let cliPath else { continue }
            let result = await context.runner.run(Command(executable: cliPath, arguments: ["--list-extensions", "--show-versions"], timeout: 60))
            let extensions = result.stdout.split(separator: "\n").map(String.init).filter { $0.contains("@") }
            guard result.succeeded, !extensions.isEmpty else { continue }
            let preview = extensions.prefix(6).joined(separator: ", ") + (extensions.count > 6 ? "…" : "")
            items.append(UpdateItem(
                id: "editor-extensions:\(definition.appName)", providerID: id, name: "Extensiones de \(definition.appName)",
                category: .editors, installedVersion: "\(extensions.count) instaladas", status: .unknown,
                source: "CLI \(definition.cli)", updateMethod: "\(definition.cli) --update-extensions",
                canUpdateAutomatically: true, path: context.locator.displayPath(cliPath),
                notes: "La CLI no informa de versiones remotas; puedes forzar la actualización. \(preview)",
                priority: priority, metadata: ["cli": cliPath, MetadataKey.onDemand: "true", MetadataKey.lock: "editor:\(definition.appName)"]
            ))
        }
        return items
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard context.policy.checkVendorFeeds || context.policy.useCaskCatalog else { return items }
        return await concurrentMap(items, limit: 4) { item in
            guard item.metadata["cli"] == nil, let appPath = item.appBundlePath, let installed = item.installedVersion else { return item }
            var checked = item
            var latest: (version: String, download: DirectDownload?)?
            if let quality = item.metadata["vscodeQuality"], context.policy.checkVendorFeeds {
                latest = await Self.vscodeRelease(quality: quality, context: context)
            } else if let entry = await context.caskCatalog()?.entry(forAppNamed: "\(item.metadata["appName"] ?? item.name).app") {
                let download = entry.installsWithPackage ? nil : URL(string: entry.url).map { DirectDownload(url: $0, sha256: entry.sha256) }
                latest = (CaskCatalog.marketingVersion(entry.version), download)
            }
            guard let latest else { return item }
            if SemanticVersion.isNewer(latest.version, than: installed) {
                checked.status = .updateAvailable
                checked.availableVersion = latest.version
                AppInstaller.prepare(&checked, appPath: appPath, download: latest.download)
                checked.notes = checked.canUpdateAutomatically
                    ? "Se descargará la versión oficial y se verificará su firma" : "Abre el editor para actualizarlo"
            } else {
                checked.status = .current
                checked.notes = "Comprobado contra la versión publicada"
            }
            return checked
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        if let cli = item.metadata["cli"] {
            guard FileManager.default.isExecutableFile(atPath: cli) else { return nil }
            return await context.runner.run(Command(executable: cli, arguments: ["--update-extensions"], timeout: 900))
        }
        return item.canUpdateAutomatically ? await AppInstaller.install(item, context: context) : nil
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        var result: [String: UpdateItem] = [:]
        for item in items {
            if item.metadata["cli"] != nil {
                var observed = item
                observed.status = .unknown
                result[item.id] = observed
            } else {
                result[item.id] = AppInstaller.observe(item)
            }
        }
        return result
    }

    /// Microsoft's update service: `{"productVersion": "1.95.3", "url": "…zip", "sha256hash": "…"}`.
    private static func vscodeRelease(quality: String, context: ProviderContext) async -> (version: String, download: DirectDownload?)? {
        let platform = HostEnvironment.architecture == "arm64" ? "darwin-arm64" : "darwin"
        guard let url = URL(string: "https://update.code.visualstudio.com/api/update/\(platform)/\(quality)/latest"),
              let data = try? await context.http.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["productVersion"] as? String else { return nil }
        let download = (json["url"] as? String).flatMap(URL.init(string:)).map { DirectDownload(url: $0, sha256: json["sha256hash"] as? String) }
        return (version, download)
    }
}

struct EcosystemDiscoveryProvider: UpdateProvider {
    let id = "ecosystem-discovery"
    let displayName = "Runtimes y gestores"
    let priority = 75

    private enum Latest: Sendable {
        case gitHub(String)
        case goToolchain
        case composer
    }

    private struct Definition: Sendable {
        let command: String
        let name: String
        var arguments = ["--version"]
        var latest: Latest?
        /// Arguments of the tool's own documented self-update command.
        var updateArguments: [String]?
        var manualURL: String?
    }

    private static let definitions = [
        Definition(command: "fnm", name: "fnm", latest: .gitHub("Schniz/fnm"), manualURL: "https://github.com/Schniz/fnm#installation"),
        Definition(command: "volta", name: "Volta", latest: .gitHub("volta-cli/volta"), manualURL: "https://docs.volta.sh/guide/getting-started"),
        Definition(command: "pyenv", name: "pyenv", latest: .gitHub("pyenv/pyenv"), manualURL: "https://github.com/pyenv/pyenv#upgrading"),
        Definition(command: "uv", name: "uv", latest: .gitHub("astral-sh/uv"), updateArguments: ["self", "update"]),
        Definition(command: "php", name: "PHP"),
        Definition(command: "composer", name: "Composer", latest: .composer, updateArguments: ["self-update"]),
        Definition(command: "ruby", name: "Ruby"),
        Definition(command: "rbenv", name: "rbenv", latest: .gitHub("rbenv/rbenv"), manualURL: "https://github.com/rbenv/rbenv#upgrading"),
        Definition(command: "go", name: "Go", arguments: ["version"], latest: .goToolchain, manualURL: "https://go.dev/dl/"),
        Definition(command: "java", name: "Java / JDK", arguments: ["-version"]),
        Definition(command: "bun", name: "Bun", latest: .gitHub("oven-sh/bun"), updateArguments: ["upgrade"]),
        Definition(command: "deno", name: "Deno", latest: .gitHub("denoland/deno"), updateArguments: ["upgrade"]),
        Definition(command: "pod", name: "CocoaPods"),
        Definition(command: "mvn", name: "Maven"),
        Definition(command: "gradle", name: "Gradle")
    ]

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let resolved = await context.shell.paths(for: Self.definitions.map(\.command) + ["node"])
        let candidates = Self.definitions.compactMap { definition -> (Definition, String)? in
            let shellPath = resolved[definition.command].flatMap { context.locator.isUsable($0) ? $0 : nil }
            guard let path = shellPath ?? context.executable(named: definition.command) else { return nil }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return Self.isCoveredElsewhere(real, context: context) ? nil : (definition, real)
        }
        var items = await concurrentMap(candidates, limit: 6) { definition, path in
            await detect(definition, path: path, context: context)
        }.compactMap { $0 }
        items += await discoverNodeInstallations(activePath: resolved["node"], context: context)

        let sdkman = "\(context.homeDirectory)/.sdkman"
        if FileManager.default.fileExists(atPath: sdkman) {
            items.append(UpdateItem(
                id: "manager:sdkman", providerID: id, name: "SDKMAN", category: .development, status: .unknown,
                source: "~/.sdkman", updateMethod: "sdk selfupdate", path: "~/.sdkman", architecture: context.architecture,
                notes: "Instalación detectada; actualízalo con sdk selfupdate", priority: priority
            ))
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard context.policy.checkVendorFeeds else { return items }
        return await concurrentMap(items, limit: 6) { item in
            guard let command = item.metadata["tool"],
                  let definition = Self.definitions.first(where: { $0.command == command }),
                  let latestSource = definition.latest,
                  let latest = await Self.latestVersion(latestSource, context: context) else { return item }
            var checked = item
            checked.availableVersion = latest
            if SemanticVersion.isNewer(latest, than: item.installedVersion) {
                checked.status = .updateAvailable
                checked.canUpdateAutomatically = definition.updateArguments != nil
                checked.updateMethod = definition.updateArguments.map { "\(command) \($0.joined(separator: " "))" } ?? checked.updateMethod
                checked.metadata[MetadataKey.openURL] = definition.manualURL
                checked.notes = checked.canUpdateAutomatically ? "Usa el comando de autoactualización oficial" : "Sigue las instrucciones oficiales para actualizar"
            } else {
                checked.status = .current
                checked.notes = "Comprobado contra la última versión publicada"
            }
            return checked
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let command = item.metadata["tool"], let path = item.metadata["toolPath"],
              let arguments = Self.definitions.first(where: { $0.command == command })?.updateArguments else { return nil }
        return await context.runner.run(Command(executable: path, arguments: arguments, timeout: 900))
    }

    private func detect(_ definition: Definition, path: String, context: ProviderContext) async -> UpdateItem? {
        let result = await context.runner.run(Command(executable: path, arguments: definition.arguments, timeout: 30))
        guard result.succeeded else { return nil }
        let firstLine = result.combinedOutput.split(separator: "\n").first.map(String.init)
        return UpdateItem(
            id: "tool:\(definition.command):\(path)", providerID: id, name: definition.name, category: .development,
            installedVersion: LatestRelease.firstVersion(in: firstLine ?? "") ?? firstLine,
            status: definition.latest == nil ? .unknown : .checking,
            source: Self.classify(path: path), updateMethod: "Gestor de origen",
            path: context.locator.displayPath(path), architecture: context.architecture,
            notes: definition.latest == nil ? "Detectado; no hay una fuente oficial de versiones que consultar" : nil,
            priority: priority, metadata: ["tool": definition.command, "toolPath": path, MetadataKey.lock: "tool:\(definition.command)"]
        )
    }

    private static func latestVersion(_ source: Latest, context: ProviderContext) async -> String? {
        switch source {
        case .gitHub(let repository):
            return await LatestRelease.gitHub(repository, context: context)
        case .goToolchain:
            guard let url = URL(string: "https://go.dev/VERSION?m=text"), let data = try? await context.http.data(from: url) else { return nil }
            return LatestRelease.firstVersion(in: String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "")
        case .composer:
            guard let url = URL(string: "https://getcomposer.org/versions"), let data = try? await context.http.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stable = json["stable"] as? [[String: Any]] else { return nil }
            return stable.first?["version"] as? String
        }
    }

    /// Node installations not owned by NVM or Homebrew (Volta, fnm, the official installer…).
    private func discoverNodeInstallations(activePath: String?, context: ProviderContext) async -> [UpdateItem] {
        let activeReal = activePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let paths = context.locator.all("node").filter { !Self.isCoveredElsewhere($0, context: context) }
        let items = await concurrentMap(paths, limit: 4) { path -> UpdateItem? in
            let result = await context.runner.run(Command(executable: path, arguments: ["--version"], timeout: 20))
            guard result.succeeded else { return nil }
            let isActive = activeReal == path
            return UpdateItem(
                id: "runtime:node:\(path)", providerID: id, name: isActive ? "Node (activo en shell)" : "Node (instalación adicional)",
                category: .development, installedVersion: result.stdout.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                status: .unknown, source: Self.classify(path: path), updateMethod: "Gestor de origen",
                path: context.locator.displayPath(path), architecture: context.architecture,
                notes: isActive ? "Versión que usa tu shell de inicio" : "Se conserva; no se modifica implícitamente",
                priority: priority
            )
        }
        return items.compactMap { $0 }
    }

    /// Homebrew formulae, NVM versions and rustup toolchains already have dedicated providers.
    private static func isCoveredElsewhere(_ path: String, context: ProviderContext) -> Bool {
        path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") || path.contains("/.cargo/") || path.contains("/.rustup/")
            || path.hasPrefix(NVMProvider.nvmDirectory(homeDirectory: context.homeDirectory) + "/")
    }

    private static func classify(path: String) -> String {
        if path.contains("/.volta/") { return "Volta" }
        if path.contains("/fnm") { return "fnm" }
        if path.contains("/.pyenv/") { return "pyenv" }
        if path.contains("/.sdkman/") { return "SDKMAN" }
        if path.contains("/.bun/") { return "Instalador de Bun" }
        if path.contains("/.deno/") { return "Instalador de Deno" }
        if path.hasPrefix("/usr/bin/") { return "macOS / Apple" }
        if path.hasPrefix("/Library/") || path.hasPrefix("/usr/local/go/") { return "Instalador oficial" }
        return "Instalación global detectada"
    }
}
