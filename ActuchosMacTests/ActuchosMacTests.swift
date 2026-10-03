import XCTest
@testable import ActuchosMac

/// Returns canned results keyed by `Command.redactedDescription`; never launches a process.
private struct MockProcessRunner: ProcessRunning {
    var responses: [String: ProcessResult] = [:]

    func run(_ command: Command) async -> ProcessResult {
        responses[command.redactedDescription] ?? ProcessResult(
            command: command.redactedDescription, stdout: "", stderr: "No mock response for \(command.redactedDescription)",
            exitCode: -1, duration: 0, timedOut: false
        )
    }
}

private struct StubFetcher: HTTPFetching {
    var responses: [URL: String]

    func data(from url: URL) async throws -> Data {
        guard let body = responses[url] else { throw URLError(.fileDoesNotExist) }
        return Data(body.utf8)
    }
}

private func makeItem(
    id: String, providerID: String = "test", name: String? = nil, key: String? = nil, priority: Int = 10,
    automatic: Bool = true, status: UpdateStatus = .updateAvailable, metadata: [String: String] = [:]
) -> UpdateItem {
    UpdateItem(id: id, providerID: providerID, name: name ?? id, category: .applications,
               installedVersion: "1.0", availableVersion: "2.0", status: status, source: "Test", updateMethod: "Mock",
               canUpdateAutomatically: automatic, deduplicationKey: key, priority: priority, metadata: metadata)
}

final class SemanticVersionTests: XCTestCase {
    func testComparisonPadsMissingComponents() {
        XCTAssertLessThan(SemanticVersion("1.2.3")!, SemanticVersion("1.2.4")!)
        XCTAssertEqual(SemanticVersion("3.12")!, SemanticVersion("3.12.0")!)
        XCTAssertLessThan(SemanticVersion("1.9")!, SemanticVersion("1.10")!)
    }

    func testPrereleaseIsOlderThanRelease() {
        XCTAssertLessThan(SemanticVersion("1.0.0-beta")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("141.0b3")!, SemanticVersion("141.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-beta.2")!, SemanticVersion("1.0.0-beta.10")!)
    }

    func testPackageManagerFormats() {
        XCTAssertEqual(SemanticVersion("v22.4.1")?.components, [22, 4, 1])
        XCTAssertLessThan(SemanticVersion("2.5.0")!, SemanticVersion("2.5.0_1")!)
        XCTAssertEqual(SemanticVersion("15.4 (24E248)")?.components, [15, 4])
        XCTAssertEqual(SemanticVersion("1.2.3+build.7")?.components, [1, 2, 3])
    }

    func testInvalidInputDoesNotCrash() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("N/A"))
        XCTAssertFalse(SemanticVersion.isNewer("N/A", than: "1.0"))
        XCTAssertFalse(SemanticVersion.isNewer(nil, than: "1.0"))
    }
}

final class PlanBuilderTests: XCTestCase {
    func testPlanOnlyContainsAutomaticUpdatesAndDeduplicatesByPriority() {
        let preferred = makeItem(id: "primary", key: "bundle:firefox", priority: 10)
        let duplicate = makeItem(id: "secondary", key: "bundle:firefox", priority: 100)
        let manual = makeItem(id: "manual", key: "bundle:manual", priority: 5, automatic: false)
        let current = makeItem(id: "current", priority: 1, status: .current)

        let plan = PlanBuilder.build(from: [duplicate, manual, preferred, current])

        XCTAssertEqual(plan.items.map(\.id), ["primary"])
        XCTAssertEqual(plan.excludedDuplicates.map(\.id), ["secondary"])
    }

    func testSelectionPlanIncludesOnlySelectedRunnableItems() {
        let a = makeItem(id: "a")
        let b = makeItem(id: "b")
        let manual = makeItem(id: "manual", automatic: false)
        let model = makeItem(id: "model", status: .unknown, metadata: [MetadataKey.onDemand: "true"])
        let plan = PlanBuilder.build(from: [a, b, manual, model], selection: ["b", "manual", "model"])
        XCTAssertEqual(Set(plan.items.map(\.id)), ["b", "model"])
    }

