import SwiftUI

private enum SidebarItem: Hashable {
    case overview
    case category(UpdateCategory)
}

struct ContentView: View {
    @EnvironmentObject private var store: UpdateStore
    @State private var showLog = false
    @State private var showHistory = false
    @State private var dryRunPlan: UpdatePlan?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 680)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Buscar por nombre, origen o ruta")
        .task { await store.load() }
        .sheet(isPresented: $showLog) { LogSheet(log: store.technicalLog) }
        .sheet(item: $dryRunPlan) { plan in DryRunSheet(plan: plan) }
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .alert("ActuchosMac", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Aceptar") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .toolbar { toolbar }
    }

    // MARK: Sidebar

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { store.selectedCategory.map(SidebarItem.category) ?? .overview },
            set: { selection in
                if case .category(let category) = selection { store.selectedCategory = category } else { store.selectedCategory = nil }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                Label("Estado general", systemImage: "gauge.with.dots.needle.50percent").tag(SidebarItem.overview)
            }
            Section("Categorías") {
                ForEach(UpdateCategory.allCases, id: \.self) { category in
                    HStack {
                        Label(category.rawValue, systemImage: category.symbol)
                        Spacer()
                        let updates = store.summary.categoryUpdates[category] ?? 0
                        if updates > 0 {
                            Text("\(updates)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(store.summary.categoryCounts[category] ?? 0)").foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarItem.category(category))
                }
            }
            Section("Actividad") {
                Button { showHistory = true } label: { Label("Historial", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.plain)
                Button { showLog = true } label: { Label("Log técnico", systemImage: "terminal") }
                    .buttonStyle(.plain)
            }
        }
        .navigationTitle("ActuchosMac")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selectedCategory?.rawValue ?? "Estado general")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(summaryText).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Comprobando \(store.completedProviders)/\(store.providers.count)")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if store.selectedCategory == nil { statusCards }
            if store.isUpdating { updateProgress }
            actions
        }
        .padding(24)
    }

    private var statusCards: some View {
        HStack(spacing: 12) {
            StatusCard(title: "Comprobados", value: store.summary.total, color: .blue, icon: "magnifyingglass",
                       isSelected: false) { store.statusFilter = .all }
            StatusCard(title: "Actualizaciones", value: store.summary.updates, color: .orange, icon: "arrow.down.circle",
                       isSelected: store.statusFilter == .updates) { toggleFilter(.updates) }
            StatusCard(title: "Requieren atención", value: store.summary.attention, color: .red, icon: "exclamationmark.triangle",
                       isSelected: store.statusFilter == .attention) { toggleFilter(.attention) }
            StatusCard(title: "No gestionadas", value: store.summary.unmanaged, color: .secondary, icon: "questionmark.circle",
                       isSelected: false) { store.selectedCategory = .unmanaged }
        }
    }

    private func toggleFilter(_ filter: StatusFilter) {
        store.statusFilter = store.statusFilter == filter ? .all : filter
    }

    private var updateProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isVerifying {
                Text("Verificando versiones instaladas…").font(.headline)
                ProgressView()
            } else {
                let active = store.items.filter { store.activeItemIDs.contains($0.id) }.map(\.name)
                Text("Actualizando \(store.progressCompleted) de \(store.progressTotal)\(active.isEmpty ? "" : " · " + active.joined(separator: ", "))")
                    .font(.headline).lineLimit(1)
                ProgressView(value: Double(store.progressCompleted), total: Double(max(store.progressTotal, 1)))
                if store.cancelRequested {
                    Text("Se detendrá al terminar lo que está en curso").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.scan() }
            } label: { Label("Buscar", systemImage: "arrow.clockwise") }
                .disabled(store.isBusy)
            Button {
                Task { await store.updateAll() }
            } label: {
                Label(store.automaticUpdateCount > 0 ? "Actualizar todo (\(store.automaticUpdateCount))" : "Actualizar todo",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || store.automaticUpdateCount == 0)
            let selected = store.selectedRunnableCount
            Button {
                Task { await store.updateSelected() }
            } label: { Label("Actualizar selección (\(selected))", systemImage: "checkmark.circle") }
                .disabled(store.isBusy || selected == 0)
            if selected > 0 {
                Button("Quitar selección") { store.clearSelection() }.disabled(store.isBusy)
            } else {
                Button("Seleccionar todas") { store.selectAllUpdates(in: store.selectedCategory) }
                    .disabled(store.isBusy || store.automaticUpdateCount == 0)
            }
            Button {
                dryRunPlan = store.dryRunPlan(selectionOnly: selected > 0)
            } label: { Label("Simular", systemImage: "checklist") }
                .disabled(store.isBusy || (store.automaticUpdateCount == 0 && selected == 0))
            if store.isUpdating && !store.isVerifying {
                Button("Cancelar", role: .cancel) { store.cancelUpdates() }.disabled(store.cancelRequested)
            }
            if store.hasFailedExecutions && !store.isBusy {
                Button("Reintentar fallidas") { Task { await store.retryFailed() } }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.isScanning && store.items.isEmpty {
            ContentUnavailableView("Construyendo inventario", systemImage: "macbook.and.iphone",
                                   description: Text("Las comprobaciones son de solo lectura."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.sections.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !store.executions.isEmpty {
                    Section("Última ejecución") {
                        ForEach(store.executions) { execution in ExecutionRow(execution: execution) }
                    }
                }
                ForEach(store.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            UpdateItemRow(
                                item: item,
                                isSelected: store.selection.contains(item.id),
                                isActive: store.activeItemIDs.contains(item.id),
                                isBusy: store.isBusy,
                                actions: rowActions
                            )
                            .equatable()
                        }
                    } header: {
                        SectionHeader(section: section, isBusy: store.isBusy) { store.selectAllUpdates(in: section.category) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var rowActions: RowActions {
        RowActions(
            toggle: { item in store.toggleSelection(item) },
            update: { item in Task { await store.update(item) } },
            openManual: { item in store.openManualUpdate(for: item) },
            reveal: { item in store.revealInFinder(item) }
        )
    }

    @ViewBuilder private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.items.isEmpty {
            ContentUnavailableView {
                Label("Sin inventario", systemImage: "magnifyingglass")
            } description: {
                Text("Pulsa Buscar para inventariar este Mac.")
            }
        } else {
            ContentUnavailableView("Nada que mostrar con este filtro", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Filtro", selection: $store.statusFilter) {
                ForEach(StatusFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .pickerStyle(.menu)
            .help("Filtrar por estado")
            Menu {
                Button("Copiar informe") { store.copyReport() }
                Button("Exportar Markdown…") { store.exportMarkdown() }
                Button("Exportar JSON…") { store.exportJSON() }
            } label: { Label("Informe", systemImage: "square.and.arrow.up") }
                .disabled(store.items.isEmpty)
        }
    }

    private var summaryText: String {
        if store.isDemoMode { return "Modo demostración (\(store.demoScenario?.rawValue ?? "")) · ningún comando real se ejecuta" }
        guard let date = store.lastScanDate else { return "Inventario todavía no realizado" }
        let relative = date.formatted(.relative(presentation: .named))
        if store.isShowingCachedInventory { return "Mostrando el inventario de \(relative) mientras se comprueba de nuevo" }
        let manual = store.summary.updates - store.summary.automatic
        let manualText = manual > 0 ? " · \(manual) se actualizan desde su app o tienda" : ""
        return "\(store.summary.total) elementos · comprobado \(relative)\(manualText)"
    }
}

// MARK: - Rows

struct RowActions {
    var toggle: (UpdateItem) -> Void
    var update: (UpdateItem) -> Void
    var openManual: (UpdateItem) -> Void
    var reveal: (UpdateItem) -> Void
}

private struct SectionHeader: View {
    let section: ItemSection
    let isBusy: Bool
    let selectAll: () -> Void

    var body: some View {
        HStack {
            Text("\(section.category.rawValue) (\(section.items.count))")
            Spacer()
            let updatable = section.items.filter { $0.status == .updateAvailable && $0.canUpdateAutomatically }.count
            if updatable > 0 {
                Button("Seleccionar \(updatable) actualizable\(updatable == 1 ? "" : "s")", action: selectAll)
                    .buttonStyle(.link).font(.caption).disabled(isBusy)
            }
        }
    }
}

private struct StatusCard: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)").font(.title2.bold()).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(isSelected ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? color : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Plain value view: it re-renders only when its own item, selection or activity changes.
private struct UpdateItemRow: View, Equatable {
    let item: UpdateItem
    let isSelected: Bool
    let isActive: Bool
    let isBusy: Bool
    let actions: RowActions

    static func == (lhs: UpdateItemRow, rhs: UpdateItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.isActive == rhs.isActive && lhs.isBusy == rhs.isBusy
    }

    var body: some View {
        HStack(spacing: 12) {
            if item.canRunUpdateNow {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in actions.toggle(item) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(isBusy)
                    .help("Seleccionar para actualizar")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Group {
                if isActive || item.status == .updating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: item.status.symbol).foregroundStyle(item.status.color).font(.title3)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text(item.versionSummary).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    if item.requiresAdmin {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Requiere permisos de administrador")
                    }
                }
                Text([item.source, item.updateMethod, item.architecture, unusualLocation].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(item.status.title).font(.caption.weight(.medium)).foregroundStyle(item.status.color)
            actionButton
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help([item.path, item.signature.map { "Firma: \($0)" }, item.notes].compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            if item.canRunUpdateNow {
                Button("Actualizar ahora") { actions.update(item) }.disabled(isBusy)
                Button(isSelected ? "Quitar de la selección" : "Añadir a la selección") { actions.toggle(item) }
            }
            if item.manualUpdateURL != nil || item.appBundlePath != nil {
                Button(manualActionTitle) { actions.openManual(item) }
            }
            if item.appBundlePath != nil || item.path != nil {
                Button("Mostrar en Finder") { actions.reveal(item) }
            }
            Divider()
            Button("Copiar nombre") { copy(item.name) }
            Button("Copiar versión") { copy(item.versionSummary) }
            if let path = item.path { Button("Copiar ruta") { copy(path) } }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if item.canRunUpdateNow {
            Button(item.isOnDemand ? "Forzar" : "Actualizar") { actions.update(item) }
                .disabled(isBusy)
                .help(item.isOnDemand ? "Ejecuta \(item.updateMethod); no hay forma de saber antes si existe versión nueva" : item.updateMethod)
        } else if [.updateAvailable, .intervention, .selfUpdating].contains(item.status),
                  item.manualUpdateURL != nil || item.appBundlePath != nil {
            Button(manualActionTitle) { actions.openManual(item) }
        }
    }

    /// Shown for bundles outside `/Applications`, so two copies of the same app can be told apart.
    private var unusualLocation: String? {
        guard let path = item.path, path.hasSuffix(".app"), !path.hasPrefix("/Applications/"), !path.hasPrefix("/System/") else { return nil }
        return path
    }

    private var manualActionTitle: String {
        guard let url = item.manualUpdateURL else { return "Abrir app" }
        switch url.scheme {
        case "macappstore": return "Abrir App Store"
        case "x-apple.systempreferences": return "Abrir Ajustes"
        default: return "Abrir web"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ExecutionRow: View {
    let execution: UpdateExecution

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(execution.name).font(.headline)
                Text("\(execution.previousVersion ?? "—") → \(execution.finalVersion ?? execution.expectedVersion ?? "—") · \(execution.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                if execution.verification == .failed, let reason = execution.technicalOutput.split(separator: "\n").last {
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Text(execution.verification.rawValue).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .help(execution.technicalOutput)
    }

    private var symbol: String {
        switch execution.verification {
        case .verified: "checkmark.seal.fill"
        case .unverified: "questionmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch execution.verification {
        case .verified: .green
        case .unverified: .yellow
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

// MARK: - Sheets

private struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Log técnico").font(.title2.bold())
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                .disabled(log.isEmpty)
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(log.isEmpty ? "Sin entradas" : log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 500)
    }
}

private struct DryRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plan: UpdatePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Simulación — ninguna acción ejecutada").font(.title2.bold())
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Este es el plan exacto. Lo que comparte gestor se ejecuta en orden; el resto, en paralelo.").foregroundStyle(.secondary)
            if plan.items.isEmpty {
                ContentUnavailableView("No hay acciones pendientes", systemImage: "checkmark.circle")
            } else {
                List {
                    Section("Se actualizarán (\(plan.items.count))") {
                        ForEach(plan.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("\(item.updateMethod) · \(item.versionSummary)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !plan.excludedDuplicates.isEmpty {
                        Section("Omitidos por duplicados (\(plan.excludedDuplicates.count))") {
                            ForEach(plan.excludedDuplicates) { item in
                                Text("\(item.name) · \(item.source)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 480)
    }
}

private struct HistorySheet: View {
    @EnvironmentObject private var store: UpdateStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Historial local").font(.title2.bold())
                Spacer()
                Button("Borrar historial", role: .destructive) { Task { await store.clearHistory() } }
                    .disabled(store.history.isEmpty)
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if store.history.isEmpty {
                ContentUnavailableView("Sin entradas", systemImage: "clock",
                                       description: Text(store.isDemoMode ? "El modo demostración no guarda historial." : "Cada búsqueda y actualización añade una entrada."))
            } else {
                List(store.history) { entry in
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(entry.checked) revisados · \(entry.updated) actualizados · \(entry.intervention) intervención · \(entry.failed) errores")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440)
    }
}

extension UpdateStatus {
    var symbol: String {
        switch self {
        case .current, .updated: "checkmark.circle.fill"
        case .updateAvailable: "arrow.down.circle.fill"
        case .updating, .checking: "clock.arrow.circlepath"
        case .intervention: "hand.raised.fill"
        case .selfUpdating: "arrow.triangle.2.circlepath.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .unmanaged, .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .current, .updated: .green
        case .updateAvailable: .orange
        case .updating, .checking: .blue
        case .intervention: .yellow
        case .selfUpdating: .teal
        case .failed: .red
        case .unmanaged, .unknown: .secondary
        }
    }
}

extension UpdatePlan: Identifiable {
    var id: String { (items + excludedDuplicates).map(\.id).joined(separator: "|") }
}
