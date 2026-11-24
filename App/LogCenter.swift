import Foundation
import SwiftUI
import MediaCore
import UIKit

enum LogLevel: String, CaseIterable, Identifiable {
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
        case .info: return "info.circle"
        case .reseau: return "network"
        case .kdrive: return "icloud"
        case .erreur: return "exclamationmark.triangle"
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String
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
    private let isoFormatter = ISO8601DateFormatter()
    private var pendingBuffer: [LogEntry] = []
    private var uiFlushTask: Task<Void, Never>?
    private var pendingDiskLines: [String] = []
    private var diskFlushScheduled = false

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

    func filtered(level: LogLevel?, search: String) -> [LogEntry] {
        flushPendingEntries()
        let needle = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if let level, entry.level != level { return false }
            if needle.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(needle)
        }
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

struct LogsView: View {
    @State private var logs = LogCenter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: LogLevel?
    @State private var search = ""
    @State private var exportURL: URL?
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        let visible = logs.filtered(level: level, search: search)
        return NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.space(2)) {
                        filterPill(title: L("Tout", "All"), selected: level == nil) { level = nil }
                        ForEach(LogLevel.allCases) { item in
                            filterPill(title: item.label, selected: level == item) { level = item }
                        }
                    }
                    .padding(.horizontal, DS.space(4))
                    .padding(.vertical, DS.space(2))
                }
                Text(L("\(visible.count) lignes", "\(visible.count) lines"))
                    .font(DS.caption2).foregroundStyle(DS.onSurfaceMuted).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, DS.space(4))
                ScrollViewReader { proxy in
                    List(visible) { entry in
                        HStack(alignment: .top, spacing: DS.space(2)) {
                            Image(systemName: entry.level.icon).foregroundStyle(entry.level == .erreur ? DS.error : DS.onSurfaceMuted).frame(width: 22)
                            VStack(alignment: .leading, spacing: DS.space(1)) {
                                Text(entry.message).font(.caption).textSelection(.enabled)
                                Text(entry.date.formatted(date: .omitted, time: .standard)).font(DS.caption2).foregroundStyle(DS.onSurfaceMuted).monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: logs.entries.count) { _, _ in
                        if let last = logs.filtered(level: level, search: search).last {
                            if reduceMotion {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            } else {
                                withAnimation(DS.micro) { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: L("Rechercher", "Search"))
            .navigationTitle(L("Journal", "Logs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Text(L("Effacer", "Clear"))
                    }
                    .disabled(logs.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            logs.copyToPasteboard(level: level, search: search)
                            copied = true
                        } label: {
                            Label(L("Copier l'onglet courant", "Copy current tab"), systemImage: "doc.on.doc")
                        }
                        Button {
                            logs.copyToPasteboard()
                            copied = true
                        } label: {
                            Label(L("Copier tout", "Copy everything"), systemImage: "doc.on.doc.fill")
                        }
                        Divider()
                        Button(L("Exporter l'onglet courant", "Export current tab")) {
                            exportURL = logs.exportFile(level: level, search: search)
                        }
                        Divider()
                        Button(L("Exporter tout", "Export everything")) {
                            exportURL = logs.exportFile()
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                    }
                    .onChange(of: copied) { _, _ in
                        guard copied else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                    .accessibilityLabel(L("Exporter les logs", "Export logs"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Fermer", "Close")) { dismiss() }
                }
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

    private func filterPill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.caption)
                .padding(.horizontal, DS.space(3))
                .padding(.vertical, DS.space(1))
                .frame(minHeight: 36)
                .foregroundStyle(selected ? DS.onAccent : DS.onSurface)
                .background(selected ? DS.accent : DS.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
