import Foundation

/// Package names that are safe to pass as a single argument (pip, npm incl. scopes, gems, crates).
private func isSafePackageName(_ name: String) -> Bool {
    name.range(of: #"^@?[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9._+-]+)?$"#, options: .regularExpression) != nil
}

/// Re-reads installed versions after an update without repeating slow network checks.
private func observedVersions(for items: [UpdateItem], installed: [String: String]) -> [String: UpdateItem] {
    var result: [String: UpdateItem] = [:]
    for item in items {
        guard let package = item.metadata["package"], let version = installed[package.lowercased()] else { continue }
        var observed = item
        observed.installedVersion = version
        observed.status = SemanticVersion.isNewer(item.availableVersion, than: version) ? .updateAvailable : .current
        result[item.id] = observed
    }
    return result
}

// MARK: - pip

struct PythonPackagesProvider: UpdateProvider {
    let id = "pip"
    let displayName = "Paquetes pip"
    let priority = 55

    /// Packages Homebrew's Python ships and manages itself.
    private static let managedByDistribution: Set = ["pip", "setuptools", "wheel"]

    private struct Interpreter: Sendable {
        let path: String
        let version: String
        let externallyManaged: Bool
    }

    private struct PipPackage: Decodable {
        let name: String
        let version: String
        let latestVersion: String?
        enum CodingKeys: String, CodingKey { case name, version; case latestVersion = "latest_version" }
    }

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let interpreters = await concurrentMap(PythonProvider.interpreters(context: context), limit: 4) { path in
            await inspect(path, context: context)
        }.compactMap { $0 }
        let lists = await concurrentMap(interpreters, limit: 4) { interpreter -> [UpdateItem] in
            let result = await context.runner.run(pip(interpreter.path, ["list", "--format=json", "--not-required"], timeout: 90))
            guard result.succeeded, let packages = try? JSONDecoder().decode([PipPackage].self, from: Data(result.stdout.utf8)) else { return [] }
            return packages.map { item(for: $0, interpreter: interpreter, context: context) }
        }
        return lists.flatMap { $0 }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        let byInterpreter = Dictionary(grouping: items, by: { $0.metadata["python"] ?? "" })
        let checked = await concurrentMap(Array(byInterpreter), limit: 4) { python, group -> [UpdateItem] in
            let result = await context.runner.run(pip(python, ["list", "--outdated", "--format=json", "--not-required"], timeout: 300))
            guard result.succeeded, let outdated = try? JSONDecoder().decode([PipPackage].self, from: Data(result.stdout.utf8)) else {
                return group.map { var item = $0; item.status = .unknown; item.notes = "pip no pudo consultar PyPI"; return item }
            }
            let latest = Dictionary(outdated.map { ($0.name.lowercased(), $0.latestVersion ?? $0.version) }, uniquingKeysWith: { first, _ in first })
            return group.map { original in
                var item = original
                if let available = latest[(item.metadata["package"] ?? "").lowercased()] {
                    item.status = .updateAvailable
                    item.availableVersion = available
                    let blocked = item.metadata["managed"] == "true" && Self.managedByDistribution.contains(item.name.lowercased())
                    item.canUpdateAutomatically = !blocked
                    if blocked { item.notes = "Lo gestiona la instalación de Python (Homebrew); se actualiza con ella" }
                } else {
                    item.status = .current
                }
                return item
            }
        }
        return checked.flatMap { $0 }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let python = item.metadata["python"], let package = item.metadata["package"], isSafePackageName(package),
              let version = item.availableVersion, SemanticVersion(version) != nil else { return nil }
        var arguments = ["install", "--upgrade", "\(package)==\(version)"]
        // PEP 668 interpreters refuse global installs; the user already opted out when installing this package there.
        if item.metadata["managed"] == "true" { arguments.append("--break-system-packages") }
        return await context.runner.run(pip(python, arguments, timeout: 1200))
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        var result: [String: UpdateItem] = [:]
        for (python, group) in Dictionary(grouping: items, by: { $0.metadata["python"] ?? "" }) {
            let list = await context.runner.run(pip(python, ["list", "--format=json"], timeout: 90))
            let packages = (try? JSONDecoder().decode([PipPackage].self, from: Data(list.stdout.utf8))) ?? []
            let installed = Dictionary(packages.map { ($0.name.lowercased(), $0.version) }, uniquingKeysWith: { first, _ in first })
            result.merge(observedVersions(for: group, installed: installed)) { _, new in new }
        }
        return result
    }

    private func inspect(_ path: String, context: ProviderContext) async -> Interpreter? {
        let script = "import json,os,sys,sysconfig,importlib.util as u;print(json.dumps({'v':'%d.%d.%d'%sys.version_info[:3],"
            + "'m':os.path.exists(os.path.join(sysconfig.get_path('stdlib'),'EXTERNALLY-MANAGED')),'p':u.find_spec('pip') is not None}))"
        let result = await context.runner.run(Command(executable: path, arguments: ["-c", script], timeout: 20))
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              json["p"] as? Bool == true, let version = json["v"] as? String else { return nil }
        return Interpreter(path: path, version: version, externallyManaged: json["m"] as? Bool == true)
    }

    private func item(for package: PipPackage, interpreter: Interpreter, context: ProviderContext) -> UpdateItem {
        let minor = interpreter.version.split(separator: ".").prefix(2).joined(separator: ".")
        let origin = PythonProvider.source(path: interpreter.path)
        return UpdateItem(
            id: "pip:\(interpreter.path):\(package.name.lowercased())", providerID: id, name: package.name, category: .packages,
            installedVersion: package.version, source: "pip · Python \(minor) (\(origin))", updateMethod: "pip install --upgrade",
            path: context.locator.displayPath(interpreter.path),
            notes: interpreter.externallyManaged ? "Python gestionado externamente (PEP 668)" : nil,
            priority: priority,
            metadata: [
                "python": interpreter.path, "package": package.name, "managed": interpreter.externallyManaged ? "true" : "false",
                MetadataKey.lock: PythonProvider.isHomebrew(interpreter.path) ? "homebrew" : "pip:\(interpreter.path)"
            ]
        )
    }

    private func pip(_ python: String, _ arguments: [String], timeout: TimeInterval) -> Command {
        Command(executable: python, arguments: ["-m", "pip"] + arguments + ["--disable-pip-version-check", "--no-input"],
                environment: ["PIP_NO_COLOR": "1"], timeout: timeout)
    }
}

