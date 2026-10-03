import Foundation

enum UpdateCategory: String, Codable, CaseIterable, Sendable {
    case system = "Sistema"
    case applications = "Aplicaciones"
    case development = "Desarrollo"
    case editors = "Editores"
    case packages = "Paquetes"
    case artificialIntelligence = "IA"
    case unmanaged = "No gestionadas"

    var symbol: String {
        switch self {
        case .system: "macbook"
        case .applications: "app.badge"
        case .development: "hammer"
        case .packages: "shippingbox"
        case .editors: "curlybraces"
        case .artificialIntelligence: "brain"
        case .unmanaged: "questionmark.diamond"
        }
    }
}

enum UpdateStatus: String, Codable, Sendable {
    case checking
    case current
    case updateAvailable
    case updating
    case updated
    case intervention
    case selfUpdating
    case unmanaged
    case failed
    case unknown

    var title: String {
        switch self {
        case .checking: "Comprobando"
        case .current: "Al día"
        case .updateAvailable: "Actualización disponible"
        case .updating: "Actualizando"
        case .updated: "Actualizado y verificado"
        case .intervention: "Requiere intervención"
        case .selfUpdating: "Actualizador propio"
        case .unmanaged: "No gestionado"
        case .failed: "Falló"
        case .unknown: "No comprobado"
        }
    }
}

struct UpdateItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var providerID: String
    var name: String
    var category: UpdateCategory
    var installedVersion: String?
    var availableVersion: String?
    var status: UpdateStatus
    var source: String
    var updateMethod: String
    var requiresAdmin: Bool
    var canUpdateAutomatically: Bool
    var path: String?
    var architecture: String?
    var signature: String?
    var notes: String?
    var deduplicationKey: String
    var priority: Int
    var metadata: [String: String]

    init(
        id: String,
        providerID: String,
        name: String,
        category: UpdateCategory,
        installedVersion: String? = nil,
        availableVersion: String? = nil,
        status: UpdateStatus = .checking,
        source: String,
        updateMethod: String,
        requiresAdmin: Bool = false,
        canUpdateAutomatically: Bool = false,
        path: String? = nil,
        architecture: String? = nil,
        signature: String? = nil,
        notes: String? = nil,
        deduplicationKey: String? = nil,
        priority: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.category = category
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.status = status
        self.source = source
        self.updateMethod = updateMethod
        self.requiresAdmin = requiresAdmin
        self.canUpdateAutomatically = canUpdateAutomatically
        self.path = path
        self.architecture = architecture
        self.signature = signature
        self.notes = notes
        self.deduplicationKey = deduplicationKey ?? id
        self.priority = priority
        self.metadata = metadata
    }

    var versionSummary: String {
        let installed = installedVersion ?? "—"
        if let availableVersion, availableVersion != installedVersion {
            return "\(installed) → \(availableVersion)"
        }
        return installed
    }

    /// Items that can only be refreshed on explicit request (no remote check exists),
    /// such as Ollama models or editor extensions. They never enter Update All.
    var isOnDemand: Bool { metadata[MetadataKey.onDemand] == "true" }

    var canRunUpdateNow: Bool {
        canUpdateAutomatically && (status == .updateAvailable || isOnDemand)
    }

    /// Absolute path to the `.app` bundle, when the item is backed by one.
    var appBundlePath: String? { metadata[MetadataKey.appPath] }

    /// URL that opens the place where the user completes a manual update.
    var manualUpdateURL: URL? { metadata[MetadataKey.openURL].flatMap(URL.init(string:)) }

    /// Updates sharing a lock run one after another; different locks run in parallel.
    var lockKey: String { metadata[MetadataKey.lock] ?? providerID }

    func appendingNote(_ note: String) -> UpdateItem {
        var copy = self
        copy.notes = [notes, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return copy
    }
}

enum MetadataKey {
    static let appPath = "appPath"
    static let openURL = "openURL"
    static let onDemand = "onDemand"
    static let caskToken = "caskToken"
    static let masReceipt = "masReceipt"
    static let lock = "lock"
    static let bundleID = "bundleID"
    static let teamID = "teamID"
    static let downloadURL = "downloadURL"
    static let downloadSHA256 = "downloadSHA256"
    static let downloadSHA512 = "downloadSHA512"
    static let edSignature = "edSignature"
    static let edPublicKey = "edPublicKey"
}

struct UpdatePlan: Codable, Sendable {
    var items: [UpdateItem]
    var excludedDuplicates: [UpdateItem]
}

enum VerificationStatus: String, Codable, Sendable {
    case verified = "Verificado"
    case unverified = "No verificado"
    case failed = "Fallido"
    case cancelled = "Cancelado"
}

struct UpdateExecution: Identifiable, Codable, Sendable {
    var id = UUID()
    var itemID: String
    var providerID: String
    var name: String
    var startedAt: Date
    var finishedAt: Date
    var previousVersion: String?
    var expectedVersion: String?
    var finalVersion: String?
    var exitCode: Int32?
    var verification: VerificationStatus
    var summary: String
    var technicalOutput: String
}

struct InventorySnapshot: Codable, Sendable {
    var date: Date
    var model: String
    var macOS: String
    var architecture: String
    var items: [UpdateItem]
    var executions: [UpdateExecution]
}

struct HistoryEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var date: Date
    var checked: Int
    var updated: Int
    var failed: Int
    var intervention: Int
}

/// Lenient version parser for the formats emitted by package managers and bundles:
/// `v22.4.1`, `3.12`, `1.0.0-beta.2`, `141.0b3`, `2.5.0_1` (Homebrew revision), `1.2.3+build`.
struct SemanticVersion: Comparable, Sendable {
    let components: [Int]
    let prerelease: String?

    init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = text.first, first == "v" || first == "V" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }
        if let space = text.firstIndex(of: " ") { text = text[..<space] }

        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
            text = text[..<dash]
        }

        var components: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            let revisionParts = part.split(separator: "_", maxSplits: 1)
            let head = revisionParts.first ?? ""
            let digits = head.prefix { $0.isNumber }
            guard let value = Int(digits) else { break }
            components.append(value)
            let rest = head.dropFirst(digits.count)
            if !rest.isEmpty {
                prerelease = prerelease ?? String(rest)
                break
            }
            if revisionParts.count > 1, let revision = Int(revisionParts[1]) {
                components.append(revision)
                break
            }
        }
        guard !components.isEmpty else { return nil }
        self.components = components
        self.prerelease = prerelease?.isEmpty == true ? nil : prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (.some, .none): return true
        case (.none, .some): return false
        case let (.some(left), .some(right)): return left.compare(right, options: .numeric) == .orderedAscending
        case (.none, .none): return false
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// `true` when `candidate` is strictly newer than `installed`. Unparseable values are never "newer".
    static func isNewer(_ candidate: String?, than installed: String?) -> Bool {
        guard let candidate, let installed,
              let remote = SemanticVersion(candidate), let local = SemanticVersion(installed) else { return false }
        return local < remote
    }
}
