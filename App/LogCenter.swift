import Foundation
import SwiftUI
import MediaCore
import UIKit

enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    case info, reseau, kdrive, erreur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .info: return L("Infos", "Info")
        case .reseau: return L("Réseau", "Network")
        case .kdrive: return "kDrive"
        case .erreur: return L("Erreurs", "Errors")
        }
    }
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .reseau: return "network"
        case .kdrive: return "icloud.fill"
        case .erreur: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .info: return DS.onSurfaceMuted
        case .reseau: return DS.accentEmphasis
        case .kdrive: return DS.calmSage
        case .erreur: return DS.calmRose
        }
    }
}

struct LogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let message: String

    init(id: UUID = UUID(), date: Date, level: LogLevel, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

struct LogLevelCounts: Equatable, Sendable {
    let total: Int
    let byLevel: [LogLevel: Int]

    func count(for level: LogLevel) -> Int {
        byLevel[level] ?? 0
    }
}

@MainActor @Observable
final class LogCenter {
    static let shared = LogCenter()
    private(set) var entries: [LogEntry] = []
    private(set) var errorCount = 0

    private static let maxMemory = 10_000
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let ioQueue = DispatchQueue(label: "LogCenter.io", qos: .utility)

    private let fileURL0: URL
    private let fileURL1: URL
    @ObservationIgnored private let isoFormatter = ISO8601DateFormatter()
    @ObservationIgnored private var pendingBuffer: [LogEntry] = []
    @ObservationIgnored private var uiFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDiskLines: [String] = []
    @ObservationIgnored private var diskFlushScheduled = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        fileURL0 = dir.appendingPathComponent("log-0.txt")
        fileURL1 = dir.appendingPathComponent("log-1.txt")
        let url0 = fileURL0
        let url1 = fileURL1
        Task.detached(priority: .utility) {
            let loaded = Self.readFromDisk(url0: url0, url1: url1)
            await MainActor.run {
                let current = LogCenter.shared
                if !loaded.entries.isEmpty {
                    let combined = (loaded.entries + current.entries)
                    let trimmed = combined.count > Self.maxMemory ? Array(combined.suffix(Self.maxMemory)) : combined
                    current.entries = trimmed
                    current.errorCount = trimmed.reduce(0) { $0 + ($1.level == .erreur ? 1 : 0) }
                }
            }
        }
        addSync(level: .info, message: L("Journal démarré.", "Log started."))
    }

    // Appel simple depuis n'importe où, même hors Main : ne bloque jamais.
    nonisolated static func log(level: LogLevel, _ message: String) {
        let clean = sanitize(message)
        Task { @MainActor in
            shared.addSync(level: level, message: clean)
        }
    }
    nonisolated static func info(_ message: String) { log(level: .info, message) }
    nonisolated static func net(_ message: String) { log(level: .reseau, message) }
    nonisolated static func kdrive(_ message: String) { log(level: .kdrive, message) }
    nonisolated static func err(_ message: String) { log(level: .erreur, message) }

    /// Ne jamais enregistrer de secret : jetons, cookies, liens privés.
    nonisolated static func sanitize(_ message: String) -> String {
        LogDiagnostics.sanitize(message)
    }

    private func addSync(level: LogLevel, message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        if level == .erreur {
            flushPendingEntries()
            appendEntry(entry)
        } else {
            pendingBuffer.append(entry)
            if uiFlushTask == nil {
                uiFlushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self?.flushPendingEntries()
                }
            }
        }
        let line = "\(isoFormatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)\n"
        pendingDiskLines.append(line)
        if pendingDiskLines.count >= 25 {
            flushDiskLines()
        } else if !diskFlushScheduled {
            diskFlushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.flushDiskLines()
            }
        }
    }

    private func appendEntry(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > Self.maxMemory {
            entries.removeFirst(entries.count - Self.maxMemory)
        }
        if entry.level == .erreur { errorCount += 1 }
    }

    private func flushPendingEntries() {
        uiFlushTask?.cancel()
        uiFlushTask = nil
        guard !pendingBuffer.isEmpty else { return }
        let batch = pendingBuffer
        pendingBuffer.removeAll(keepingCapacity: true)
        var next = entries
        next.append(contentsOf: batch)
        if next.count > Self.maxMemory {
            next.removeFirst(next.count - Self.maxMemory)
        }
        entries = next
        let addedErrors = batch.reduce(0) { $0 + ($1.level == .erreur ? 1 : 0) }
        if addedErrors > 0 { errorCount += addedErrors }
    }

    private func flushDiskLines() {
        diskFlushScheduled = false
        guard !pendingDiskLines.isEmpty else { return }
        let payload = pendingDiskLines.joined()
        pendingDiskLines.removeAll(keepingCapacity: true)
        let url0 = fileURL0
        let url1 = fileURL1
        let maxBytes = Self.maxFileBytes
        Self.ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url0.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url0.path)[.size] as? Int), size > maxBytes {
                try? fm.removeItem(at: url1)
                try? fm.moveItem(at: url0, to: url1)
            }
            guard let data = payload.data(using: .utf8) else { return }
            if !fm.fileExists(atPath: url0.path) { try? data.write(to: url0) }
            else if let handle = try? FileHandle(forWritingTo: url0) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    func clear() {
        uiFlushTask?.cancel()
        uiFlushTask = nil
        pendingBuffer.removeAll()
        pendingDiskLines.removeAll()
        diskFlushScheduled = false
        entries = []
        errorCount = 0
        let url0 = fileURL0
        let url1 = fileURL1
        Self.ioQueue.async {
            try? FileManager.default.removeItem(at: url0)
            try? FileManager.default.removeItem(at: url1)
        }
        addSync(level: .info, message: L("Journal effacé.", "Log cleared."))
    }

    /// Force l'intégration immédiate du tampon dans `entries` (à appeler en dehors de `View.body`).
    func flushNow() {
        flushPendingEntries()
    }

    nonisolated static func filterEntries(
        _ entries: [LogEntry],
        level: LogLevel?,
        search: String,
        newestFirst: Bool = false
    ) -> [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter { entry in
            if let level, entry.level != level { return false }
            if needle.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(needle)
        }
        return newestFirst ? matches.reversed() : matches
    }

    nonisolated static func countEntries(
        _ entries: [LogEntry],
        search: String
    ) -> LogLevelCounts {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var counts: [LogLevel: Int] = [:]
        var total = 0
        for entry in entries {
            if !needle.isEmpty, !entry.message.localizedCaseInsensitiveContains(needle) {
                continue
            }
            total += 1
            counts[entry.level, default: 0] += 1
        }
        return LogLevelCounts(total: total, byLevel: counts)
    }

    func filtered(level: LogLevel?, search: String, newestFirst: Bool = false) -> [LogEntry] {
        Self.filterEntries(entries, level: level, search: search, newestFirst: newestFirst)
    }

    func counts(search: String = "") -> LogLevelCounts {
        Self.countEntries(entries, search: search)
    }

    func formattedLine(for entry: LogEntry) -> String {
        "\(isoFormatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)"
    }

    /// Texte d'export : par onglet (`level`) ou tout l'historique si nil,
    /// restreint à la recherche courante si fournie. Léger, partageable.
    func exportText(level: LogLevel? = nil, search: String = "") -> String {
        let scope: String
        if let level { scope = level.rawValue } else { scope = L("tout", "all") }
        var text = "RedditMediaPocket logs (\(scope)) — \(Date())\n"
        let needle = search.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            text += L("Filtre recherche : \(needle)\n", "Search filter: \(needle)\n")
        }
        text += "\n"
        let formatter = ISO8601DateFormatter()
        for e in entries where level == nil || e.level == level {
            if !needle.isEmpty, !e.message.localizedCaseInsensitiveContains(needle) { continue }
            text += "\(formatter.string(from: e.date)) [\(e.level.rawValue)] \(e.message)\n"
        }
        return text
    }

    /// Copie du journal dans le presse-papiers : les applications qui n'acceptent
    /// pas les fichiers n'ont besoin que du texte.
    func copyToPasteboard(level: LogLevel? = nil, search: String = "") {
        flushPendingEntries()
        UIPasteboard.general.string = exportText(level: level, search: search)
    }

    /// Fichier d'export : même contenu que la copie, matérialisé en .txt.
    func exportFile(level: LogLevel? = nil, search: String = "") -> URL {
        flushPendingEntries()
        let scope: String
        if let level { scope = level.rawValue } else { scope = L("tout", "all") }
        let stamp = Int(Date().timeIntervalSince1970)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-logs-\(scope)-\(stamp).txt")
        try? exportText(level: level, search: search).write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    nonisolated private static func readFromDisk(url0: URL, url1: URL) -> (entries: [LogEntry], errorCount: Int) {
        var lines: [String] = []
        for url in [url1, url0] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.maxMemory).map(String.init))
        }
        let tail = lines.suffix(Self.maxMemory)
        let formatter = ISO8601DateFormatter()
        var loaded: [LogEntry] = []
        var errors = 0
        for line in tail {
            // Format : date [niveau] message — tolérant si date illisible.
            let level: LogLevel = line.contains("[erreur]") ? .erreur : (line.contains("[reseau]") ? .reseau : (line.contains("[kdrive]") ? .kdrive : .info))
            let date = formatter.date(from: String(line.prefix(20))) ?? Date()
            let message: String = {
                if let idx = line.firstIndex(of: "]") {
                    return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                }
                return line
            }()
            if message.isEmpty { continue }
            if level == .erreur { errors += 1 }
            loaded.append(LogEntry(date: date, level: level, message: message))
        }
        return (loaded, errors)
    }
}