// MARK: - npm global packages

struct NPMGlobalPackagesProvider: UpdateProvider {
    let id = "npm-global"
    let displayName = "Paquetes npm globales"
    let priority = 46

    /// npm and Corepack are handled by `NodePackagesProvider`.
    private static let excluded: Set = ["npm", "corepack"]

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let npm = await context.activeExecutable(named: "npm") else { return [] }
        let installed = await installedPackages(npm: npm, context: context)
        let isHomebrew = npm.contains("/Cellar/") || npm.hasPrefix("/opt/homebrew/")
        return installed.sorted { $0.key < $1.key }.compactMap { name, version in
            guard !Self.excluded.contains(name) else { return nil }
            return UpdateItem(
                id: "npm-global:\(name)", providerID: id, name: name, category: .packages, installedVersion: version,
                source: "npm global", updateMethod: "npm install --global", path: context.locator.displayPath(npm),
                priority: priority, metadata: ["package": name, "npm": npm, MetadataKey.lock: isHomebrew ? "homebrew" : "node"]
            )
        }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard let npm = items.first?.metadata["npm"] else { return items }
        // `npm outdated` exits with 1 when something is outdated; the JSON is still valid.
        let result = await context.runner.run(Command(executable: npm, arguments: ["outdated", "--global", "--json"], timeout: 180))
        guard let json = try? JSONSerialization.jsonObject(with: Data((result.stdout.isEmpty ? "{}" : result.stdout).utf8)) as? [String: [String: Any]] else {
            return items.map { var item = $0; item.status = .unknown; item.notes = "npm no pudo consultar el registro"; return item }
        }
        return items.map { original in
            var item = original
            if let latest = json[item.name]?["latest"] as? String, SemanticVersion.isNewer(latest, than: item.installedVersion) {
                item.status = .updateAvailable
                item.availableVersion = latest
                item.canUpdateAutomatically = true
            } else {
                item.status = .current
            }
            return item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let npm = item.metadata["npm"], let package = item.metadata["package"], isSafePackageName(package),
              let version = item.availableVersion, SemanticVersion(version) != nil else { return nil }
        return await context.runner.run(Command(executable: npm, arguments: ["install", "--global", "\(package)@\(version)"], timeout: 1200))
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        guard let npm = items.first?.metadata["npm"] else { return [:] }
        let installed = await installedPackages(npm: npm, context: context)
        return observedVersions(for: items, installed: Dictionary(installed.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }))
    }

    private func installedPackages(npm: String, context: ProviderContext) async -> [String: String] {
        let result = await context.runner.run(Command(executable: npm, arguments: ["ls", "--global", "--depth=0", "--json"], timeout: 60))
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let dependencies = json["dependencies"] as? [String: [String: Any]] else { return [:] }
        return dependencies.compactMapValues { $0["version"] as? String }
    }
}

// MARK: - RubyGems

struct RubyGemsProvider: UpdateProvider {
    let id = "gem"
    let displayName = "Gems de Ruby"
    let priority = 57

