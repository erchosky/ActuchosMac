import AppKit
import CryptoKit
import Foundation
import Security

/// In-process code-signature inspection (no `codesign` subprocess per app).
enum CodeSignature {
    struct Info: Equatable {
        var teamID: String?
        var authority: String?
    }

    static func info(forAppAt path: String) -> Info {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return Info(teamID: nil, authority: "Sin firma válida") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any], dictionary[kSecCodeInfoIdentifier as String] != nil else {
            return Info(teamID: nil, authority: "Sin firma")
        }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let authority = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Firma ad hoc"
        return Info(teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String, authority: authority)
    }

    static func architectures(ofBundleAt path: String) -> String? {
        guard let values = Bundle(path: path)?.executableArchitectures?.map(\.intValue), !values.isEmpty else { return nil }
        return values.map { value -> String in
            switch value {
            case NSBundleExecutableArchitectureARM64: "arm64"
            case NSBundleExecutableArchitectureX86_64: "x86_64"
            default: "otra"
            }
        }.joined(separator: " ")
    }
}

/// Replaces an installed `.app` with a newer build downloaded from the vendor's own feed or Homebrew's catalog.
///
/// Safety checks, all mandatory: HTTPS download, published hash or EdDSA signature when available,
/// valid code signature from the *same* Apple Team ID as the installed app, Gatekeeper acceptance,
/// and the previous version is moved to the Trash (never deleted) so the update can be undone.
enum AppInstaller {
    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Marks an item as installable when everything needed for a verified replacement is known.
    static func prepare(_ item: inout UpdateItem, appPath: String, download: DirectDownload?) {
        item.metadata[MetadataKey.appPath] = appPath
        let signature = CodeSignature.info(forAppAt: appPath)
        let bundleID = Bundle(path: appPath)?.bundleIdentifier
        item.metadata[MetadataKey.bundleID] = bundleID
        item.metadata[MetadataKey.teamID] = signature.teamID
        guard let download, download.isInstallable, signature.teamID != nil, let bundleID,
              bundleID != Bundle.main.bundleIdentifier else {
            item.canUpdateAutomatically = false
            return
        }
        download.apply(to: &item.metadata)
        item.metadata[MetadataKey.lock] = "app:\(bundleID)"
        item.canUpdateAutomatically = true
        item.updateMethod = "Descarga verificada (\(download.url.host ?? "fabricante"))"
    }

    /// Reads the version currently on disk; used to verify an install without a full rescan.
    static func observe(_ item: UpdateItem) -> UpdateItem? {
        guard let path = item.appBundlePath, let info = Bundle(path: path)?.infoDictionary else { return nil }
        var observed = item
        observed.installedVersion = info["CFBundleShortVersionString"] as? String
        observed.status = SemanticVersion.isNewer(item.availableVersion, than: observed.installedVersion) ? .updateAvailable : .current
        return observed
    }

    static func install(_ item: UpdateItem, context: ProviderContext) async -> ProcessResult {
        let started = Date()
        do {
            let summary = try await perform(item, context: context)
            return ProcessResult(command: "instalar \(item.name)", stdout: summary, stderr: "", exitCode: 0,
                                 duration: Date().timeIntervalSince(started), timedOut: false)
        } catch {
            return ProcessResult(command: "instalar \(item.name)", stdout: "", stderr: error.localizedDescription, exitCode: 1,
                                 duration: Date().timeIntervalSince(started), timedOut: false)
        }
    }

    private static func perform(_ item: UpdateItem, context: ProviderContext) async throws -> String {
        guard let appPath = item.appBundlePath,
              let raw = item.metadata[MetadataKey.downloadURL], let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            throw InstallError(message: "No hay una descarga HTTPS conocida para esta app")
        }
        guard let bundleID = item.metadata[MetadataKey.bundleID], let teamID = item.metadata[MetadataKey.teamID], !teamID.isEmpty else {
            throw InstallError(message: "La app instalada no tiene firma de desarrollador; no se puede verificar la descarga")
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ActuchosMac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        await context.logger.log(provider: item.name, "Descargando \(url.host ?? "")\(url.path)")
        let archive = try await context.http.download(from: url, into: workspace)
        try verifyIntegrity(of: archive, item: item)

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await extract(archive, into: extracted, workspace: workspace, bundleID: bundleID, context: context)
        guard let newApp = findApp(withBundleID: bundleID, in: extracted) else {
            throw InstallError(message: "El archivo descargado no contiene \(bundleID)")
        }
        try await verifySignature(of: newApp, expectedTeamID: teamID, context: context)
        let newVersion = Bundle(path: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        let wasRunning = try await quitIfRunning(bundleID: bundleID, name: item.name, allowed: context.policy.quitRunningApps)
        try replace(appAt: appPath, with: newApp)
        if wasRunning { await relaunch(appPath) }
        return "\(item.name) \(newVersion) instalada en \(appPath). La versión anterior está en la Papelera."
    }

    // MARK: Integrity

    private static func verifyIntegrity(of archive: URL, item: UpdateItem) throws {
        if let expected = item.metadata[MetadataKey.downloadSHA256]?.lowercased() {
            var hasher = SHA256()
            try stream(archive) { hasher.update(data: $0) }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw InstallError(message: "El SHA-256 de la descarga no coincide con el publicado")
            }
        }
        if let expected = item.metadata[MetadataKey.downloadSHA512] {
            var hasher = SHA512()
            try stream(archive) { hasher.update(data: $0) }
            guard Data(hasher.finalize()).base64EncodedString() == expected else {
                throw InstallError(message: "El SHA-512 de la descarga no coincide con el publicado")
            }
        }
        if let signature = item.metadata[MetadataKey.edSignature].flatMap({ Data(base64Encoded: $0) }),
           let keyData = item.metadata[MetadataKey.edPublicKey].flatMap({ Data(base64Encoded: $0) }) {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard key.isValidSignature(signature, for: data) else {
                throw InstallError(message: "La firma EdDSA de Sparkle no es válida")
            }
        }
    }

