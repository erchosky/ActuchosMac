import Foundation

enum PlanBuilder {
    /// Keeps only automatic updates (or, with a selection, exactly the selected runnable items), orders them
    /// by provider priority and drops items whose deduplication key is owned by a higher-priority provider.
    static func build(from items: [UpdateItem], selection: Set<String>? = nil) -> UpdatePlan {
        let candidates = items.filter { item in
            if let selection { return selection.contains(item.id) && item.canRunUpdateNow }
            return item.status == .updateAvailable && item.canUpdateAutomatically
        }
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.priority < rhs.priority
            }
        var seen = Set<String>()
        var selected: [UpdateItem] = []
        var duplicates: [UpdateItem] = []
        for item in candidates {
            if seen.insert(item.deduplicationKey).inserted { selected.append(item) } else { duplicates.append(item) }
        }
        return UpdatePlan(items: selected, excludedDuplicates: duplicates)
    }

    /// Splits a plan into queues that can run in parallel: items sharing a lock (one package manager,
    /// one interpreter, one app) stay sequential and keep their order.
    static func lockGroups(_ items: [UpdateItem]) -> [[UpdateItem]] {
        var order: [String] = []
        var groups: [String: [UpdateItem]] = [:]
        for item in items {
            if groups[item.lockKey] == nil { order.append(item.lockKey) }
            groups[item.lockKey, default: []].append(item)
        }
        return order.compactMap { groups[$0] }
    }
}

enum UpdateVerifier {
    /// A zero exit code only means "the command finished"; the fresh inventory decides the outcome.
    static func isVerified(planned: UpdateItem, observed: UpdateItem?) -> Bool {
        guard let observed else { return false }
        if observed.status == .current || observed.status == .updated { return true }
        if observed.status == .updateAvailable { return false }
        if let expected = planned.availableVersion, let installed = observed.installedVersion {
            if installed == expected { return true }
            if let local = SemanticVersion(installed), let target = SemanticVersion(expected) { return !(local < target) }
            return false
        }
        return planned.isOnDemand && observed.status != .failed
    }
}

/// Merges overlapping views of the same software so each installation is listed once,
/// owned by the provider that can actually check and update it.
enum InventoryReconciler {
    static let applicationsProviderID = "applications"

    static func reconcile(_ scanned: [UpdateItem]) -> [UpdateItem] {
        var owners = scanned.filter { $0.providerID != applicationsProviderID }
        // Indexes instead of linear searches: this runs on every progressive publish during a scan.
        var byAppPath: [String: Int] = [:]
        var byCaskToken: [String: Int] = [:]
        var byStoreName: [String: Int] = [:]
        for (index, owner) in owners.enumerated() {
            if let path = owner.appBundlePath { byAppPath[path] = byAppPath[path] ?? index }
            if owner.providerID == "homebrew", owner.metadata["kind"] == "cask", let token = owner.metadata["token"] { byCaskToken[token] = index }
            if owner.providerID == "mas", owner.metadata["storeID"] != nil { byStoreName[normalized(owner.name)] = index }
        }

        var applications: [UpdateItem] = []
        for app in scanned where app.providerID == applicationsProviderID {
            var index = app.appBundlePath.flatMap { byAppPath[$0] }
            if index == nil, let token = app.metadata[MetadataKey.caskToken] { index = byCaskToken[token] }
            if index == nil, app.metadata[MetadataKey.masReceipt] == "true" {
                let fileName = URL(fileURLWithPath: app.appBundlePath ?? "").deletingPathExtension().lastPathComponent
                index = byStoreName[normalized(app.name)] ?? byStoreName[normalized(fileName)]
            }
            if let index { owners[index] = merge(app: app, into: owners[index]) } else { applications.append(app) }
        }
        return owners + applications
    }

    private static func merge(app: UpdateItem, into owner: UpdateItem) -> UpdateItem {
        var merged = owner
        if owner.providerID == "homebrew" { merged.name = app.name }
        merged.path = merged.path ?? app.path
        merged.architecture = merged.architecture ?? app.architecture
        merged.signature = merged.signature ?? app.signature
        merged.metadata[MetadataKey.appPath] = merged.metadata[MetadataKey.appPath] ?? app.appBundlePath
        if merged.installedVersion == nil { merged.installedVersion = app.installedVersion }
        return merged
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
