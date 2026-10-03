import AppKit
import Foundation
import UniformTypeIdentifiers

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Todo"
    case updates = "Con actualización"
    case attention = "Requiere atención"
    case current = "Al día"

    var id: String { rawValue }

    func matches(_ item: UpdateItem) -> Bool {
        switch self {
        case .all: true
        case .updates: item.status == .updateAvailable
        case .attention: item.status == .intervention || item.status == .failed
        case .current: item.status == .current || item.status == .updated
        }
    }
}

struct InventorySummary: Equatable {
    var total = 0
    var updates = 0
    var automatic = 0
    var attention = 0
    var unmanaged = 0
    var categoryCounts: [UpdateCategory: Int] = [:]
    var categoryUpdates: [UpdateCategory: Int] = [:]
}

struct ItemSection: Identifiable, Equatable {
    var category: UpdateCategory
    var items: [UpdateItem]
    var id: UpdateCategory { category }
}

@MainActor
final class UpdateStore: ObservableObject {
    private static let maximumParallelQueues = 3

    @Published private(set) var items: [UpdateItem] = [] { didSet { refreshDerivedState() } }
    @Published private(set) var summary = InventorySummary()
    @Published private(set) var sections: [ItemSection] = []
    @Published private(set) var executions: [UpdateExecution] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var technicalLog = ""
    @Published private(set) var isScanning = false
    @Published private(set) var isUpdating = false
    @Published private(set) var isVerifying = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var progressCompleted = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var activeItemIDs: Set<String> = []
    @Published private(set) var completedProviders = 0
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var isShowingCachedInventory = false
    @Published var selectedCategory: UpdateCategory? { didSet { refreshSections() } }
    @Published var statusFilter: StatusFilter = .all { didSet { refreshSections() } }
    @Published var searchText = "" { didSet { refreshSections() } }
    @Published var selection: Set<String> = []
    @Published var errorMessage: String?

    let demoScenario: DemoScenario?
    let providers: [AnyUpdateProvider]
    private let runner: any ProcessRunning
    private let http: any HTTPFetching
    private let logger = TechnicalLogger()
    private let historyStore: HistoryStore?
    private let inventoryCache: InventoryCache?
    private var itemsByProvider: [String: [UpdateItem]] = [:]

    init(demoScenario: DemoScenario? = DemoScenario.current(), runner: any ProcessRunning = ProcessRunner()) {
        // The unit-test bundle is hosted by the app: never inventory or touch the host Mac in that case.
        let scenario = HostEnvironment.isRunningTests ? (demoScenario ?? .clean) : demoScenario
        self.demoScenario = scenario
        self.runner = runner
        if let scenario {
            providers = [AnyUpdateProvider(DemoProvider(scenario: scenario))]
            historyStore = nil
            inventoryCache = nil
            http = OfflineFetcher()
        } else {
            providers = [
                AnyUpdateProvider(AppleSoftwareProvider()),
                AnyUpdateProvider(HomebrewProvider()),
                AnyUpdateProvider(MacAppStoreProvider()),
                AnyUpdateProvider(NVMProvider()),
                AnyUpdateProvider(NodePackagesProvider()),
                AnyUpdateProvider(NPMGlobalPackagesProvider()),
                AnyUpdateProvider(PythonProvider()),
                AnyUpdateProvider(PythonPackagesProvider()),
                AnyUpdateProvider(PythonToolsProvider()),
                AnyUpdateProvider(RubyGemsProvider()),
                AnyUpdateProvider(CargoInstallsProvider()),
                AnyUpdateProvider(RustupProvider()),
                AnyUpdateProvider(DotNetProvider()),
                AnyUpdateProvider(OllamaProvider()),
                AnyUpdateProvider(EditorProvider()),
                AnyUpdateProvider(EcosystemDiscoveryProvider()),
                AnyUpdateProvider(ApplicationInventoryProvider())
            ]
            historyStore = HistoryStore()
            inventoryCache = InventoryCache()
            http = URLSessionFetcher()
        }
    }

    var isDemoMode: Bool { demoScenario != nil }
    var isBusy: Bool { isScanning || isUpdating }
    var automaticUpdateCount: Int { summary.automatic }
    var hasFailedExecutions: Bool { executions.contains { $0.verification == .failed } }

    /// Selected items that can actually run now (selection survives rescans by id).
    var selectedRunnableCount: Int { items.lazy.filter { self.selection.contains($0.id) && $0.canRunUpdateNow }.count }