struct LogsButton: View {
    @State private var logs = LogCenter.shared
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "doc.text.magnifyingglass")
                if logs.errorCount > 0 {
                    Circle().fill(DS.error).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(DS.onAccent, lineWidth: 1.5))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .accessibilityLabel(L("Journal de bord", "Logs"))
        .accessibilityValue(logs.errorCount > 0 ? L("\(logs.errorCount) erreurs", "\(logs.errorCount) errors") : L("Aucune erreur", "No errors"))
        .sheet(isPresented: $presented) { LogsView() }
    }
}

@MainActor
private enum LogTimestampFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm:ss"
        return f
    }()

    static func string(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return timeOnly.string(from: date)
        }
        return dayAndTime.string(from: date)
    }
}

private struct LogEntryRow: View, Equatable {
    let entry: LogEntry
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.space(2)) {
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.level.tint)
                .frame(width: 3)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: compact ? 2 : DS.space(1)) {
                HStack(spacing: DS.space(2)) {
                    HStack(spacing: 4) {
                        Image(systemName: entry.level.icon)
                            .font(.caption2.weight(.semibold))
                        Text(entry.level.label)
                            .font(DS.caption2.weight(.semibold))
                    }
                    .foregroundStyle(entry.level.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.level.tint.opacity(0.12), in: Capsule())

                    Spacer(minLength: DS.space(2))

                    Text(LogTimestampFormatter.string(for: entry.date))
                        .font(DS.monoCaption)
                        .foregroundStyle(DS.onSurfaceMuted)
                }

                Text(entry.message)
                    .font(compact ? .caption : .footnote)
                    .foregroundStyle(DS.onSurface)
                    .lineSpacing(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.space(3))
        .padding(.vertical, compact ? DS.space(2) : DS.space(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            entry.level == .erreur
                ? DS.calmRose.opacity(0.08)
                : DS.surface,
            in: RoundedRectangle(cornerRadius: DS.radiusM)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM)
                .stroke(
                    entry.level == .erreur
                        ? DS.calmRose.opacity(0.28)
                        : DS.separator.opacity(0.55),
                    lineWidth: 0.75
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.label), \(LogTimestampFormatter.string(for: entry.date)) : \(entry.message)")
    }
}