    private static func stream(_ file: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { consume(chunk) }
    }

    // MARK: Extraction

    private static func extract(_ archive: URL, into destination: URL, workspace: URL, bundleID: String, context: ProviderContext) async throws {
        let kind = archiveKind(archive)
        switch kind {
        case "zip":
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path], context: context, failure: "No se pudo descomprimir el ZIP")
        case "tar":
            try await run("/usr/bin/tar", ["-xf", archive.path, "-C", destination.path], context: context, failure: "No se pudo descomprimir el archivo")
        default:
            let mountPoint = workspace.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mountPoint.path, archive.path],
                          context: context, failure: "No se pudo montar la imagen (puede requerir aceptar una licencia)", timeout: 300)
            let detach = Command(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"], timeout: 60)
            do {
                guard let app = findApp(withBundleID: bundleID, in: mountPoint) else {
                    throw InstallError(message: "La imagen no contiene \(bundleID)")
                }
                let copy = destination.appendingPathComponent(URL(fileURLWithPath: app).lastPathComponent)
                try await run("/usr/bin/ditto", [app, copy.path], context: context, failure: "No se pudo copiar la app desde la imagen")
            } catch {
                _ = await context.runner.run(detach)
                throw error
            }
            _ = await context.runner.run(detach)
        }
    }

    private static func archiveKind(_ file: URL) -> String {
        let name = file.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return "zip" }
        if name.hasSuffix(".dmg") { return "dmg" }
        if [".tar", ".tgz", ".tar.gz", ".tar.bz2", ".tar.xz", ".tbz"].contains(where: name.hasSuffix) { return "tar" }
        let magic = (try? FileHandle(forReadingFrom: file).read(upToCount: 2)) ?? Data()
        return magic == Data("PK".utf8) ? "zip" : "dmg"
    }

    static func findApp(withBundleID bundleID: String, in root: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "app" else { continue }
            enumerator.skipDescendants()
            // A symlinked bundle (e.g. a DMG shortcut) could point anywhere; only real bundles qualify.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if Bundle(url: url)?.bundleIdentifier == bundleID { return url.path }
        }
        return nil
    }

    // MARK: Verification

    private static func verifySignature(of app: String, expectedTeamID: String, context: ProviderContext) async throws {
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app], context: context,
                      failure: "La firma de la nueva versión no es válida", timeout: 300)
        let team = CodeSignature.info(forAppAt: app).teamID
        guard team == expectedTeamID else {
            throw InstallError(message: "La descarga está firmada por otro desarrollador (\(team ?? "sin Team ID")); se esperaba \(expectedTeamID)")
        }
        try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app], context: context,
                      failure: "Gatekeeper rechaza la nueva versión (no está notarizada)", timeout: 120)
    }

    private static func run(_ executable: String, _ arguments: [String], context: ProviderContext,
                            failure: String, timeout: TimeInterval = 600) async throws {
        let result = await context.runner.run(Command(executable: executable, arguments: arguments, timeout: timeout))
        guard result.succeeded else { throw InstallError(message: "\(failure): \(result.combinedOutput)") }
    }

    // MARK: Replacement

    @MainActor
    private static func quitIfRunning(bundleID: String, name: String, allowed: Bool) async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return false }
        guard allowed else { throw InstallError(message: "\(name) está abierta. Ciérrala y vuelve a intentarlo.") }
        running.forEach { $0.terminate() }
        for _ in 0..<60 {
            if running.allSatisfy(\.isTerminated) { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw InstallError(message: "\(name) no se cerró (¿documentos sin guardar?). Ciérrala y vuelve a intentarlo.")
    }

    private static func replace(appAt path: String, with newApp: String) throws {
        let manager = FileManager.default
        let target = URL(fileURLWithPath: path)
        var trashed: NSURL?
        do {
            try manager.trashItem(at: target, resultingItemURL: &trashed)
        } catch {
            throw InstallError(message: "Sin permiso para reemplazar \(path): \(error.localizedDescription)")
        }
        do {
            try manager.moveItem(at: URL(fileURLWithPath: newApp), to: target)
        } catch {
            if let trashed = trashed as URL? { try? manager.moveItem(at: trashed, to: target) }
            throw InstallError(message: "No se pudo colocar la nueva versión; se restauró la anterior: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func relaunch(_ path: String) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }
}