    // MARK: Loading and scanning

    func load() async {
        history = await historyStore?.load() ?? []
        if items.isEmpty, let cached = await inventoryCache?.load() {
            itemsByProvider = Dictionary(grouping: cached.items, by: \.providerID)
            items = cached.items
            lastScanDate = cached.date
            isShowingCachedInventory = true
        }
        let scanOnLaunch = UserDefaults.standard.object(forKey: PreferenceKey.scanOnLaunch) as? Bool ?? true
        if scanOnLaunch || isDemoMode || items.isEmpty { await scan() }
    }

    /// Every provider publishes its local inventory as soon as it has it, then again once remote checks finish.
    func scan() async {
        guard !isBusy else { return }
        isScanning = true
        completedProviders = 0
        errorMessage = nil
        executions = []
        await logger.clear()
        await logger.log(provider: "ActuchosMac", "Inicio de inventario de solo lectura")
        let context = makeContext()
        var reported = Set<String>()
        await withTaskGroup(of: String.self) { group in
            for provider in providers {
                group.addTask { @MainActor in
                    let detected = await provider.detect(context: context)
                    self.publish(detected, for: provider.id)
                    let checked = await provider.check(items: detected, context: context)
                    self.publish(checked, for: provider.id)
                    return provider.id
                }
            }
            for await providerID in group {
                reported.insert(providerID)
                completedProviders += 1
            }
        }
        itemsByProvider = itemsByProvider.filter { reported.contains($0.key) }
        items = InventoryReconciler.reconcile(itemsByProvider.values.flatMap { $0 })
        lastScanDate = Date()
        isShowingCachedInventory = false
        await logger.log(provider: "ActuchosMac", "Inventario finalizado: \(items.count) elementos")
        technicalLog = await logger.text()
        isScanning = false
        await inventoryCache?.save(items, date: Date())
        await recordHistory(updated: 0)
    }

    private func publish(_ providerItems: [UpdateItem], for providerID: String) {
        itemsByProvider[providerID] = providerItems
        items = InventoryReconciler.reconcile(itemsByProvider.values.flatMap { $0 })
    }

    // MARK: Selection

    func toggleSelection(_ item: UpdateItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else if item.canRunUpdateNow { selection.insert(item.id) }
    }

    /// Selects every automatic update in the given section (or everywhere when `nil`).
    func selectAllUpdates(in category: UpdateCategory? = nil) {
        let ids = items.filter { ($0.status == .updateAvailable && $0.canUpdateAutomatically) && (category == nil || $0.category == category) }.map(\.id)
        selection.formUnion(ids)
    }

    func clearSelection() { selection.removeAll() }

    // MARK: Updating

    func dryRunPlan(selectionOnly: Bool = false) -> UpdatePlan {
        let plan = PlanBuilder.build(from: items, selection: selectionOnly ? selection : nil)
        Task {
            await logger.log(provider: "Simulación", "Plan construido: \(plan.items.count) acciones; 0 ejecutadas")
            technicalLog = await logger.text()
        }
        return plan
    }

    func updateAll() async {
        await execute(PlanBuilder.build(from: items))
    }

    func updateSelected() async {
        await execute(PlanBuilder.build(from: items, selection: selection))
    }

    func update(_ item: UpdateItem) async {
        guard item.canRunUpdateNow else { return }
        await execute(UpdatePlan(items: [item], excludedDuplicates: []))
    }

    func retryFailed() async {
        let failedIDs = Set(executions.filter { $0.verification == .failed }.map(\.itemID))
        await execute(UpdatePlan(items: items.filter { failedIDs.contains($0.id) && $0.canUpdateAutomatically }, excludedDuplicates: []))
    }

    /// Stops starting new items; anything already running finishes, because interrupting an installer is unsafe.
    func cancelUpdates() {
        guard isUpdating, !isVerifying else { return }
        cancelRequested = true
    }

