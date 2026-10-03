import Foundation

struct ApplicationInventoryProvider: UpdateProvider {
    let id = InventoryReconciler.applicationsProviderID
    let displayName = "Aplicaciones macOS"
    let priority = 80

    private enum Key {
        static let feedURL = "sparkleFeed"
        static let electronConfig = "electronConfig"
        static let build = "build"
        static let checkable = "checkable"
    }

    private struct Classification {
        var source: String
        var method: String
        var status: UpdateStatus
        var category: UpdateCategory = .applications
        var notes: String?
        var metadata: [String: String] = [:]
    }

    // MARK: Detect (local only, fast)

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let roots = ["/Applications", "\(context.homeDirectory)/Applications", "/System/Applications"]
        async let caskApps = installedCaskApplications(context: context)
        let paths = applicationPaths(roots: roots)
        let casks = await caskApps
        let items = await concurrentMap(paths, limit: 8) { path in inspect(path: path, caskApps: casks, context: context) }
        await context.logger.log(provider: displayName, "\(items.count) aplicaciones encontradas")
        return items
    }

    private func inspect(path: String, caskApps: [String: String], context: ProviderContext) -> UpdateItem {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier ?? "path:\(path)"
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let isSystem = path.hasPrefix("/System/")
        let signature = isSystem ? CodeSignature.Info(teamID: nil, authority: "Apple (sistema)") : CodeSignature.info(forAppAt: path)

        var classification = classify(path: path, bundleID: bundle?.bundleIdentifier, info: info, caskApps: caskApps)
        var metadata = classification.metadata
        metadata[MetadataKey.bundleID] = bundleID
        metadata[MetadataKey.appPath] = path
        metadata[MetadataKey.teamID] = signature.teamID
        metadata[MetadataKey.edPublicKey] = info["SUPublicEDKey"] as? String
        metadata[Key.build] = build
        if metadata[Key.checkable] == "true" && classification.status != .unmanaged { classification.status = .checking }

        let buildNote = build.flatMap { $0 != version ? "Build \($0)" : nil }
        let notes = [buildNote, classification.notes].compactMap { $0 }.joined(separator: " · ")
        return UpdateItem(
            id: "app:\(bundleID):\(path)", providerID: id, name: name, category: classification.category,
            installedVersion: version, status: classification.status, source: classification.source,
            updateMethod: classification.method, requiresAdmin: isSystem, path: context.locator.displayPath(path),
            architecture: CodeSignature.architectures(ofBundleAt: path), signature: signature.authority,
            notes: notes.isEmpty ? nil : notes, deduplicationKey: "bundle:\(bundleID)", priority: priority, metadata: metadata
        )
    }

    // MARK: Check (network: vendor feeds and Homebrew's catalog)

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        let candidates = items.contains { $0.metadata[Key.checkable] == "true" }
        let catalog = candidates ? await context.caskCatalog() : nil
        return await concurrentMap(items, limit: 8) { item in
            guard item.metadata[Key.checkable] == "true" else { return item }
            return await checkOne(item, catalog: catalog, context: context)
        }
    }

    private func checkOne(_ original: UpdateItem, catalog: CaskCatalog?, context: ProviderContext) async -> UpdateItem {
        var item = original
        guard let appPath = item.appBundlePath else { return item }
        let fallbackStatus: UpdateStatus = original.category == .unmanaged ? .unmanaged : .selfUpdating

        var result: VendorFeedResult?
        if context.policy.checkVendorFeeds {
            if let feed = item.metadata[Key.feedURL] {
                result = await SparkleFeed.check(feedURL: feed, installedBuild: item.metadata[Key.build],
                                                 installedVersion: item.installedVersion, context: context)
            } else if let configPath = item.metadata[Key.electronConfig],
                      let configuration = try? String(contentsOfFile: configPath, encoding: .utf8) {
                result = await ElectronUpdaterFeed.check(configuration: configuration, installedVersion: item.installedVersion, context: context)
            }
        }
        var origin = "feed del fabricante"
        if result?.isConclusive != true, let catalog, let entry = catalog.entry(forAppNamed: URL(fileURLWithPath: appPath).lastPathComponent) {
            origin = "catálogo de Homebrew (\(entry.token))"
            let remote = CaskCatalog.marketingVersion(entry.version)
            if SemanticVersion(remote) == nil || SemanticVersion(item.installedVersion ?? "") == nil {
                result = .unavailable("El catálogo de Homebrew usa un formato de versión no comparable")
            } else if SemanticVersion.isNewer(remote, than: item.installedVersion) {
                let download = entry.installsWithPackage ? nil : URL(string: entry.url).map { DirectDownload(url: $0, sha256: entry.sha256) }
                result = .updateAvailable(version: remote, download: download)
                if entry.installsWithPackage, let homepage = entry.homepage { item.metadata[MetadataKey.openURL] = homepage }
            } else {
                result = .current(remote)
            }
            item.category = .applications
            item.source = item.source == "Instalación manual o desconocida" ? "Instalación manual" : item.source
        }

        switch result {
        case .updateAvailable(let version, let download):
            item.status = .updateAvailable
            item.availableVersion = version
            AppInstaller.prepare(&item, appPath: appPath, download: download)
            item.notes = item.canUpdateAutomatically
                ? "Se descargará del \(origin) y se verificará firma y desarrollador antes de instalar"
                : "Abre la aplicación para instalar la actualización"
        case .current:
            item.status = .current
            item.notes = "Comprobado con el \(origin)"
        case .unavailable(let reason):
            item.status = fallbackStatus
            item.notes = reason
        case nil:
            item.status = fallbackStatus
        }
        return item
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard item.canUpdateAutomatically else { return nil }
        return await AppInstaller.install(item, context: context)
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        var result: [String: UpdateItem] = [:]
        for item in items { result[item.id] = AppInstaller.observe(item) }
        return result
    }

    // MARK: Discovery helpers

    private func applicationPaths(roots: [String]) -> [String] {
        var result = Set<String>()
        let manager = FileManager.default
        for root in roots where manager.fileExists(atPath: root) {
            guard let enumerator = manager.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "app" {
                    result.insert(url.resolvingSymlinksInPath().path)
                    enumerator.skipDescendants()
                }
            }
        }
        return result.sorted()
    }

    /// Maps `Firefox.app` → `firefox` for every installed cask, so bundles can be attributed to Homebrew.
    private func installedCaskApplications(context: ProviderContext) async -> [String: String] {
        guard let brew = context.executable(named: "brew") else { return [:] }
        let result = await context.cachedRun(Command(executable: brew, arguments: ["info", "--cask", "--json=v2", "--installed"],
                                                     environment: HomebrewProvider.readOnlyEnvironment))
        guard result.exitCode == 0,
              let root = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            collectAppNames(in: cask["artifacts"], token: token, into: &map)
        }
        return map
    }

    private func collectAppNames(in value: Any?, token: String, into map: inout [String: String]) {
        if let string = value as? String, string.hasSuffix(".app") {
            map[URL(fileURLWithPath: string).lastPathComponent.lowercased()] = token
        } else if let array = value as? [Any] {
            for child in array { collectAppNames(in: child, token: token, into: &map) }
        } else if let dictionary = value as? [String: Any] {
            for child in dictionary.values { collectAppNames(in: child, token: token, into: &map) }
        }
    }

    private func classify(path: String, bundleID: String?, info: [String: Any], caskApps: [String: String]) -> Classification {
        let manager = FileManager.default
        if path.hasPrefix("/System/") {
            return Classification(source: "Apple / macOS", method: "Software Update", status: .current,
                                  category: .system, notes: "Se actualiza junto con macOS")
        }
        if manager.fileExists(atPath: "\(path)/Contents/_MASReceipt/receipt") {
            return Classification(source: "Mac App Store", method: "App Store / mas", status: .unknown,
                                  notes: "Se comprueba con mas o desde la App Store",
                                  metadata: [MetadataKey.masReceipt: "true", MetadataKey.openURL: "macappstore://showUpdatesPage"])
        }
        let appName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if let cask = caskApps[appName] {
            return Classification(source: "Homebrew Cask", method: "Homebrew (\(cask))", status: .unknown,
                                  metadata: [MetadataKey.caskToken: cask])
        }
        var metadata = [Key.checkable: "true"]
        if let feed = info["SUFeedURL"] as? String { metadata[Key.feedURL] = feed }
        if manager.fileExists(atPath: "\(path)/Contents/Frameworks/Sparkle.framework") || metadata[Key.feedURL] != nil {
            return Classification(source: "Instalación directa", method: "Actualizador propio (Sparkle)", status: .selfUpdating,
                                  notes: "Abre la aplicación para buscar actualizaciones", metadata: metadata)
        }
        let electronConfig = "\(path)/Contents/Resources/app-update.yml"
        if manager.fileExists(atPath: electronConfig) {
            metadata[Key.electronConfig] = electronConfig
            return Classification(source: "Instalación directa", method: "Actualizador propio (Electron)", status: .selfUpdating,
                                  notes: "Abre la aplicación para buscar actualizaciones", metadata: metadata)
        }
        if let updater = knownSelfUpdater(path: path, bundleID: bundleID) {
            return Classification(source: "Instalación directa", method: updater, status: .selfUpdating,
                                  notes: "La aplicación gestiona sus propias actualizaciones", metadata: metadata)
        }
        if let bundleID, bundleID.hasPrefix("com.apple.") {
            return Classification(source: "Apple", method: "Software Update / App Store", status: .unknown)
        }
        return Classification(source: "Instalación manual o desconocida", method: "Sin método automático conocido",
                              status: .unmanaged, category: .unmanaged, metadata: metadata)
    }

    private func knownSelfUpdater(path: String, bundleID: String?) -> String? {
        let manager = FileManager.default
        if manager.fileExists(atPath: "\(path)/Contents/Frameworks/Squirrel.framework") { return "Actualizador propio (Squirrel)" }
        if manager.fileExists(atPath: "\(path)/Contents/MacOS/updater.app") { return "Actualizador propio (Mozilla)" }
        guard let bundleID else { return nil }
        if bundleID.hasPrefix("com.google.") { return "Google Software Update" }
        if bundleID.hasPrefix("com.microsoft.") { return "Microsoft AutoUpdate" }
        if bundleID.hasPrefix("com.adobe.") { return "Adobe Creative Cloud" }
        if bundleID.hasPrefix("com.jetbrains.") { return "JetBrains Toolbox / actualizador propio" }
        return nil
    }
}