    /// Lists only outdated gems: Ruby installs dozens of default gems that are not meant to be managed.
    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let gem = await context.activeExecutable(named: "gem"),
              !gem.hasPrefix("/usr/bin/"), !gem.hasPrefix("/System/") else { return [] }
        let result = await context.runner.run(Command(executable: gem, arguments: ["outdated"], timeout: 180))
        guard result.succeeded else { return [] }
        return Self.parseOutdated(result.stdout).map { name, installed, latest in
            UpdateItem(
                id: "gem:\(name)", providerID: id, name: name, category: .packages, installedVersion: installed,
                availableVersion: latest, status: .updateAvailable, source: "RubyGems", updateMethod: "gem update",
                canUpdateAutomatically: true, path: context.locator.displayPath(gem), priority: priority,
                metadata: ["package": name, "gem": gem, MetadataKey.lock: "gem"]
            )
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let gem = item.metadata["gem"], let package = item.metadata["package"], isSafePackageName(package) else { return nil }
        return await context.runner.run(Command(executable: gem, arguments: ["update", package, "--no-document"], timeout: 1200))
    }

    /// Parses `rake (13.0.6 < 13.2.1)`.
    static func parseOutdated(_ output: String) -> [(name: String, installed: String, latest: String)] {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
            let name = text[..<open].trimmingCharacters(in: .whitespaces)
            let versions = text[text.index(after: open)..<close].components(separatedBy: " < ")
            guard versions.count == 2, !name.isEmpty else { return nil }
            let installed = versions[0].split(separator: ",").first.map(String.init) ?? versions[0]
            return (name, installed.trimmingCharacters(in: .whitespaces), versions[1].trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: - cargo install

struct CargoInstallsProvider: UpdateProvider {
    let id = "cargo"
    let displayName = "Binarios de cargo"
    let priority = 58

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let cargo = await context.activeExecutable(named: "cargo") else { return [] }
        let result = await context.runner.run(Command(executable: cargo, arguments: ["install", "--list"], timeout: 60))
        guard result.succeeded else { return [] }
        return Self.parseInstallList(result.stdout).map { name, version in
            UpdateItem(
                id: "cargo:\(name)", providerID: id, name: name, category: .packages, installedVersion: version,
                source: "cargo install (crates.io)", updateMethod: "cargo install", path: context.locator.displayPath(cargo),
                priority: priority, metadata: ["package": name, "cargo": cargo, MetadataKey.lock: "cargo"]
            )
        }
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard context.policy.checkVendorFeeds else { return items }
        return await concurrentMap(items, limit: 4) { original in
            var item = original
            guard let name = item.metadata["package"], isSafePackageName(name),
                  let url = URL(string: "https://crates.io/api/v1/crates/\(name)"),
                  let data = try? await context.http.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let crate = json["crate"] as? [String: Any],
                  let latest = (crate["max_stable_version"] as? String) ?? (crate["newest_version"] as? String) else {
                item.status = .unknown
                return item
            }
            item.availableVersion = latest
            item.status = SemanticVersion.isNewer(latest, than: item.installedVersion) ? .updateAvailable : .current
            item.canUpdateAutomatically = item.status == .updateAvailable
            return item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let cargo = item.metadata["cargo"], let name = item.metadata["package"], isSafePackageName(name),
              let version = item.availableVersion, SemanticVersion(version) != nil else { return nil }
        return await context.runner.run(Command(executable: cargo, arguments: ["install", name, "--version", version], timeout: 3600))
    }

    /// Parses `ripgrep v14.1.0:` headers; local-path installs (`name v0.1.0 (/path):`) are skipped.
    static func parseInstallList(_ output: String) -> [(name: String, version: String)] {
        output.split(separator: "\n").compactMap { line in
            guard let first = line.first, !first.isWhitespace, line.hasSuffix(":"), !line.contains("(") else { return nil }
            let parts = line.dropLast().split(separator: " ")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst(parts[1].hasPrefix("v") ? 1 : 0)))
        }
    }
}

// MARK: - pipx and uv tools

struct PythonToolsProvider: UpdateProvider {
    let id = "python-tools"
    let displayName = "pipx / uv tool"
    let priority = 56