    func testLockGroupsKeepSharedManagersSequential() {
        let brew1 = makeItem(id: "brew1", metadata: [MetadataKey.lock: "homebrew"])
        let app = makeItem(id: "app", metadata: [MetadataKey.lock: "app:x"])
        let brew2 = makeItem(id: "brew2", metadata: [MetadataKey.lock: "homebrew"])
        let groups = PlanBuilder.lockGroups([brew1, app, brew2])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["brew1", "brew2"], ["app"]])
    }

    func testOnDemandItemsNeverEnterUpdateAll() {
        let model = makeItem(id: "model", status: .unknown, metadata: [MetadataKey.onDemand: "true"])
        XCTAssertTrue(model.canRunUpdateNow)
        XCTAssertTrue(PlanBuilder.build(from: [model]).items.isEmpty)
    }
}

final class VerificationTests: XCTestCase {
    func testVerifiedWhenInstalledVersionReachesTarget() {
        let planned = makeItem(id: "a")
        var observed = planned
        observed.status = .unknown
        observed.installedVersion = "2.0"
        XCTAssertTrue(UpdateVerifier.isVerified(planned: planned, observed: observed))
    }

    func testNotVerifiedWhenStillOutdatedOrMissing() {
        let planned = makeItem(id: "a")
        XCTAssertFalse(UpdateVerifier.isVerified(planned: planned, observed: planned))
        XCTAssertFalse(UpdateVerifier.isVerified(planned: planned, observed: nil))
    }

    func testMissingVersionsAreNotTreatedAsMatch() {
        var planned = makeItem(id: "a")
        planned.availableVersion = nil
        var observed = planned
        observed.installedVersion = nil
        observed.status = .unknown
        XCTAssertFalse(UpdateVerifier.isVerified(planned: planned, observed: observed))
    }
}

final class ReconcilerTests: XCTestCase {
    func testCaskBundleIsMergedIntoHomebrewItem() {
        let cask = makeItem(id: "brew:cask:firefox", providerID: "homebrew", name: "firefox", metadata: ["kind": "cask", "token": "firefox"])
        var app = makeItem(id: "app:org.mozilla.firefox", providerID: InventoryReconciler.applicationsProviderID, name: "Firefox",
                           automatic: false, status: .unknown,
                           metadata: [MetadataKey.caskToken: "firefox", MetadataKey.appPath: "/Applications/Firefox.app"])
        app.signature = "Mozilla Corporation"

        let result = InventoryReconciler.reconcile([cask, app])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "brew:cask:firefox")
        XCTAssertEqual(result[0].name, "Firefox")
        XCTAssertEqual(result[0].signature, "Mozilla Corporation")
        XCTAssertEqual(result[0].appBundlePath, "/Applications/Firefox.app")
    }

    func testAppStoreBundleIsMergedByName() {
        let mas = makeItem(id: "mas:1", providerID: "mas", name: "Pixelmator Pro", metadata: ["storeID": "1"])
        let app = makeItem(id: "app:pixelmator", providerID: InventoryReconciler.applicationsProviderID, name: "Pixelmator Pro",
                           automatic: false, status: .unknown,
                           metadata: [MetadataKey.masReceipt: "true", MetadataKey.appPath: "/Applications/Pixelmator Pro.app"])
        XCTAssertEqual(InventoryReconciler.reconcile([mas, app]).map(\.id), ["mas:1"])
    }

    func testUnmatchedBundlesStayVisible() {
        let app = makeItem(id: "app:manual", providerID: InventoryReconciler.applicationsProviderID, status: .unmanaged)
        XCTAssertEqual(InventoryReconciler.reconcile([app]).map(\.id), ["app:manual"])
    }
}

