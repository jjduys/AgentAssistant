import AppKit

let clipboardHistoryFileName = "剪贴板历史.md"

/// Hints used only to decide whether copied text is code; never written to the history file.
struct ClipboardSource: Equatable {
    var path: String? = nil
    var bundleIdentifier: String?
}

struct ClipboardEntry: Codable, Equatable {
    var date: Date
    var text: String
    /// nil: ordinary text kept verbatim; otherwise rendered as a fenced code block ("" means no language tag).
    var language: String?
}

enum ClipboardFormatter {
    static let codeExtensions: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "jsx", "ts": "typescript", "tsx": "tsx",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "go": "go", "rs": "rust", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "rb": "ruby", "php": "php", "sh": "bash", "bash": "bash", "zsh": "zsh", "fish": "fish",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml", "html": "html", "htm": "html", "css": "css", "scss": "scss",
        "less": "less", "sql": "sql", "lua": "lua", "r": "r", "scala": "scala", "dart": "dart", "vue": "vue", "svelte": "svelte", "pl": "perl", "ex": "elixir",
        "exs": "elixir", "erl": "erlang", "hs": "haskell", "clj": "clojure", "gradle": "groovy", "groovy": "groovy", "ps1": "powershell", "dockerfile": "dockerfile"
    ]
    static let editorApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.3", "com.sublimetext.4", "com.panic.Nova", "com.google.android.studio", "com.exafunction.windsurf"
    ]
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty", "com.mitchellh.ghostty"
    ]
    private static let codePrefixes = ["func ", "def ", "class ", "import ", "from ", "return ", "if (", "for (", "while (", "switch ", "#include", "#import", "#define",
                                       "const ", "let ", "var ", "public ", "private ", "protected ", "static ", "fn ", "pub ", "package ", "struct ", "enum ", "interface ",
                                       "<?php", "#!/", "async ", "await ", "try {", "} else", "elif ", "SELECT ", "INSERT ", "UPDATE ", "CREATE "]
    private static let codeSuffixes = [";", "{", "}", "};", "):", "=>", "->", "*/"]

    /// Decide whether copied text is code, and which fence language to use.
    static func language(for text: String, source: ClipboardSource) -> String? {
        if let path = source.path, let lang = codeExtensions[URL(fileURLWithPath: path).pathExtension.lowercased()] { return lang }
        if let id = source.bundleIdentifier {
            if editorApps.contains(id) || id.hasPrefix("com.jetbrains.") { return "" }
            if terminalApps.contains(id) { return "" }
        }
        // Text that already has Markdown fences is kept as Markdown.
        return !text.contains("```") && looksLikeCode(text) ? "" : nil
    }

    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        let codeLike = lines.filter { line in codeSuffixes.contains(where: line.hasSuffix) || codePrefixes.contains(where: line.hasPrefix) }.count
        return codeLike >= 2 && Double(codeLike) / Double(lines.count) >= 0.4
    }

    /// A backtick fence longer than any backtick run inside the content, so the content is never closed early.
    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for c in text { if c == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func render(_ entries: [ClipboardEntry], retentionDays: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "# 剪贴板历史\n\n> 自动记录最近 \(retentionDays) 天复制的文字（不含文件），最新的排在最前。本文件由 AgentAssistant 自动生成。\n"
        if entries.isEmpty { out += "\n暂无记录。\n"; return out }
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            out += "\n---\n\n### \(formatter.string(from: entry.date))\n\n"
            if let language = entry.language {
                let fence = fence(for: entry.text)
                out += fence + language + "\n" + entry.text + (entry.text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
            } else {
                out += entry.text + (entry.text.hasSuffix("\n") ? "" : "\n")
            }
        }
        return out
    }
}

/// Keeps copied text in a hidden JSON record and regenerates the Markdown file shown on the shelf.
final class ClipboardHistory {
    static let maximumLength = 1_000_000
    let store: FileStore
    var retentionDays: Int
    private(set) var entries: [ClipboardEntry] = []
    var fileURL: URL { store.directory.appendingPathComponent(clipboardHistoryFileName) }
    private var recordURL: URL { store.directory.appendingPathComponent(".clipboard-history.json") }
    var onWrite: ((URL) -> Void)?

    init(store: FileStore, retentionDays: Int) {
        self.store = store; self.retentionDays = retentionDays
        if let data = try? Data(contentsOf: recordURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
        }
    }

    func record(_ text: String, source: ClipboardSource, at date: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maximumLength else { return }
        let entry = ClipboardEntry(date: date, text: text, language: ClipboardFormatter.language(for: text, source: source))
        var next = entries.sorted { $0.date > $1.date }
        // Copying the same text again only refreshes its position.
        if let newest = next.first, newest.text == entry.text { next[0] = entry } else { next.insert(entry, at: 0) }
        try write(pruned(next, now: date))
    }

    /// Drops entries older than the retention window; rewrites only when something changed.
    func prune(now: Date = Date()) throws {
        let kept = pruned(entries, now: now)
        if kept != entries || !FileManager.default.fileExists(atPath: fileURL.path) && !kept.isEmpty { try write(kept) }
    }

    /// The file always exists after this, so the shortcut can open it even before anything is copied.
    @discardableResult func ensureFile() throws -> URL {
        if !FileManager.default.fileExists(atPath: fileURL.path) { try write(pruned(entries, now: Date()), force: true) }
        return fileURL
    }

    func clear() throws {
        entries = []
        if FileManager.default.fileExists(atPath: recordURL.path) { try FileManager.default.removeItem(at: recordURL) }
    }

    private func pruned(_ list: [ClipboardEntry], now: Date) -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
        return list.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
    }

    private func write(_ list: [ClipboardEntry], force: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(list).write(to: recordURL, options: .atomic)
        entries = list
        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        guard existed || !list.isEmpty || force else { return }
        try Data(ClipboardFormatter.render(list, retentionDays: retentionDays).utf8).write(to: fileURL, options: .atomic)
        // Record access only when the file first appears; later rewrites keep the shelf's existing order rules.
        if existed { store.onChange?() } else { try store.recordAccess(fileURL) }
        onWrite?(fileURL)
    }
}

/// Polls the general pasteboard for copied text. File copies, images and password-manager content are ignored.
@MainActor
final class ClipboardMonitor {
    nonisolated static let ignoredTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType"]
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var timer: Timer?
    private let onText: (String, ClipboardSource) -> Void

    init(pasteboard: NSPasteboard = .general, onText: @escaping (String, ClipboardSource) -> Void) {
        self.pasteboard = pasteboard; self.onText = onText
        changeCount = pasteboard.changeCount // Content already on the clipboard at launch is not recorded.
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let text = Self.copiedText(from: pasteboard) else { return }
        onText(text, Self.currentSource(pasteboard: pasteboard))
    }

    nonisolated static func copiedText(from pasteboard: NSPasteboard) -> String? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ignoredTypes), !types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
              !types.contains("NSFilenamesPboardType") else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// The front app hints at code (editors, terminals); in this app's own editor the edited file's extension is used.
    static func currentSource(pasteboard: NSPasteboard) -> ClipboardSource {
        let app = NSWorkspace.shared.frontmostApplication
        let ownFile = app?.processIdentifier == getpid() ? NSApp.keyWindow?.representedURL?.path : nil
        return ClipboardSource(path: ownFile, bundleIdentifier: app?.bundleIdentifier)
    }
}
