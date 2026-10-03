import Foundation

/// Read-only checks against the update metadata vendors already publish.
enum VendorFeedResult: Equatable, Sendable {
    case updateAvailable(version: String, download: DirectDownload?)
    case current(String?)
    case unavailable(String)

    var isConclusive: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// A downloadable archive plus whatever integrity data the vendor published for it.
struct DirectDownload: Equatable, Sendable {
    var url: URL
    var sha256: String?
    var sha512: String?
    var edSignature: String?

    func apply(to metadata: inout [String: String]) {
        metadata[MetadataKey.downloadURL] = url.absoluteString
        metadata[MetadataKey.downloadSHA256] = sha256
        metadata[MetadataKey.downloadSHA512] = sha512
        metadata[MetadataKey.edSignature] = edSignature
    }

    static let installableExtensions: Set = ["zip", "dmg", "tgz", "gz", "bz2", "xz", "tar"]

    /// `.pkg` installers need administrator rights and are left to the user.
    var isInstallable: Bool { Self.installableExtensions.contains(url.pathExtension.lowercased()) }
}

// MARK: - Sparkle

struct AppcastRelease: Equatable, Sendable {
    var version: String?
    var shortVersion: String?
    var channel: String?
    var minimumSystemVersion: String?
    var downloadURL: String?
    var edSignature: String?
    var installationType: String?
    var operatingSystem: String?

    var displayVersion: String? { shortVersion ?? version }
}

enum SparkleFeed {
    static func check(feedURL: String, installedBuild: String?, installedVersion: String?, context: ProviderContext) async -> VendorFeedResult {
        guard let url = URL(string: feedURL), url.scheme?.lowercased() == "https" else {
            return .unavailable("Feed Sparkle sin HTTPS; no se consulta")
        }
        do {
            let data = try await context.http.data(from: url)
            let releases = AppcastParser.releases(from: data)
            guard let latest = latest(in: releases, includeBetas: context.policy.includeBetas, systemVersion: HostEnvironment.macOSVersion) else {
                return .unavailable("El feed Sparkle no contiene versiones compatibles")
            }
            guard isNewer(latest, installedBuild: installedBuild, installedVersion: installedVersion) else {
                return .current(latest.displayVersion)
            }
            var download: DirectDownload?
            if latest.installationType != "package", let raw = latest.downloadURL,
               let downloadURL = URL(string: raw, relativeTo: url)?.absoluteURL, downloadURL.scheme?.lowercased() == "https" {
                download = DirectDownload(url: downloadURL, edSignature: latest.edSignature)
            }
            return .updateAvailable(version: latest.displayVersion ?? "nueva versión", download: download)
        } catch {
            return .unavailable("No se pudo consultar el feed Sparkle: \(error.localizedDescription)")
        }
    }