    private func execute(_ plan: UpdatePlan) async {
        guard !isBusy, !plan.items.isEmpty else { return }
        isUpdating = true
        cancelRequested = false
        progressCompleted = 0
        progressTotal = plan.items.count
        activeItemIDs = []
        executions = []
        let context = makeContext()
        var finished: [FinishedUpdate] = []

        var queues = PlanBuilder.lockGroups(plan.items).makeIterator()
        await withTaskGroup(of: [FinishedUpdate].self) { group in
            func startNextQueue() {
                guard let queue = queues.next() else { return }
                group.addTask { @MainActor in await self.run(queue, context: context) }
            }
            for _ in 0..<Self.maximumParallelQueues { startNextQueue() }
            for await done in group {
                finished += done
                startNextQueue()
            }
        }

        await verify(finished)
        activeItemIDs = []
        technicalLog = await logger.text()
        selection.subtract(plan.items.map(\.id))
        isUpdating = false
        cancelRequested = false
        if !NSApplication.shared.isActive { NSApplication.shared.requestUserAttention(.informationalRequest) }
        await inventoryCache?.save(items, date: lastScanDate ?? Date())
        await recordHistory(updated: executions.filter { $0.verification == .verified }.count)
    }

    private struct FinishedUpdate: Sendable {
        var item: UpdateItem
        var result: ProcessResult
        var started: Date
    }

    private func run(_ queue: [UpdateItem], context: ProviderContext) async -> [FinishedUpdate] {
        var finished: [FinishedUpdate] = []
        for planned in queue {
            defer { progressCompleted += 1 }
            if cancelRequested {
                executions.append(execution(for: planned, started: Date(), verification: .cancelled, summary: "Cancelado antes de empezar"))
                continue
            }
            let started = Date()
            activeItemIDs.insert(planned.id)
            setStatus(id: planned.id, status: .updating)
            defer { activeItemIDs.remove(planned.id) }
            guard let provider = provider(for: planned.providerID) else {
                recordFailure(planned, started: started, output: "Proveedor no disponible")
                continue
            }
            await logger.log(provider: provider.displayName, "Actualizando \(planned.name)")
            guard let result = await provider.update(item: planned, context: context) else {
                recordFailure(planned, started: started, output: "El proveedor no produjo una operación segura")
                continue
            }
            await logger.log(provider: provider.displayName, "\(planned.name): exit=\(result.exitCode) en \(result.duration.formatted(.number.precision(.fractionLength(1))))s")
            if result.succeeded {
                setStatus(id: planned.id, status: .checking)
                finished.append(FinishedUpdate(item: planned, result: result, started: started))
            } else {
                recordFailure(planned, started: started, output: result.combinedOutput, exitCode: result.exitCode)
            }
            technicalLog = await logger.text()
        }
        return finished
    }

    /// One fresh check per provider confirms every update it ran; exit code 0 alone is not trusted.
    private func verify(_ finished: [FinishedUpdate]) async {
        guard !finished.isEmpty else { return }
        isVerifying = true
        defer { isVerifying = false }
        var policy = UpdatePolicy.load()
        policy.refreshHomebrewIndex = false
        let context = makeContext(policy: policy)
        let groups = Dictionary(grouping: finished, by: \.item.providerID)
        await withTaskGroup(of: Void.self) { group in
            for (providerID, entries) in groups {
                guard let provider = provider(for: providerID) else { continue }
                group.addTask { @MainActor in
                    let observed = await provider.verify(items: entries.map(\.item), context: context)
                    for entry in entries { self.recordVerification(entry, observed: observed[entry.item.id]) }
                }
            }
        }
    }

    private func recordVerification(_ entry: FinishedUpdate, observed fresh: UpdateItem?) {
        let verified = UpdateVerifier.isVerified(planned: entry.item, observed: fresh)
        if let index = items.firstIndex(where: { $0.id == entry.item.id }) {
            var item = items[index]
            if let installed = fresh?.installedVersion { item.installedVersion = installed }
            if verified {
                item.status = .updated
                item.availableVersion = nil
                item.canUpdateAutomatically = entry.item.isOnDemand
            } else {
                item.status = .intervention
                item = item.appendingNote("La versión instalada no coincide con la esperada; revisa el log")
            }
            replace(item)
        }
        var record = execution(for: entry.item, started: entry.started, verification: verified ? .verified : .unverified,
                               summary: verified ? "Actualización verificada" : "El comando terminó, pero la versión no pudo verificarse")
        record.finalVersion = fresh?.installedVersion
        record.exitCode = entry.result.exitCode
        record.technicalOutput = TechnicalLogger.sanitize(entry.result.combinedOutput)
        executions.append(record)
    }