struct LogsView: View {
    @State private var logs = LogCenter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: LogLevel?
    @State private var search = ""
    @State private var exportURL: URL?
    @State private var copiedFeedback: String?
    @State private var confirmClear = false
    @AppStorage("logs.newestFirst") private var newestFirst = true
    @AppStorage("logs.compactMode") private var compactMode = false
    @State private var autoFollow = true

    private var hasActiveFilter: Bool {
        level != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let counts = logs.counts(search: search)
        let visible = logs.filtered(level: level, search: search, newestFirst: newestFirst)

        return NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    filterHeader(counts: counts, visibleCount: visible.count, proxy: proxy, visible: visible)
                    Divider().overlay(DS.separator)

                    if visible.isEmpty {
                        emptyState
                    } else {
                        List(visible) { entry in
                            LogEntryRow(entry: entry, compact: compactMode)
                                .equatable()
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = logs.formattedLine(for: entry)
                                        showCopiedFeedback(L("Ligne copiée", "Line copied"))
                                    } label: {
                                        Label(L("Copier la ligne", "Copy line"), systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        UIPasteboard.general.string = entry.message
                                        showCopiedFeedback(L("Message copié", "Message copied"))
                                    } label: {
                                        Label(L("Copier le message", "Copy message"), systemImage: "text.quote")
                                    }
                                    Divider()
                                    if level == entry.level {
                                        Button {
                                            level = nil
                                        } label: {
                                            Label(L("Afficher tous les niveaux", "Show all levels"), systemImage: "line.3.horizontal.decrease.circle")
                                        }
                                    } else {
                                        Button {
                                            level = entry.level
                                        } label: {
                                            Label(L("Filtrer : \(entry.level.label)", "Filter: \(entry.level.label)"), systemImage: entry.level.icon)
                                        }
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(
                                    top: compactMode ? 3 : 5,
                                    leading: DS.space(4),
                                    bottom: compactMode ? 3 : 5,
                                    trailing: DS.space(4)
                                ))
                                .id(entry.id)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(DS.background)
                        .onChange(of: logs.entries.count) { _, _ in
                            guard autoFollow else { return }
                            let target = newestFirst ? visible.first : visible.last
                            guard let target else { return }
                            let anchor: UnitPoint = newestFirst ? .top : .bottom
                            if reduceMotion {
                                proxy.scrollTo(target.id, anchor: anchor)
                            } else {
                                withAnimation(DS.micro) { proxy.scrollTo(target.id, anchor: anchor) }
                            }
                        }
                    }
                }
                .background(DS.background)
                .overlay(alignment: .bottom) {
                    if let copiedFeedback {
                        Label(copiedFeedback, systemImage: "checkmark.circle.fill")
                            .font(DS.caption)
                            .foregroundStyle(DS.onAccent)
                            .padding(.horizontal, DS.space(4))
                            .padding(.vertical, DS.space(2))
                            .background(DS.accent, in: Capsule())
                            .shadow(
                                color: DS.shadowColor.opacity(DS.shadowOpacity),
                                radius: DS.shadowRadius,
                                y: DS.shadowY
                            )
                            .padding(.bottom, DS.space(4))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            .searchable(text: $search, prompt: L("Filtrer le journal…", "Filter logs…"))
            .navigationTitle(L("Journal de bord", "Logs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle(isOn: $newestFirst) {
                            Label(L("Plus récents en premier", "Newest first"), systemImage: "arrow.up.arrow.down")
                        }
                        Toggle(isOn: $compactMode) {
                            Label(L("Affichage compact", "Compact display"), systemImage: "rectangle.compress.vertical")
                        }
                        Toggle(isOn: $autoFollow) {
                            Label(L("Suivi automatique", "Auto-follow"), systemImage: "arrow.down.to.line")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label(L("Effacer le journal", "Clear logs"), systemImage: "trash")
                        }
                        .disabled(logs.entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L("Options du journal", "Log options"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            logs.copyToPasteboard(level: level, search: search)
                            showCopiedFeedback(L("Vue copiée", "View copied"))
                        } label: {
                            Label(L("Copier la vue filtrée", "Copy filtered view"), systemImage: "doc.on.doc")
                        }
                        .disabled(visible.isEmpty)
                        Button {
                            logs.copyToPasteboard(level: .erreur)
                            showCopiedFeedback(L("Erreurs copiées", "Errors copied"))
                        } label: {
                            Label(L("Copier les erreurs (\(logs.errorCount))", "Copy errors (\(logs.errorCount))"), systemImage: "exclamationmark.triangle")
                        }
                        .disabled(logs.errorCount == 0)
                        Button {
                            logs.copyToPasteboard()
                            showCopiedFeedback(L("Journal complet copié", "Full log copied"))
                        } label: {
                            Label(L("Copier tout", "Copy everything"), systemImage: "doc.on.doc.fill")
                        }
                        .disabled(logs.entries.isEmpty)

                        Divider()

                        Button {
                            exportURL = logs.exportFile(level: level, search: search)
                        } label: {
                            Label(L("Exporter la vue filtrée (.txt)", "Export filtered view (.txt)"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(visible.isEmpty)
                        Button {
                            exportURL = logs.exportFile(level: .erreur)
                        } label: {
                            Label(L("Exporter les erreurs (.txt)", "Export errors (.txt)"), systemImage: "exclamationmark.triangle")
                        }
                        .disabled(logs.errorCount == 0)
                        Button {
                            exportURL = logs.exportFile()
                        } label: {
                            Label(L("Exporter tout (.txt)", "Export everything (.txt)"), systemImage: "doc.badge.arrow.up")
                        }
                        .disabled(logs.entries.isEmpty)
                    } label: {
                        Image(systemName: copiedFeedback != nil ? "checkmark" : "square.and.arrow.up")
                    }
                    .accessibilityLabel(L("Partager ou copier les logs", "Share or copy logs"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
            }
            .onAppear {
                logs.flushNow()
            }
            .confirmationDialog(L("Effacer le journal ?", "Clear logs?"), isPresented: $confirmClear, titleVisibility: .visible) {
                Button(L("Effacer", "Clear"), role: .destructive) { logs.clear() }
                Button(L("Annuler", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Tout l’historique du journal sera définitivement supprimé.", "The entire log history will be permanently deleted."))
            }
            .sheet(item: Binding(
                get: { exportURL.map { ExportSelection(files: [$0]) } },
                set: { if $0 == nil { exportURL = nil } }
            )) { item in
                ExportSheet(files: item.files).ignoresSafeArea()
            }
        }
        .tint(DS.accentEmphasis)
    }

    @ViewBuilder
    private func filterHeader(
        counts: LogLevelCounts,
        visibleCount: Int,
        proxy: ScrollViewProxy,
        visible: [LogEntry]
    ) -> some View {
        VStack(spacing: DS.space(2)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.space(2)) {
                    filterChip(
                        title: L("Tout", "All"),
                        icon: "tray.full.fill",
                        count: counts.total,
                        tint: DS.accent,
                        selected: level == nil,
                        highlightBadge: false
                    ) { level = nil }

                    ForEach(LogLevel.allCases) { item in
                        let itemCount = counts.count(for: item)
                        filterChip(
                            title: item.label,
                            icon: item.icon,
                            count: itemCount,
                            tint: item.tint,
                            selected: level == item,
                            highlightBadge: item == .erreur && itemCount > 0
                        ) { level = (level == item) ? nil : item }
                    }
                }
                .padding(.horizontal, DS.space(4))
            }

            HStack(spacing: DS.space(2)) {
                Text(hasActiveFilter
                     ? L("\(visibleCount) / \(logs.entries.count) entrées", "\(visibleCount) / \(logs.entries.count) entries")
                     : L("\(visibleCount) entrées", "\(visibleCount) entries"))
                    .font(DS.monoCaption)
                    .foregroundStyle(DS.onSurfaceMuted)

                Spacer()

                Button {
                    newestFirst.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        Text(newestFirst ? L("Récents", "Newest") : L("Anciens", "Oldest"))
                    }
                    .font(DS.caption2.weight(.medium))
                    .foregroundStyle(DS.onSurface)
                    .padding(.horizontal, DS.space(2))
                    .padding(.vertical, 4)
                    .background(DS.surface, in: Capsule())
                    .overlay(Capsule().stroke(DS.separator.opacity(0.7), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Changer l'ordre chronologique", "Toggle chronological order"))
                .accessibilityValue(newestFirst ? L("Plus récents en premier", "Newest first") : L("Plus anciens en premier", "Oldest first"))

                Button {
                    autoFollow.toggle()
                } label: {
                    Image(systemName: autoFollow ? "dot.radiowaves.left.and.right" : "pause.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(autoFollow ? DS.accentEmphasis : DS.onSurfaceMuted)
                        .frame(width: 28, height: 24)
                        .background(
                            autoFollow ? DS.accentEmphasis.opacity(0.12) : DS.surface,
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(DS.separator.opacity(0.7), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Suivi automatique en direct", "Live auto-follow"))
                .accessibilityValue(autoFollow ? L("Activé", "On") : L("En pause", "Paused"))

                if let edge = newestFirst ? visible.last : visible.first {
                    Button {
                        let anchor: UnitPoint = newestFirst ? .bottom : .top
                        if reduceMotion {
                            proxy.scrollTo(edge.id, anchor: anchor)
                        } else {
                            withAnimation(DS.micro) { proxy.scrollTo(edge.id, anchor: anchor) }
                        }
                    } label: {
                        Image(systemName: newestFirst ? "arrow.down.to.line" : "arrow.up.to.line")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DS.onSurfaceMuted)
                            .frame(width: 28, height: 24)
                            .background(DS.surface, in: Capsule())
                            .overlay(Capsule().stroke(DS.separator.opacity(0.7), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(newestFirst
                        ? L("Aller aux entrées les plus anciennes", "Jump to oldest entries")
                        : L("Aller aux entrées les plus récentes", "Jump to newest entries"))
                }
            }
            .padding(.horizontal, DS.space(4))
        }
        .padding(.vertical, DS.space(2))
        .background(DS.background)
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasActiveFilter {
            ContentUnavailableView {
                Label(L("Aucune entrée", "No matching entries"), systemImage: "magnifyingglass")
            } description: {
                Text(L("Aucune ligne ne correspond au filtre ou à la recherche en cours.", "No log entries match the active filter or search query."))
            } actions: {
                Button(L("Réinitialiser les filtres", "Reset filters")) {
                    level = nil
                    search = ""
                }
                .buttonStyle(DSPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)
        } else {
            ContentUnavailableView {
                Label(L("Journal vide", "No logs yet"), systemImage: "doc.text")
            } description: {
                Text(L("Les événements réseau, kDrive et erreurs apparaîtront ici automatiquement.", "Network, kDrive, and error events will appear here automatically."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)
        }
    }

    private func showCopiedFeedback(_ message: String) {
        if reduceMotion {
            copiedFeedback = message
        } else {
            withAnimation(DS.micro) { copiedFeedback = message }
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard copiedFeedback == message else { return }
            if reduceMotion {
                copiedFeedback = nil
            } else {
                withAnimation(DS.micro) { copiedFeedback = nil }
            }
        }
    }

    private func filterChip(
        title: String,
        icon: String,
        count: Int,
        tint: Color,
        selected: Bool,
        highlightBadge: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? DS.onAccent : tint)

                Text(title)
                    .font(DS.caption)
                    .foregroundStyle(selected ? DS.onAccent : DS.onSurface)

                Text("\(count)")
                    .font(DS.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(selected ? DS.onAccent : (highlightBadge ? DS.calmRose : DS.onSurfaceMuted))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        selected
                            ? DS.onAccent.opacity(0.22)
                            : (highlightBadge ? DS.calmRose.opacity(0.14) : DS.background),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, DS.space(3))
            .padding(.vertical, DS.space(1))
            .frame(minHeight: 34)
            .background(selected ? tint : DS.surface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        selected
                            ? tint
                            : (highlightBadge ? DS.calmRose.opacity(0.4) : DS.separator.opacity(0.7)),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(DSPressableButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(title), \(count)")
    }
}