final class ParserTests: XCTestCase {
    func testSoftwareUpdateTitlesAndVersions() {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Sequoia 15.6-24G84
        \tTitle: macOS Sequoia 15.6, Version: 15.6, Size: 1234567KiB, Recommended: YES, Action: restart,
        """
        let updates = AppleSoftwareProvider.parseAvailableUpdates(output + """

        * Label: Command Line Tools for Xcode-16.4
        \tTitle: Command Line Tools for Xcode, Version: 16.4, Size: 900000KiB, Recommended: YES,
        """)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.title, "macOS Sequoia 15.6")
        XCTAssertEqual(updates.first?.version, "15.6")
        XCTAssertTrue(updates[0].isMacOS)
        XCTAssertEqual(updates[1].label, "Command Line Tools for Xcode-16.4")
        XCTAssertFalse(updates[1].isMacOS)
        XCTAssertTrue(AppleSoftwareProvider.parseAvailableUpdates("No new software available.").isEmpty)
    }

    func testMasLines() {
        let provider = MacAppStoreProvider()
        XCTAssertEqual(provider.parseLine("497799835  Xcode  (16.0)")?.installedVersion, "16.0")
        let outdated = provider.parseLine("  1289583905 Pixelmator Pro (3.5 -> 3.6)")
        XCTAssertEqual(outdated?.name, "Pixelmator Pro")
        XCTAssertEqual(outdated?.installedVersion, "3.6")
        XCTAssertEqual(outdated?.metadata["storeID"], "1289583905")
        XCTAssertNil(provider.parseLine("Warning: something"))
    }

    func testHomebrewInstalledList() {
        let items = HomebrewProvider.parseInstalled("git 2.46.0\nopenssl@3 3.3.1 3.3.2\n", kind: "formula", providerID: "homebrew", priority: 20)
        XCTAssertEqual(items.map(\.name), ["git", "openssl@3"])
        XCTAssertEqual(items[1].installedVersion, "3.3.1, 3.3.2")
        XCTAssertEqual(items[0].deduplicationKey, "brew-formula:git")
    }

    func testDotNetListsKeepPathOutOfVersion() {
        let sdks = DotNetProvider.parse("8.0.100 [/usr/local/share/dotnet/sdk]")
        XCTAssertEqual(sdks.first?.version, "8.0.100")
        XCTAssertEqual(sdks.first?.path, "/usr/local/share/dotnet/sdk")
        let runtimes = DotNetProvider.parse("Microsoft.NETCore.App 8.0.0 [/usr/local/share/dotnet/shared/Microsoft.NETCore.App]")
        XCTAssertEqual(runtimes.first?.name, "Microsoft.NETCore.App")
        XCTAssertEqual(runtimes.first?.version, "8.0.0")
    }
}

final class VendorFeedTests: XCTestCase {
    private let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>3.2</title>
          <sparkle:version>320</sparkle:version>
          <sparkle:shortVersionString>3.2</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/app-3.2.zip" length="1" type="application/octet-stream"/>
        </item>
        <item>
          <title>4.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/app-4.0b1.zip" sparkle:version="400" sparkle:shortVersionString="4.0b1"/>
        </item>
        <item>
          <title>9.0</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/app-9.zip" sparkle:version="900" sparkle:shortVersionString="9.0"/>
        </item>
      </channel>
    </rss>
    """

    func testAppcastSelectsNewestCompatibleStableRelease() {
        let releases = AppcastParser.releases(from: Data(appcast.utf8))
        XCTAssertEqual(releases.count, 3)
        XCTAssertEqual(SparkleFeed.latest(in: releases, includeBetas: false, systemVersion: "15.0")?.shortVersion, "3.2")
        XCTAssertEqual(SparkleFeed.latest(in: releases, includeBetas: true, systemVersion: "15.0")?.shortVersion, "4.0b1")
    }

    func testSparkleComparesBuildNumbersFirst() {
        let release = AppcastRelease(version: "320", shortVersion: "3.2")
        XCTAssertTrue(SparkleFeed.isNewer(release, installedBuild: "310", installedVersion: "3.1"))
        XCTAssertFalse(SparkleFeed.isNewer(release, installedBuild: "320", installedVersion: "3.2"))
    }

    func testSparkleCheckUsesInjectedFetcher() async {
        let url = URL(string: "https://example.com/appcast.xml")!
        let context = ProviderContext(runner: MockProcessRunner(), http: StubFetcher(responses: [url: appcast]))
        let result = await SparkleFeed.check(feedURL: url.absoluteString, installedBuild: "300", installedVersion: "3.0", context: context)
        XCTAssertEqual(result, .updateAvailable(version: "3.2", download: DirectDownload(url: URL(string: "https://example.com/app-3.2.zip")!)))
        let insecure = await SparkleFeed.check(feedURL: "http://example.com/appcast.xml", installedBuild: "300", installedVersion: "3.0", context: context)
        guard case .unavailable = insecure else { return XCTFail("HTTP feeds must never be fetched") }
    }

    func testAppcastIgnoresDeltaEnclosures() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <sparkle:version>5</sparkle:version>
          <sparkle:deltas><enclosure url="https://example.com/delta.delta" sparkle:deltaFrom="4"/></sparkle:deltas>
          <enclosure url="https://example.com/full.zip" sparkle:edSignature="c2ln"/>
        </item></channel></rss>
        """
        let release = AppcastParser.releases(from: Data(xml.utf8)).first
        XCTAssertEqual(release?.downloadURL, "https://example.com/full.zip")
        XCTAssertEqual(release?.edSignature, "c2ln")
    }

    func testElectronManifestPicksNativeArchive() {
        let yaml = """
        version: 2.3.0
        files:
          - url: App-2.3.0-x64-mac.zip
            sha512: aW50ZWw=
            size: 1
          - url: App-2.3.0-arm64-mac.zip
            sha512: YXJt
            size: 1
          - url: App-2.3.0.dmg
            sha512: ZG1n
        path: App-2.3.0-x64-mac.zip
        sha512: aW50ZWw=
        """
        let manifest = ElectronUpdaterFeed.manifest(from: yaml)
        XCTAssertEqual(manifest.version, "2.3.0")
        XCTAssertEqual(manifest.files.count, 3)
        XCTAssertEqual(ElectronUpdaterFeed.preferredFile(in: manifest, architecture: "arm64")?.sha512, "YXJt")
        XCTAssertEqual(ElectronUpdaterFeed.preferredFile(in: manifest, architecture: "x86_64")?.url, "App-2.3.0-x64-mac.zip")
    }

    func testCaskCatalogParsesJWSEnvelopeAndPrefersMainToken() throws {
        let casks: [[String: Any]] = [
            ["token": "firefox@beta", "version": "143.0b1", "url": "https://example.com/beta.dmg", "sha256": String(repeating: "b", count: 64),
             "artifacts": [["app": ["Firefox.app"]]]],
            ["token": "firefox", "version": "142.0.1", "url": "https://example.com/ff.dmg", "sha256": String(repeating: "a", count: 64),
             "artifacts": [["app": ["Firefox.app"]], ["zap": ["trash": "~/x"]]]],
            ["token": "daisydisk", "version": "4.33.3,170", "url": "https://example.com/dd.zip", "sha256": "no_check",
             "artifacts": [["app": ["DaisyDisk.app"]]]],
            ["token": "office", "version": "16.90", "url": "https://example.com/office.pkg", "sha256": String(repeating: "c", count: 64),
             "artifacts": [["pkg": ["Office.pkg"]], ["app": ["Microsoft Word.app"]]]],
            ["token": "insecure", "version": "1.0", "url": "http://example.com/x.zip", "artifacts": [["app": ["Insecure.app"]]]]
        ]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: casks), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": payload, "signatures": []])
        let catalog = try XCTUnwrap(CaskCatalog.parse(envelope))
        XCTAssertEqual(catalog.entry(forAppNamed: "Firefox.app")?.token, "firefox")
        XCTAssertEqual(catalog.entry(forAppNamed: "firefox.app")?.sha256, String(repeating: "a", count: 64))
        XCTAssertNil(catalog.entry(forAppNamed: "DaisyDisk.app")?.sha256)
        XCTAssertEqual(CaskCatalog.marketingVersion("4.33.3,170"), "4.33.3")
        XCTAssertEqual(catalog.entry(forAppNamed: "Microsoft Word.app")?.installsWithPackage, true)
        XCTAssertNil(catalog.entry(forAppNamed: "Insecure.app"))
    }

    func testOnlyArchivesAreInstallable() {
        XCTAssertTrue(DirectDownload(url: URL(string: "https://x.com/a.zip")!).isInstallable)
        XCTAssertTrue(DirectDownload(url: URL(string: "https://x.com/a.dmg")!).isInstallable)
        XCTAssertFalse(DirectDownload(url: URL(string: "https://x.com/a.pkg")!).isInstallable)
    }

    func testElectronUpdaterFeedURLs() {
        let github = ElectronUpdaterFeed.feedURL(fromConfiguration: "owner: acme\nrepo: desktop\nprovider: github\nupdaterCacheDirName: acme-updater\n")
        XCTAssertEqual(github?.absoluteString, "https://github.com/acme/desktop/releases/latest/download/latest-mac.yml")
        let generic = ElectronUpdaterFeed.feedURL(fromConfiguration: "provider: generic\nurl: https://downloads.example.com/releases\nchannel: stable\n")
        XCTAssertEqual(generic?.absoluteString, "https://downloads.example.com/releases/stable-mac.yml")
        XCTAssertNil(ElectronUpdaterFeed.feedURL(fromConfiguration: "provider: generic\nurl: http://insecure.example.com\n"))
        XCTAssertNil(ElectronUpdaterFeed.feedURL(fromConfiguration: "provider: github\nowner: acme\nrepo: x\nprivate: true\n"))
        XCTAssertEqual(ElectronUpdaterFeed.version(fromManifest: "version: 1.4.2\nfiles:\n  - url: App.zip\nreleaseDate: '2026-01-01'\n"), "1.4.2")
    }
}

final class PackageParserTests: XCTestCase {
    func testGemOutdated() {
        let parsed = RubyGemsProvider.parseOutdated("rake (13.0.6 < 13.2.1)\nbundler (2.4.10, 2.3.0 < 2.5.22)\n")
        XCTAssertEqual(parsed.map(\.name), ["rake", "bundler"])
        XCTAssertEqual(parsed[1].installed, "2.4.10")
        XCTAssertEqual(parsed[1].latest, "2.5.22")
    }

    func testCargoInstallList() {
        let parsed = CargoInstallsProvider.parseInstallList("ripgrep v14.1.0:\n    rg\nlocal-tool v0.1.0 (/Users/me/tool):\n    tool\n")
        XCTAssertEqual(parsed.map(\.name), ["ripgrep"])
        XCTAssertEqual(parsed.first?.version, "14.1.0")
    }

    func testPipxAndUVTools() {
        let pipx = PythonToolsProvider.parsePipx(#"{"venvs": {"black": {"metadata": {"main_package": {"package": "black", "package_version": "24.4.2"}}}}}"#)
        XCTAssertEqual(pipx.first?.name, "black")
        XCTAssertEqual(pipx.first?.version, "24.4.2")
        let uv = PythonToolsProvider.parseUVTools("ruff v0.6.9\n- ruff\nhttpie v3.2.3\n- http\n- https\n")
        XCTAssertEqual(uv.map(\.name), ["ruff", "httpie"])
        XCTAssertEqual(uv.last?.version, "3.2.3")
    }

    func testRustupCheck() {
        let output = """
        stable-aarch64-apple-darwin - Update available : 1.80.1 (3f5fd8dd4 2024-08-06) -> 1.81.0 (eeb90cda1 2024-09-04)
        nightly-aarch64-apple-darwin - Up to date : 1.83.0-nightly (abc 2024-10-01)
        rustup - Up to date : 1.27.1
        """
        let parsed = RustupProvider.parseCheck(output)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].installed, "1.80.1")
        XCTAssertEqual(parsed[0].available, "1.81.0")
        XCTAssertNil(parsed[1].available)
        XCTAssertEqual(parsed[2].name, "rustup")
    }

    func testFirstVersionExtraction() {
        XCTAssertEqual(LatestRelease.firstVersion(in: "deno 2.0.0 (stable, release, aarch64-apple-darwin)"), "2.0.0")
        XCTAssertEqual(LatestRelease.firstVersion(in: "bun-v1.1.30"), "1.1.30")
        XCTAssertEqual(LatestRelease.firstVersion(in: "go version go1.23.2 darwin/arm64"), "1.23.2")
        XCTAssertNil(LatestRelease.firstVersion(in: "no version here"))
    }
}

final class SafetyTests: XCTestCase {
    func testTechnicalLoggerRedactsSecrets() {
        let sanitized = TechnicalLogger.sanitize("token=abc123 password: supersecret Authorization: Bearer xyz.987")
        XCTAssertFalse(sanitized.contains("abc123"))
        XCTAssertFalse(sanitized.contains("supersecret"))
        XCTAssertFalse(sanitized.contains("xyz.987"))
        XCTAssertTrue(sanitized.contains("token=<redacted>"))
    }

    func testCommandDescriptionRedactsSensitiveArguments() {
        let command = Command(executable: "/usr/bin/tool", arguments: ["--token=abc", "safe value"])
        XCTAssertEqual(command.redactedDescription, "/usr/bin/tool <redacted> \"safe value\"")
    }

    func testProcessRunnerReportsExitCodeAndOutput() async {
        let result = await ProcessRunner().run(Command(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
    }

    func testProcessRunnerEnforcesTimeout() async {
        let result = await ProcessRunner().run(Command(executable: "/bin/sleep", arguments: ["10"], timeout: 0.5))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.duration, 5)
    }

    func testProcessRunnerDrainsLargeOutputWithoutDeadlock() async {
        let result = await ProcessRunner().run(Command(executable: "/bin/sh", arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' a"], timeout: 20))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 2_000_000)
    }

    func testMissingExecutableFailsGracefully() async {
        let result = await ProcessRunner().run(Command(executable: "/nonexistent/tool", arguments: []))
        XCTAssertEqual(result.exitCode, -1)
    }
}

final class PortableFixtureTests: XCTestCase {
    private let context = ProviderContext(runner: MockProcessRunner(), homeDirectory: "/Users/testuser")

    func testEveryDemoScenarioRunsWithoutHostTools() async {
        for scenario in DemoScenario.allCases {
            let items = await DemoProvider(scenario: scenario).detect(context: context)
            XCTAssertFalse(items.isEmpty, "Fixture \(scenario.rawValue) should contain synthetic inventory")
            XCTAssertFalse(items.contains { ($0.path ?? "").contains(NSHomeDirectory()) })
        }
    }

    func testMultipleNodeFixtureIdentifiesActiveAndAdditionalInstallations() async {
        let items = await DemoProvider(scenario: .multipleNode).detect(context: context)
        XCTAssertTrue(items.contains { $0.name.contains("activo") && $0.source == "NVM" })
        XCTAssertTrue(items.contains { $0.name.contains("adicional") && $0.source == "Homebrew" })
    }

    func testDemoArgumentParsing() {
        XCTAssertNil(DemoScenario.current(arguments: ["ActuchosMac"]))
        XCTAssertEqual(DemoScenario.current(arguments: ["ActuchosMac", "--demo"]), .developer)
        XCTAssertEqual(DemoScenario.current(arguments: ["ActuchosMac", "--demo=many-updates"]), .manyUpdates)
        XCTAssertEqual(DemoScenario.current(arguments: ["ActuchosMac", "--demo=unknown"]), .developer)
    }

    @MainActor
    func testDemoStoreUpdatesAndVerifies() async {
        let store = UpdateStore(demoScenario: .manyUpdates, runner: MockProcessRunner())
        await store.scan()
        XCTAssertEqual(store.automaticUpdateCount, 13)
        await store.updateAll()
        XCTAssertEqual(store.automaticUpdateCount, 0)
        XCTAssertEqual(store.executions.filter { $0.verification == .verified }.count, 13)
        XCTAssertFalse(store.isUpdating)
    }

    @MainActor
    func testDemoStoreUpdatesOnlySelection() async {
        let store = UpdateStore(demoScenario: .manyUpdates, runner: MockProcessRunner())
        await store.scan()
        let chosen = store.items.filter { $0.canRunUpdateNow }.prefix(2).map(\.id)
        chosen.forEach { id in store.toggleSelection(store.items.first { $0.id == id }!) }
        XCTAssertEqual(store.selectedRunnableCount, 2)
        await store.updateSelected()
        XCTAssertEqual(store.executions.count, 2)
        XCTAssertEqual(store.automaticUpdateCount, 11)
        XCTAssertTrue(store.selection.isEmpty)
    }
}

/// Opt-in end-to-end check of the verified installer against a real vendor feed, run on a *copy* of an app.
/// `TEST_RUNNER_ACTUCHOS_INTEGRATION_APP=/Applications/Some.app xcodebuild test -only-testing:ActuchosMacTests/InstallerIntegrationTests`
final class InstallerIntegrationTests: XCTestCase {
    func testInstallsNewerVersionOverCopyOfApp() async throws {
        guard let source = ProcessInfo.processInfo.environment["ACTUCHOS_INTEGRATION_APP"] else {
            throw XCTSkip("Define ACTUCHOS_INTEGRATION_APP para ejecutar la prueba de instalación real")
        }
        let info = try XCTUnwrap(Bundle(path: source)?.infoDictionary)
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String, "La app de prueba necesita un feed Sparkle")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ActuchosIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let copy = workspace.appendingPathComponent(URL(fileURLWithPath: source).lastPathComponent).path
        try FileManager.default.copyItem(atPath: source, toPath: copy)

        var policy = UpdatePolicy()
        policy.quitRunningApps = false
        let context = ProviderContext(runner: ProcessRunner(), policy: policy, http: URLSessionFetcher())
        // Pretend the copy is one release behind so the feed always offers an update.
        let result = await SparkleFeed.check(feedURL: feed, installedBuild: "0", installedVersion: "0.0.1", context: context)
        guard case .updateAvailable(let version, let download) = result else { return XCTFail("Feed sin actualización: \(result)") }

        var item = UpdateItem(id: "integration", providerID: "applications", name: "Prueba", category: .applications,
                              installedVersion: "0.0.1", availableVersion: version, status: .updateAvailable,
                              source: "Prueba", updateMethod: "Prueba", priority: 0)
        AppInstaller.prepare(&item, appPath: copy, download: download)
        item.metadata[MetadataKey.edPublicKey] = info["SUPublicEDKey"] as? String
        XCTAssertTrue(item.canUpdateAutomatically, "La descarga debería poder verificarse")

        let install = await AppInstaller.install(item, context: context)
        print("INSTALL RESULT:", install.stdout, install.stderr)
        XCTAssertTrue(install.succeeded, install.stderr)
        XCTAssertEqual(AppInstaller.observe(item)?.installedVersion, version)
        XCTAssertEqual(CodeSignature.info(forAppAt: copy).teamID, item.metadata[MetadataKey.teamID])
    }
}
