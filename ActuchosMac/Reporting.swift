import Foundation

actor HistoryStore {
    private static let maximumEntries = 100
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActuchosMac", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")
    }

    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        let entries = Array(([entry] + load()).prefix(Self.maximumEntries))
        write(entries)
        return entries
    }

    func clear() {
        write([])
    }

    private func write(_ entries: [HistoryEntry]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Last inventory on disk, so the window is populated instantly while a fresh scan runs.
actor InventoryCache {
    private struct Payload: Codable {
        var date: Date
        var items: [UpdateItem]
    }

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActuchosMac", isDirectory: true)
        fileURL = base.appendingPathComponent("inventory.json")
    }

    func load() -> (date: Date, items: [UpdateItem])? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        return (payload.date, payload.items)
    }

    func save(_ items: [UpdateItem], date: Date) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(Payload(date: date, items: items)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum ReportBuilder {
    static func snapshot(items: [UpdateItem], executions: [UpdateExecution]) -> InventorySnapshot {
        InventorySnapshot(date: Date(), model: HostEnvironment.hardwareModel, macOS: HostEnvironment.macOSVersion,
                          architecture: HostEnvironment.architecture, items: items, executions: executions)
    }

    static func markdown(snapshot: InventorySnapshot) -> String {
        let counts = Dictionary(grouping: snapshot.items, by: \.status).mapValues(\.count)
        var lines = [
            "# Informe ActuchosMac",
            "",
            "- Fecha: \(snapshot.date.formatted(date: .long, time: .standard))",
            "- Mac: \(snapshot.model)",
            "- macOS: \(snapshot.macOS)",
            "- Arquitectura: \(snapshot.architecture)",
            "- Elementos comprobados: \(snapshot.items.count)",
            "- Al día / verificados: \((counts[.updated] ?? 0) + (counts[.current] ?? 0))",
            "- Actualizaciones disponibles: \(counts[.updateAvailable] ?? 0)",
            "- Requieren intervención: \(counts[.intervention] ?? 0)",
            "- Con actualizador propio: \(counts[.selfUpdating] ?? 0)",
            "- No gestionados: \(counts[.unmanaged] ?? 0)",
            "- Fallos: \(counts[.failed] ?? 0)",
            ""
        ]
        for category in UpdateCategory.allCases {
            let items = snapshot.items.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            lines.append("## \(category.rawValue)")
            lines.append("")
            for item in items.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                lines.append("- **\(item.name)** — \(item.versionSummary) — \(item.status.title) — \(item.source)")
            }
            lines.append("")
        }
        if !snapshot.executions.isEmpty {
            lines.append("## Ejecuciones")
            lines.append("")
            for execution in snapshot.executions {
                let versions = "\(execution.previousVersion ?? "—") → \(execution.finalVersion ?? execution.expectedVersion ?? "—")"
                lines.append("- **\(execution.name)** — \(versions) — \(execution.verification.rawValue) — \(execution.summary)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
