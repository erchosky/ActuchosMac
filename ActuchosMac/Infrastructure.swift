import Foundation

enum HostEnvironment {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static let standardBinaryDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }

    /// `/usr/bin/python3` and friends are shims that open the "install Command Line Tools" dialog
    /// when no developer directory exists. They must never be executed in that state.
    static var developerToolsInstalled: Bool {
        let manager = FileManager.default
        if let selected = try? manager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            return manager.fileExists(atPath: "\(selected)/usr/bin")
        }
        return manager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin")
            || manager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin")
    }

    /// `/usr/bin/java` shows a "no Java runtime" dialog unless a JDK is registered with the system.
    static func javaRuntimeInstalled(homeDirectory: String) -> Bool {
        ["/Library/Java/JavaVirtualMachines", "\(homeDirectory)/Library/Java/JavaVirtualMachines"].contains { root in
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return entries.contains { $0.hasSuffix(".jdk") }
        }
    }
}

struct ExecutableLocator: Sendable {
    let homeDirectory: String

    func find(_ name: String, additionalPaths: [String] = []) -> String? {
        all(name, additionalPaths: additionalPaths).first
    }

    func all(_ name: String, additionalPaths: [String] = []) -> [String] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let userDirectories = [
            "bin", ".local/bin", ".volta/bin", ".bun/bin", ".deno/bin", ".cargo/bin",
            ".pyenv/shims", ".local/share/fnm/aliases/default/bin"
        ].map { "\(homeDirectory)/\($0)" }
        var candidates = additionalPaths
        candidates += (pathDirectories + HostEnvironment.standardBinaryDirectories + userDirectories).map { "\($0)/\(name)" }
        candidates += managerExecutables(name: name)
        var seen = Set<String>()
        return candidates.compactMap { path in
            guard isUsable(path), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return seen.insert(resolved).inserted ? resolved : nil
        }
    }

    func applications(named names: [String]) -> [String] {
        let roots = ["/Applications", "\(homeDirectory)/Applications"]
        return names.flatMap { name in roots.map { "\($0)/\(name).app" } }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    func displayPath(_ path: String) -> String {
        path.hasPrefix(homeDirectory + "/") ? "~" + path.dropFirst(homeDirectory.count) : path
    }

    /// Filters out system shims that would open an installation dialog instead of running.
    func isUsable(_ path: String) -> Bool {
        switch path {
        case "/usr/bin/python3", "/usr/bin/pip3":
            return HostEnvironment.developerToolsInstalled
        case "/usr/bin/java", "/usr/bin/javac":
            return HostEnvironment.javaRuntimeInstalled(homeDirectory: homeDirectory)
        default:
            return true
        }
    }

    private func managerExecutables(name: String) -> [String] {
        let roots = [
            "\(homeDirectory)/.nvm/versions/node",
            "\(homeDirectory)/.pyenv/versions",
            "/Library/Frameworks/Python.framework/Versions"
        ]
        return roots.flatMap { root -> [String] in
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return versions.sorted(by: versionDescending).map { "\(root)/\($0)/bin/\(name)" }
        }
    }

    private func versionDescending(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) else { return lhs > rhs }
        return right < left
    }
}

actor TechnicalLogger {
    private static let maximumEntries = 5_000
    private(set) var entries: [String] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func log(provider: String, _ message: String) {
        entries.append("[\(formatter.string(from: Date()))] [\(provider)] \(Self.sanitize(message))")
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
    }

    func text() -> String { entries.joined(separator: "\n") }

    func clear() { entries.removeAll() }

    nonisolated static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let rules = [
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/-]+=*"#, "Bearer <redacted>"),
            (#"(?i)\b(token|password|passwd|secret|api[_-]?key)\b(\s*[:=]\s*)\S+"#, "$1$2<redacted>"),
            (#"(?i)\b(authorization)\b(\s*[:=]\s*)(?!Bearer <redacted>)\S+"#, "$1$2<redacted>")
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }
}

/// Resolves which executable the user's login shell would run (NVM, Volta, pyenv… are usually set up in
/// rc files that a Finder-launched app never sees). All names requested together share one shell launch.
actor LoginShellResolver {
    private static let marker = "__ACTUCHOSMAC__"
    private let runner: any ProcessRunning
    private var tasks: [String: Task<String?, Never>] = [:]

    init(runner: any ProcessRunning) { self.runner = runner }

    func path(for name: String) async -> String? {
        await paths(for: [name])[name]
    }

    func paths(for names: [String]) async -> [String: String] {
        let missing = Array(Set(names.filter { tasks[$0] == nil && Self.isSafeName($0) }))
        if !missing.isEmpty {
            let runner = runner
            let batch = Task { await Self.probe(missing, runner: runner) }
            for name in missing { tasks[name] = Task { await batch.value[name] } }
        }
        var result: [String: String] = [:]
        for name in names {
            if let task = tasks[name], let path = await task.value { result[name] = path }
        }
        return result
    }

    private static func probe(_ names: [String], runner: any ProcessRunning) async -> [String: String] {
        let script = "for n in \"$@\"; do p=$(command -v -- \"$n\" 2>/dev/null) && printf '\(marker)%s=%s\\n' \"$n\" \"$p\"; done"
        let result = await runner.run(Command(executable: userShell, arguments: ["-lic", script, "actuchosmac"] + names, timeout: 30))
        var paths: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") where line.hasPrefix(marker) {
            let pair = line.dropFirst(marker.count).split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[1].hasPrefix("/"), FileManager.default.isExecutableFile(atPath: pair[1]) else { continue }
            paths[pair[0]] = pair[1]
        }
        return paths
    }

    private static var userShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let supported = ["zsh", "bash"].contains(URL(fileURLWithPath: shell).lastPathComponent)
        return supported && FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil
    }
}

protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
    /// Follows redirects without downloading a body (used for `github.com/<repo>/releases/latest`).
    func finalURL(for url: URL) async throws -> URL
    /// Downloads a (possibly large) file into `directory` and returns its local URL.
    func download(from url: URL, into directory: URL) async throws -> URL
}

extension HTTPFetching {
    func finalURL(for url: URL) async throws -> URL { throw URLError(.unsupportedURL) }

    func download(from url: URL, into directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        try await data(from: url).write(to: destination)
        return destination
    }
}

/// HTTPS-only, small-response client used for read-only vendor checks (appcasts, release metadata).
struct URLSessionFetcher: HTTPFetching {
    private static let maximumResponseSize = 8_000_000
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    func data(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response)
        guard data.count <= Self.maximumResponseSize else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    func finalURL(for url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await Self.session.data(for: request)
        try Self.validate(response)
        guard let final = response.url else { throw URLError(.badServerResponse) }
        return final
    }

    func download(from url: URL, into directory: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await Self.downloadSession.download(for: request)
        try Self.validate(response)
        guard response.url?.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let destination = directory.appendingPathComponent(name.isEmpty ? "download" : name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static let userAgent = "ActuchosMac/\(HostEnvironment.appVersion) (+https://github.com/BioChosk/ActuchosMac)"

    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

/// Used by demo mode and tests: every request fails as if the Mac were offline.
struct OfflineFetcher: HTTPFetching {
    func data(from url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    func finalURL(for url: URL) async throws -> URL { throw URLError(.notConnectedToInternet) }
    func download(from url: URL, into directory: URL) async throws -> URL { throw URLError(.notConnectedToInternet) }
}

enum PreferenceKey {
    static let scanOnLaunch = "scanOnLaunch"
    static let refreshHomebrewIndex = "refreshHomebrewIndex"
    static let includeGreedyCasks = "includeGreedyCasks"
    static let checkVendorFeeds = "checkVendorFeeds"
    static let includeBetas = "includeBetas"
    static let allowOllamaModelPulls = "updateOllamaModels"
    static let useCaskCatalog = "useCaskCatalog"
    static let quitRunningApps = "quitRunningApps"

    static let defaults: [String: Any] = [
        useCaskCatalog: true,
        quitRunningApps: true,
        scanOnLaunch: true,
        refreshHomebrewIndex: true,
        includeGreedyCasks: false,
        checkVendorFeeds: true,
        includeBetas: false,
        allowOllamaModelPulls: false
    ]
}

struct UpdatePolicy: Sendable {
    var refreshHomebrewIndex = true
    var includeGreedyCasks = false
    var checkVendorFeeds = true
    var includeBetas = false
    var allowOllamaModelPulls = false
    var useCaskCatalog = true
    var quitRunningApps = true

    /// Read on every scan so Settings changes apply without restarting the app.
    static func load(from defaults: UserDefaults = .standard) -> UpdatePolicy {
        defaults.register(defaults: PreferenceKey.defaults)
        return UpdatePolicy(
            refreshHomebrewIndex: defaults.bool(forKey: PreferenceKey.refreshHomebrewIndex),
            includeGreedyCasks: defaults.bool(forKey: PreferenceKey.includeGreedyCasks),
            checkVendorFeeds: defaults.bool(forKey: PreferenceKey.checkVendorFeeds),
            includeBetas: defaults.bool(forKey: PreferenceKey.includeBetas),
            allowOllamaModelPulls: defaults.bool(forKey: PreferenceKey.allowOllamaModelPulls),
            useCaskCatalog: defaults.bool(forKey: PreferenceKey.useCaskCatalog),
            quitRunningApps: defaults.bool(forKey: PreferenceKey.quitRunningApps)
        )
    }
}

struct ProviderContext: Sendable {
    let runner: any ProcessRunning
    let logger: TechnicalLogger
    let homeDirectory: String
    let policy: UpdatePolicy
    let shell: LoginShellResolver
    let http: any HTTPFetching
    let cache: CommandCache

    init(
        runner: any ProcessRunning,
        logger: TechnicalLogger = TechnicalLogger(),
        homeDirectory: String = NSHomeDirectory(),
        policy: UpdatePolicy = UpdatePolicy(),
        http: any HTTPFetching = OfflineFetcher()
    ) {
        self.runner = runner
        self.logger = logger
        self.homeDirectory = homeDirectory
        self.policy = policy
        self.shell = LoginShellResolver(runner: runner)
        self.http = http
        self.cache = CommandCache(runner: runner)
    }

    var locator: ExecutableLocator { ExecutableLocator(homeDirectory: homeDirectory) }
    var architecture: String { HostEnvironment.architecture }

    func executable(named name: String, additionalPaths: [String] = []) -> String? {
        locator.find(name, additionalPaths: additionalPaths)
    }

    /// Runs a read-only command once per scan, even if several providers ask for it.
    func cachedRun(_ command: Command) async -> ProcessResult {
        await cache.run(command)
    }

    /// Homebrew's cask catalog, loaded at most once per scan and only when enabled.
    func caskCatalog() async -> CaskCatalog? {
        guard policy.useCaskCatalog else { return nil }
        return await cache.caskCatalog(context: self)
    }

    /// Prefers the executable the login shell would run, falling back to well-known locations.
    func activeExecutable(named name: String) async -> String? {
        if let path = await shell.path(for: name), locator.isUsable(path) { return path }
        return executable(named: name)
    }
}

/// Shares the output of identical read-only commands (e.g. `brew list --cask`) between providers.
actor CommandCache {
    private let runner: any ProcessRunning
    private var tasks: [String: Task<ProcessResult, Never>] = [:]

    init(runner: any ProcessRunning) { self.runner = runner }

    func run(_ command: Command) async -> ProcessResult {
        let key = command.redactedDescription + command.environment.sorted { $0.key < $1.key }.description
        if let task = tasks[key] { return await task.value }
        let runner = runner
        let task = Task { await runner.run(command) }
        tasks[key] = task
        return await task.value
    }

    private var catalogTask: Task<CaskCatalog?, Never>?

    func caskCatalog(context: ProviderContext) async -> CaskCatalog? {
        if let catalogTask { return await catalogTask.value }
        let task = Task { await CaskCatalog.load(context: context) }
        catalogTask = task
        return await task.value
    }
}

protocol UpdateProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var priority: Int { get }
    func detect(context: ProviderContext) async -> [UpdateItem]
    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem]
    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult?
    /// Re-inventories once and returns the fresh state of each updated item, keyed by the planned item id.
    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem]
}

extension UpdateProvider {
    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] { items }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? { nil }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        let fresh = await check(items: await detect(context: context), context: context)
        var result: [String: UpdateItem] = [:]
        for item in items {
            result[item.id] = fresh.first { $0.id == item.id } ?? fresh.first { $0.deduplicationKey == item.deduplicationKey }
        }
        return result
    }
}