    func detect(context: ProviderContext) async -> [UpdateItem] {
        let paths = await context.shell.paths(for: ["pipx", "uv"])
        var items: [UpdateItem] = []
        if let pipx = paths["pipx"] ?? context.executable(named: "pipx") {
            let result = await context.runner.run(Command(executable: pipx, arguments: ["list", "--json"], timeout: 60))
            items += Self.parsePipx(result.stdout).map { tool(name: $0.name, version: $0.version, manager: "pipx", path: pipx, context: context) }
        }
        if let uv = paths["uv"] ?? context.executable(named: "uv") {
            let result = await context.runner.run(Command(executable: uv, arguments: ["tool", "list"], timeout: 60))
            items += Self.parseUVTools(result.stdout).map { tool(name: $0.name, version: $0.version, manager: "uv", path: uv, context: context) }
        }
        return items
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        guard context.policy.checkVendorFeeds else { return items }
        return await concurrentMap(items, limit: 4) { original in
            var item = original
            guard let name = item.metadata["package"], isSafePackageName(name),
                  let url = URL(string: "https://pypi.org/pypi/\(name)/json"),
                  let data = try? await context.http.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latest = (json["info"] as? [String: Any])?["version"] as? String else {
                item.status = .unknown
                return item
            }
            item.availableVersion = latest
            item.status = SemanticVersion.isNewer(latest, than: item.installedVersion) ? .updateAvailable : .current
            item.canUpdateAutomatically = item.status == .updateAvailable
            return item
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let path = item.metadata["managerPath"], let name = item.metadata["package"], isSafePackageName(name) else { return nil }
        let arguments = item.metadata["manager"] == "uv" ? ["tool", "upgrade", name] : ["upgrade", name]
        return await context.runner.run(Command(executable: path, arguments: arguments, timeout: 1200))
    }

    private func tool(name: String, version: String, manager: String, path: String, context: ProviderContext) -> UpdateItem {
        UpdateItem(
            id: "\(manager)-tool:\(name)", providerID: id, name: name, category: .packages, installedVersion: version,
            source: manager == "uv" ? "uv tool" : "pipx", updateMethod: manager == "uv" ? "uv tool upgrade" : "pipx upgrade",
            path: context.locator.displayPath(path), priority: priority,
            metadata: ["package": name, "manager": manager, "managerPath": path, MetadataKey.lock: manager]
        )
    }

    /// `pipx list --json` → `{"venvs": {"black": {"metadata": {"main_package": {"package_version": "24.1"}}}}}`.
    static func parsePipx(_ output: String) -> [(name: String, version: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let venvs = json["venvs"] as? [String: [String: Any]] else { return [] }
        return venvs.compactMap { name, venv in
            let main = (venv["metadata"] as? [String: Any])?["main_package"] as? [String: Any]
            guard let version = main?["package_version"] as? String else { return nil }
            return ((main?["package"] as? String) ?? name, version)
        }.sorted { $0.name < $1.name }
    }

    /// `uv tool list` → `ruff v0.6.9` followed by `- ruff` lines.
    static func parseUVTools(_ output: String) -> [(name: String, version: String)] {
        output.split(separator: "\n").compactMap { line in
            guard let first = line.first, first != "-", !first.isWhitespace else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("v") else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst()))
        }
    }
}

// MARK: - rustup

struct RustupProvider: UpdateProvider {
    let id = "rustup"
    let displayName = "Rust (rustup)"
    let priority = 59

    func detect(context: ProviderContext) async -> [UpdateItem] {
        guard let rustup = await context.activeExecutable(named: "rustup") else { return [] }
        let result = await context.runner.run(Command(executable: rustup, arguments: ["check"], timeout: 120))
        return Self.parseCheck(result.stdout).map { entry in
            UpdateItem(
                id: "rustup:\(entry.name)", providerID: id, name: entry.name == "rustup" ? "rustup" : "Rust \(entry.name)",
                category: .development, installedVersion: entry.installed, availableVersion: entry.available,
                status: entry.available == nil ? .current : .updateAvailable, source: "rustup",
                updateMethod: entry.name == "rustup" ? "rustup self update" : "rustup update",
                canUpdateAutomatically: entry.available != nil, path: context.locator.displayPath(rustup), priority: priority,
                metadata: ["toolchain": entry.name, "rustup": rustup, MetadataKey.lock: "rustup"]
            )
        }
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        guard let rustup = item.metadata["rustup"], let toolchain = item.metadata["toolchain"], isSafePackageName(toolchain) else { return nil }
        let arguments = toolchain == "rustup" ? ["self", "update"] : ["update", toolchain, "--no-self-update"]
        return await context.runner.run(Command(executable: rustup, arguments: arguments, timeout: 3600))
    }

    /// Parses `stable-aarch64-apple-darwin - Update available : 1.80.1 (…) -> 1.81.0 (…)` and `… - Up to date : 1.81.0 (…)`.
    static func parseCheck(_ output: String) -> [(name: String, installed: String?, available: String?)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let detail = parts.dropFirst().joined(separator: " - ")
            let versions = detail.components(separatedBy: "->").map { LatestRelease.firstVersion(in: $0) }
            if detail.contains("Update available") {
                return (name, versions.first ?? nil, versions.count > 1 ? versions[1] : nil)
            }
            if detail.contains("Up to date") { return (name, versions.first ?? nil, nil) }
            return nil
        }
    }
}