    private func recordFailure(_ item: UpdateItem, started: Date, output: String, exitCode: Int32? = nil) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var failed = items[index]
            failed.status = .failed
            failed.notes = TechnicalLogger.sanitize(output).split(separator: "\n").last.map(String.init) ?? failed.notes
            replace(failed)
        }
        var record = execution(for: item, started: started, verification: .failed, summary: "Actualización fallida")
        record.exitCode = exitCode
        record.technicalOutput = TechnicalLogger.sanitize(output)
        executions.append(record)
    }

    private func execution(for item: UpdateItem, started: Date, verification: VerificationStatus, summary: String) -> UpdateExecution {
        UpdateExecution(itemID: item.id, providerID: item.providerID, name: item.name, startedAt: started, finishedAt: Date(),
                        previousVersion: item.installedVersion, expectedVersion: item.availableVersion, finalVersion: nil,
                        exitCode: nil, verification: verification, summary: summary, technicalOutput: "")
    }

    // MARK: Actions

    func openManualUpdate(for item: UpdateItem) {
        if let url = item.manualUpdateURL {
            NSWorkspace.shared.open(url)
        } else if let path = item.appBundlePath {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func revealInFinder(_ item: UpdateItem) {
        guard let path = item.appBundlePath ?? item.path.map({ NSString(string: $0).expandingTildeInPath }),
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportBuilder.markdown(snapshot: snapshot()), forType: .string)
    }

    func exportMarkdown() {
        export(data: Data(ReportBuilder.markdown(snapshot: snapshot()).utf8), name: "ActuchosMac-informe.md",
               type: UTType(filenameExtension: "md") ?? .plainText)
    }

    func exportJSON() {
        do {
            export(data: try JSONEncoder.pretty.encode(snapshot()), name: "ActuchosMac-informe.json", type: .json)
        } catch {
            errorMessage = "No se pudo generar el JSON: \(error.localizedDescription)"
        }
    }

    func clearHistory() async {
        await historyStore?.clear()
        history = []
    }

    // MARK: Derived state (computed once per change, not on every render)

    private func refreshDerivedState() {
        var summary = InventorySummary(total: items.count)
        for item in items {
            summary.categoryCounts[item.category, default: 0] += 1
            switch item.status {
            case .updateAvailable:
                summary.updates += 1
                summary.categoryUpdates[item.category, default: 0] += 1
            case .intervention, .failed: summary.attention += 1
            case .unmanaged: summary.unmanaged += 1
            default: break
            }
        }
        summary.automatic = PlanBuilder.build(from: items).items.count
        if self.summary != summary { self.summary = summary }
        refreshSections()
    }

    private func refreshSections() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let visible = items.filter { item in
            (selectedCategory == nil || item.category == selectedCategory)
                && statusFilter.matches(item)
                && (query.isEmpty || [item.name, item.source, item.path ?? "", item.updateMethod].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let grouped = Dictionary(grouping: visible, by: \.category)
        let sections = UpdateCategory.allCases.compactMap { category -> ItemSection? in
            guard let values = grouped[category] else { return nil }
            return ItemSection(category: category, items: values.sorted { lhs, rhs in
                if (lhs.status == .updateAvailable) != (rhs.status == .updateAvailable) { return lhs.status == .updateAvailable }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
        }
        if self.sections != sections { self.sections = sections }
    }

    // MARK: Helpers

    private func makeContext(policy: UpdatePolicy = .load()) -> ProviderContext {
        ProviderContext(runner: runner, logger: logger, homeDirectory: NSHomeDirectory(), policy: policy, http: http)
    }

    private func provider(for id: String) -> AnyUpdateProvider? {
        providers.first { $0.id == id }
    }

    private func setStatus(id: String, status: UpdateStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.status = status
        replace(item)
    }

    /// Keeps `itemsByProvider` in sync so a later progressive publish does not resurrect stale state.
    private func replace(_ item: UpdateItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        if let index = itemsByProvider[item.providerID]?.firstIndex(where: { $0.id == item.id }) {
            itemsByProvider[item.providerID]?[index] = item
        }
    }

    private func recordHistory(updated: Int) async {
        guard let historyStore else { return }
        let entry = HistoryEntry(date: Date(), checked: items.count, updated: updated,
                                 failed: items.filter { $0.status == .failed }.count,
                                 intervention: items.filter { $0.status == .intervention }.count)
        history = await historyStore.append(entry)
    }

    private func snapshot() -> InventorySnapshot {
        ReportBuilder.snapshot(items: items, executions: executions)
    }

    private func export(data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            errorMessage = "No se pudo exportar: \(error.localizedDescription)"
        }
    }
}