    static func latest(in releases: [AppcastRelease], includeBetas: Bool, systemVersion: String) -> AppcastRelease? {
        let system = SemanticVersion(systemVersion)
        return releases
            .filter { $0.operatingSystem == nil || $0.operatingSystem == "macos" }
            .filter { includeBetas || $0.channel == nil }
            .filter { release in
                guard let minimum = release.minimumSystemVersion.flatMap(SemanticVersion.init), let system else { return true }
                return !(system < minimum)
            }
            .compactMap { release in (release.version ?? release.shortVersion).flatMap(SemanticVersion.init).map { (release, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Sparkle compares `sparkle:version` with `CFBundleVersion`; fall back to marketing versions otherwise.
    static func isNewer(_ release: AppcastRelease, installedBuild: String?, installedVersion: String?) -> Bool {
        if let remote = release.version, let local = installedBuild,
           SemanticVersion(remote) != nil, SemanticVersion(local) != nil {
            return SemanticVersion.isNewer(remote, than: local)
        }
        return SemanticVersion.isNewer(release.shortVersion, than: installedVersion)
    }
}

final class AppcastParser: NSObject, XMLParserDelegate {
    private var releases: [AppcastRelease] = []
    private var current: AppcastRelease?
    private var insideDeltas = false
    private var text = ""

    static func releases(from data: Data) -> [AppcastRelease] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.releases
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "item": current = AppcastRelease()
        case "sparkle:deltas": insideDeltas = true
        case "enclosure" where !insideDeltas:
            guard var release = current, release.downloadURL == nil else { return }
            release.downloadURL = attributeDict["url"]
            release.version = release.version ?? attributeDict["sparkle:version"]
            release.shortVersion = release.shortVersion ?? attributeDict["sparkle:shortVersionString"]
            release.edSignature = attributeDict["sparkle:edSignature"]
            release.installationType = attributeDict["sparkle:installationType"]
            release.operatingSystem = attributeDict["sparkle:os"]
            current = release
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        if elementName == "sparkle:deltas" { insideDeltas = false; return }
        guard current != nil, !insideDeltas else { return }
        switch elementName {
        case "sparkle:version" where !value.isEmpty: current?.version = value
        case "sparkle:shortVersionString" where !value.isEmpty: current?.shortVersion = value
        case "sparkle:channel" where !value.isEmpty: current?.channel = value
        case "sparkle:minimumSystemVersion" where !value.isEmpty: current?.minimumSystemVersion = value
        case "item":
            if let release = current, release.version != nil || release.shortVersion != nil { releases.append(release) }
            current = nil
        default: break
        }
    }
}

// MARK: - electron-builder

/// electron-builder apps ship `Contents/Resources/app-update.yml` describing where `latest-mac.yml` lives.
enum ElectronUpdaterFeed {
    struct Manifest: Equatable {
        var version: String?
        var files: [(url: String, sha512: String?)]

        static func == (lhs: Manifest, rhs: Manifest) -> Bool {
            lhs.version == rhs.version && lhs.files.map(\.url) == rhs.files.map(\.url) && lhs.files.map(\.sha512) == rhs.files.map(\.sha512)
        }
    }

    static func feedURL(fromConfiguration yaml: String) -> URL? {
        let values = topLevelValues(yaml)
        guard values["private"] != "true" else { return nil }
        let file = "\(values["channel"] ?? "latest")-mac.yml"
        switch values["provider"] {
        case "github":
            guard let owner = values["owner"], let repo = values["repo"], isSafeComponent(owner), isSafeComponent(repo) else { return nil }
            guard (values["host"] ?? "github.com") == "github.com" else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(file)")
        case "generic":
            guard let base = values["url"], let url = URL(string: base), url.scheme?.lowercased() == "https" else { return nil }
            return url.appendingPathComponent(file)
        default:
            return nil
        }
    }

    static func version(fromManifest yaml: String) -> String? {
        topLevelValues(yaml)["version"]
    }

    static func manifest(from yaml: String) -> Manifest {
        var files: [(url: String, sha512: String?)] = []
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- url:") {
                files.append((value(after: "- url:", in: line), nil))
            } else if line.hasPrefix("sha512:"), rawLine.first?.isWhitespace == true, !files.isEmpty {
                files[files.count - 1].sha512 = value(after: "sha512:", in: line)
            }
        }
        return Manifest(version: topLevelValues(yaml)["version"], files: files)
    }

    /// Picks the archive for this Mac: an arm64/x64 zip when published separately, otherwise the universal one.
    static func preferredFile(in manifest: Manifest, architecture: String = HostEnvironment.architecture) -> (url: String, sha512: String?)? {
        let archives = manifest.files.filter { ["zip", "dmg"].contains(URL(fileURLWithPath: $0.url).pathExtension.lowercased()) }
        let native = architecture == "arm64" ? "arm64" : "x64"
        let foreign = architecture == "arm64" ? "x64" : "arm64"
        let ranked = archives.sorted { lhs, rhs in score(lhs.url, native: native, foreign: foreign) > score(rhs.url, native: native, foreign: foreign) }
        return ranked.first { !$0.url.lowercased().contains(foreign) || $0.url.lowercased().contains("universal") }
    }

    static func check(configuration: String, installedVersion: String?, context: ProviderContext) async -> VendorFeedResult {
        guard let url = feedURL(fromConfiguration: configuration) else {
            return .unavailable("Actualizador Electron con un origen que no se puede consultar de forma segura")
        }
        do {
            let data = try await context.http.data(from: url)
            let manifest = manifest(from: String(decoding: data, as: UTF8.self))
            guard let remote = manifest.version else { return .unavailable("El manifiesto de actualización no indica versión") }
            if !context.policy.includeBetas, SemanticVersion(remote)?.prerelease != nil { return .current(installedVersion) }
            guard SemanticVersion.isNewer(remote, than: installedVersion) else { return .current(remote) }
            var download: DirectDownload?
            if let file = preferredFile(in: manifest), let fileURL = URL(string: file.url, relativeTo: url)?.absoluteURL,
               fileURL.scheme?.lowercased() == "https" {
                download = DirectDownload(url: fileURL, sha512: file.sha512)
            }
            return .updateAvailable(version: remote, download: download)
        } catch {
            return .unavailable("No se pudo consultar el manifiesto de actualización: \(error.localizedDescription)")
        }
    }

    /// Minimal `key: value` reader for the flat YAML files electron-builder emits.
    static func topLevelValues(_ yaml: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in yaml.split(whereSeparator: \.isNewline) {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-" else { continue }
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[1].isEmpty else { continue }
            values[pair[0]] = unquote(pair[1])
        }
        return values
    }

    private static func value(after prefix: String, in line: String) -> String {
        unquote(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func score(_ url: String, native: String, foreign: String) -> Int {
        let lowered = url.lowercased()
        var score = 0
        if lowered.contains(native) { score += 4 }
        if lowered.contains("universal") { score += 2 }
        if lowered.hasSuffix(".zip") { score += 1 }
        if lowered.contains(foreign) && !lowered.contains("universal") { score -= 10 }
        return score
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Latest releases

enum LatestRelease {
    /// Resolves `github.com/<repo>/releases/latest` through its redirect (no API rate limit) and extracts the version.
    static func gitHub(_ repository: String, context: ProviderContext) async -> String? {
        guard let url = URL(string: "https://github.com/\(repository)/releases/latest"),
              let final = try? await context.http.finalURL(for: url) else { return nil }
        let tag = final.lastPathComponent
        guard final.path.contains("/releases/tag/") else { return nil }
        return firstVersion(in: tag)
    }

    /// First `x.y[.z]` number in free-form tool output such as `deno 2.0.0 (stable, release, aarch64)`.
    static func firstVersion(in text: String) -> String? {
        text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(text[$0]) }
    }
}

// MARK: - Homebrew cask catalog

/// Homebrew's public cask metadata, used to offer verified updates for apps installed by hand
/// (dragged from a DMG) that Homebrew knows about. Read from Homebrew's local API cache when present.
struct CaskCatalog: Sendable {
    struct Entry: Equatable, Sendable {
        var token: String
        var version: String
        var url: String
        var sha256: String?
        var homepage: String?
        var installsWithPackage: Bool
    }

    private let entriesByAppName: [String: Entry]

    init(entries: [String: Entry]) { entriesByAppName = entries }

    func entry(forAppNamed fileName: String) -> Entry? {
        entriesByAppName[fileName.lowercased()]
    }

    /// Cask versions look like `4.33.3` or `4.33.3,170`; only the marketing part is compared.
    static func marketingVersion(_ version: String) -> String {
        String(version.split(separator: ",").first ?? Substring(version))
    }

    static func load(context: ProviderContext) async -> CaskCatalog? {
        let cacheRoot = ProcessInfo.processInfo.environment["HOMEBREW_CACHE"] ?? "\(context.homeDirectory)/Library/Caches/Homebrew"
        let local = URL(fileURLWithPath: "\(cacheRoot)/api/cask.jws.json")
        if let data = try? Data(contentsOf: local, options: .mappedIfSafe), let catalog = parse(data) { return catalog }

        let ownCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActuchosMac", isDirectory: true)
        let cached = ownCache.appendingPathComponent("cask.json")
        let modified = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: cached, options: .mappedIfSafe), let catalog = parse(data) { return catalog }

        guard let remote = URL(string: "https://formulae.brew.sh/api/cask.json") else { return nil }
        try? FileManager.default.createDirectory(at: ownCache, withIntermediateDirectories: true)
        guard let downloaded = try? await context.http.download(from: remote, into: ownCache) else { return nil }
        if downloaded != cached {
            try? FileManager.default.removeItem(at: cached)
            try? FileManager.default.moveItem(at: downloaded, to: cached)
        }
        guard let data = try? Data(contentsOf: cached, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    /// Accepts both the plain JSON array and Homebrew's signed JWS envelope (`{"payload": "<json>"}`).
    static func parse(_ data: Data, architecture: String = HostEnvironment.architecture) -> CaskCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let array: [[String: Any]]
        if let list = root as? [[String: Any]] {
            array = list
        } else if let envelope = root as? [String: Any], let payload = envelope["payload"] as? String,
                  let list = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]] {
            array = list
        } else {
            return nil
        }

        var entries: [String: Entry] = [:]
        for var cask in array {
            guard let token = cask["token"] as? String, cask["disabled"] as? Bool != true else { continue }
            if architecture != "arm64", let variations = cask["variations"] as? [String: [String: Any]],
               let intel = variations.first(where: { !$0.key.hasPrefix("arm64") })?.value {
                cask.merge(intel) { _, new in new }
            }
            guard let version = cask["version"] as? String, version != "latest",
                  let url = cask["url"] as? String, url.lowercased().hasPrefix("https://") else { continue }
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            let appNames = artifacts.compactMap { $0["app"] as? [Any] }.flatMap { $0 }.compactMap { $0 as? String }
            guard !appNames.isEmpty else { continue }
            let sha = cask["sha256"] as? String
            let entry = Entry(
                token: token, version: version, url: url,
                sha256: sha.flatMap { $0.count == 64 ? $0 : nil },
                homepage: cask["homepage"] as? String,
                installsWithPackage: artifacts.contains { $0["pkg"] != nil }
            )
            for appName in appNames {
                let key = URL(fileURLWithPath: appName).lastPathComponent.lowercased()
                // Prefer the main cask (`firefox`) over variants (`firefox@beta`, `firefox@esr`).
                if let existing = entries[key], !existing.token.contains("@") || token.contains("@") { continue }
                entries[key] = entry
            }
        }
        return CaskCatalog(entries: entries)
    }
}