struct AnyUpdateProvider: Sendable {
    let id: String
    let displayName: String
    let priority: Int
    private let detectBlock: @Sendable (ProviderContext) async -> [UpdateItem]
    private let checkBlock: @Sendable ([UpdateItem], ProviderContext) async -> [UpdateItem]
    private let updateBlock: @Sendable (UpdateItem, ProviderContext) async -> ProcessResult?
    private let verifyBlock: @Sendable ([UpdateItem], ProviderContext) async -> [String: UpdateItem]

    init<P: UpdateProvider>(_ provider: P) {
        id = provider.id
        displayName = provider.displayName
        priority = provider.priority
        detectBlock = { context in await provider.detect(context: context) }
        checkBlock = { items, context in await provider.check(items: items, context: context) }
        updateBlock = { item, context in await provider.update(item: item, context: context) }
        verifyBlock = { items, context in await provider.verify(items: items, context: context) }
    }

    func detect(context: ProviderContext) async -> [UpdateItem] {
        await detectBlock(context)
    }

    func check(items: [UpdateItem], context: ProviderContext) async -> [UpdateItem] {
        await checkBlock(items, context)
    }

    func update(item: UpdateItem, context: ProviderContext) async -> ProcessResult? {
        await updateBlock(item, context)
    }

    func verify(items: [UpdateItem], context: ProviderContext) async -> [String: UpdateItem] {
        await verifyBlock(items, context)
    }
}

/// Order-preserving `map` that runs at most `limit` transforms at the same time.
func concurrentMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    limit: Int,
    _ transform: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    await withTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: inputs.count)
        var next = 0
        func enqueue() {
            guard next < inputs.count else { return }
            let index = next
            let input = inputs[index]
            group.addTask { (index, await transform(input)) }
            next += 1
        }
        for _ in 0..<min(max(limit, 1), inputs.count) { enqueue() }
        for await (index, output) in group {
            results[index] = output
            enqueue()
        }
        return results.compactMap { $0 }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
