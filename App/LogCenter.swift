import Foundation
import SwiftUI
import MediaCore

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

@MainActor final class LogCenter: ObservableObject {
    static let shared = LogCenter()
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var errorCount = 0

    private static let maxMemory = 10_000
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let ioQueue = DispatchQueue(label: "LogCenter.io", qos: .utility)

    private var fileURL0: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("log-0.txt")
    }
    private var fileURL1: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("log-1.txt")
    }

    private init() {
        loadFromDisk()
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
        entries.append(entry)
        if entries.count > Self.maxMemory {
            entries.removeFirst(entries.count - Self.maxMemory)
        }
        if level == .erreur { errorCount += 1 }
        // Écriture fichier hors Main pour ne jamais geler l'écran même avec 500 lignes par run.
        let line: String = {
            let f = ISO8601DateFormatter()
            return "\(f.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)\n"
        }()
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
            guard let data = line.data(using: .utf8) else { return }
            if !fm.fileExists(atPath: url0.path) { try? data.write(to: url0) }
            else if let handle = try? FileHandle(forWritingTo: url0) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    func clear() {
        entries = []
        errorCount = 0
        try? FileManager.default.removeItem(at: fileURL0)
        try? FileManager.default.removeItem(at: fileURL1)
        addSync(level: .info, message: L("Journal effacé.", "Log cleared."))
    }

    func filtered(level: LogLevel?, search: String) -> [LogEntry] {
        entries.filter { entry in
            if let level, entry.level != level { return false }
            if search.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(search)
        }
    }

    /// Fichier d'export : tout l'historique mémoire + note. Léger, partageable.
    func exportFile() -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-logs-\(Int(Date().timeIntervalSince1970)).txt")
        var text = "RedditMediaPocket logs — \(Date())\n\n"
        let formatter = ISO8601DateFormatter()
        for e in entries {
            text += "\(formatter.string(from: e.date)) [\(e.level.rawValue)] \(e.message)\n"
        }
        try? text.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        var lines: [String] = []
        for url in [fileURL1, fileURL0] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.maxMemory).map(String.init))
        }
        let tail = lines.suffix(Self.maxMemory)
        let formatter = ISO8601DateFormatter()
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
            entries.append(LogEntry(date: date, level: level, message: message))
        }
        errorCount = entries.filter { $0.level == .erreur }.count
    }
}

struct LogsButton: View {
    @ObservedObject private var logs = LogCenter.shared
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "doc.text.magnifyingglass")
                if logs.errorCount > 0 {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
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
    @ObservedObject private var logs = LogCenter.shared
    @State private var level: LogLevel?
    @State private var search = ""
    @State private var exportURL: URL?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("Filtre", "Filter"), selection: Binding(
                    get: { level?.rawValue ?? "all" },
                    set: { level = LogLevel(rawValue: $0) }
                )) {
                    Text(L("Tout", "All")).tag("all")
                    ForEach(LogLevel.allCases) { l in Text(l.label).tag(l.rawValue) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
                Text(L("\(logs.filtered(level: level, search: search).count) lignes", "\(logs.filtered(level: level, search: search).count) lines"))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 12)
                ScrollViewReader { proxy in
                    List(logs.filtered(level: level, search: search)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.level.icon).foregroundStyle(entry.level == .erreur ? .red : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message).font(.caption).textSelection(.enabled)
                                Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: logs.entries.count) { _ in
                        if let last = logs.filtered(level: level, search: search).last {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: L("Rechercher", "Search"))
            .navigationTitle(L("Journal", "Logs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Effacer", "Clear")) { logs.clear() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { exportURL = logs.exportFile() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L("Exporter les logs", "Export logs"))
                }
            }
            .sheet(item: Binding(
                get: { exportURL.map { ExportSelection(files: [$0]) } },
                set: { if $0 == nil { exportURL = nil } }
            )) { item in
                ExportSheet(files: item.files).ignoresSafeArea()
            }
        }
    }
}
