import AppKit

func runSelfTests() throws {
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw AppError.message(message) } }
    let cases: [[[String]]] = [ [[""]], [["a", "b"], ["1", "2"]], [["逗号,内容", "引号\"内容", "多行\n文字"]], [["a", ""], ["", ""]], [["a\r\nb", "中文🙂"]], [["", "b"], ["c"]] ]
    for rows in cases { try check(CSVCodec.parse(CSVCodec.encode(rows)) == rows, "CSV roundtrip: \(rows)") }
    try check(CSVCodec.parse("a,b\r\n1,2\r\n") == [["a", "b"], ["1", "2"]], "CSV CRLF")
    do { _ = try CSVCodec.parse("\"unclosed"); throw AppError.message("CSV accepted invalid input") } catch let e as AppError { if e.localizedDescription == "CSV accepted invalid input" { throw e } }
    for input in ["{\"x\":[1,true,null,\"中文\"],\"empty\":{}}", "[0,false,{},[]]", "null", "\"hello\"", "1.25e3"] {
        let node = try JSONNode.parse(input); let output = try node.encode()
        let before = try JSONSerialization.jsonObject(with: Data(input.utf8), options: .fragmentsAllowed) as AnyObject
        let after = try JSONSerialization.jsonObject(with: Data(output.utf8), options: .fragmentsAllowed) as AnyObject
        try check(before.isEqual(after), "JSON semantic roundtrip")
    }
    let tree = try JSONNode.parse("{\"a\":1,\"b\":false}"); try check(tree.children[0].kind == "number" && tree.children[1].kind == "boolean", "JSON scalar types")
    tree.children[0].value = "7"; try check(try tree.encode().contains("7"), "JSON edit")
    let xml = try XMLDocument(xmlString: "<?xml version=\"1.0\"?><root id=\"1\"><a>中文 &amp; text</a><!-- comment --></root>", options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    let root = XMLTreeNode(xml); try check(root.children.count == 1 && root.children[0].children.first?.kind == "attribute", "XML attributes")
    xml.rootElement()?.attribute(forName: "id")?.stringValue = "2&3"
    let again = try XMLDocument(xmlString: xml.xmlString, options: [.nodeLoadExternalEntitiesNever]); try check(again.rootElement()?.attribute(forName: "id")?.stringValue == "2&3", "XML escaping")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAssistant-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = try FileStore(directory: temporary)
    let a = try store.create(name: "a.txt", data: Data("one".utf8)); let b = try store.create(name: "a.txt", data: Data("two".utf8))
    try check(a != b && store.files().count == 2, "Unique file names")
    try store.save("updated", to: a); try check(readText(a) == "updated", "Atomic text persistence")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: b.path)
    let recent = Date().addingTimeInterval(100)
    try store.recordAccess(a, at: recent)
    try check(store.files().last?.url.standardizedFileURL.path == a.standardizedFileURL.path, "Old-to-new sort")
    let copy = try store.importFile(a); try check(readText(copy) == "updated" && copy != a, "Import copies original")
    try store.recordAccess(b, at: recent.addingTimeInterval(1))
    try check(store.latestFile()?.url.standardizedFileURL == b.standardizedFileURL, "Reopening an older file must make it latest without modifying contents: \(store.files().map { "\($0.name):\($0.lastAccessed.timeIntervalSince1970)" })")
    let reopenedStore = try FileStore(directory: temporary)
    try check(reopenedStore.latestFile()?.url.standardizedFileURL == b.standardizedFileURL, "Access order survives restart")
    _ = try readText(a); _ = reopenedStore.files()
    try check(reopenedStore.latestFile()?.url.standardizedFileURL == b.standardizedFileURL, "Background reads must not change access order")
    try FileManager.default.removeItem(at: b)
    try check(reopenedStore.latestFile()?.url.standardizedFileURL == a.standardizedFileURL, "Deleted files are excluded from latest")
    let textStore = try FileStore(directory: temporary.appendingPathComponent("paste"))
    try check(textStore.latestFile() == nil, "Empty storage")
    let pasted = try textStore.createPastedText("# 中文\n\n**内容**🙂", stamp: "test")
    try check(pasted.pathExtension == "md" && readText(pasted) == "# 中文\n\n**内容**🙂", "Paste preserves Markdown content")
    try check(textStore.latestFile()?.url.standardizedFileURL.path == pasted.standardizedFileURL.path, "Newly created file is latest")
    let imported = try textStore.importFile(a)
    try check(textStore.latestFile()?.url.standardizedFileURL.path == imported.standardizedFileURL.path, "Imported file is latest")
    let image = try textStore.create(name: "picture.png", data: Data())
    try check(textStore.latestFile()?.isImage == true && textStore.latestFile()?.url.standardizedFileURL.path == image.standardizedFileURL.path, "New image can be the latest file")
    try textStore.save("edited", to: pasted)
    try check(textStore.latestFile()?.url.standardizedFileURL.path == pasted.standardizedFileURL.path, "Editing updates access order")
    let retentionStore = try FileStore(directory: temporary.appendingPathComponent("retention"))
    let now = Date()
    let fresh = try retentionStore.create(name: "fresh.md", data: Data("new".utf8))
    let edge = try retentionStore.create(name: "edge.md", data: Data("edge".utf8))
    let stale = try retentionStore.create(name: "stale.md", data: Data("old".utf8))
    try retentionStore.recordAccess(edge, at: now.addingTimeInterval(-FileStore.shelfRetention + 60))
    try retentionStore.recordAccess(stale, at: now.addingTimeInterval(-FileStore.shelfRetention - 60))
    try retentionStore.recordAccess(fresh, at: now)
    let recentNames = retentionStore.recentFiles(now: now).map(\.name)
    try check(recentNames == ["edge.md", "fresh.md"], "Shelf keeps only the last 3 days, old-to-new: \(recentNames)")
    try check(FileManager.default.fileExists(atPath: stale.path) && retentionStore.files().count == 3, "Expired shelf entries stay on disk")
    try check(ShelfStripLayout.visibleCount(total: 0, availableWidth: 2000) == 0, "Empty strip shows nothing")
    try check(ShelfStripLayout.visibleCount(total: 5, availableWidth: 2000) == 5, "Few files all visible")
    try check(ShelfStripLayout.visibleCount(total: 12, availableWidth: 2000) == 7, "At most 7 cards visible")
    try check(ShelfStripLayout.visibleCount(total: 12, availableWidth: ShelfStripLayout.width(cards: 4)) == 4, "Narrow screens fit fewer cards")
    try check(ShelfStripLayout.visibleCount(total: 12, availableWidth: 10) == 1, "Always at least one card")
    try check(ShelfStripLayout.newestOffset(total: 12, viewport: ShelfStripLayout.width(cards: 7)) == ShelfStripLayout.cardX(5) - ShelfStripLayout.inset, "Initial offset shows the newest 7 cards")
    try check(ShelfStripLayout.newestOffset(total: 3, viewport: ShelfStripLayout.width(cards: 3)) == 0, "No offset when all cards fit")
    let suite = "AgentAssistant-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try check(AppSettings.load(from: defaults) == AppSettings(), "Default shortcuts and top-left corner")
    var settings = AppSettings(); settings.triggerCorner = .bottomRight
    settings.latestShortcut = KeyboardShortcut(keyCode: 12, modifiers: 4352, keyLabel: "Q")
    defaults.set(try JSONEncoder().encode(settings), forKey: "TCenter.settings")
    try check(AppSettings.load(from: defaults) == settings, "AgentAssistant preserves legacy TCenter preferences")
    try settings.save(to: defaults)
    try check(AppSettings.load(from: defaults) == settings, "Settings persist")
    settings.latestShortcut = settings.shelfShortcut
    try check(settings.shortcutsConflict, "Duplicate shortcuts detected")
    try settings.save(to: defaults)
    try check(AppSettings.load(from: defaults) == AppSettings(), "Invalid persisted shortcuts fall back to defaults")
    // Settings written before clipboard history existed must keep their shortcuts and gain clipboard defaults.
    let legacy = "{\"shelfShortcut\":{\"keyCode\":49,\"modifiers\":6144,\"keyLabel\":\"Space\"},\"latestShortcut\":{\"keyCode\":12,\"modifiers\":4352,\"keyLabel\":\"Q\"},\"triggerCorner\":\"bottomLeft\"}"
    defaults.set(Data(legacy.utf8), forKey: "TCenter.settings")
    let migrated = AppSettings.load(from: defaults)
    try check(migrated.triggerCorner == .bottomLeft && migrated.latestShortcut.keyLabel == "Q" && migrated.clipboardShortcut == .clipboard && migrated.recordsClipboard && migrated.clipboardRetentionDays == 3, "Legacy settings gain clipboard defaults")
    var clipSettings = AppSettings(); clipSettings.clipboardShortcut = clipSettings.latestShortcut
    try check(clipSettings.anyShortcutConflict, "Clipboard shortcut conflict detected")
    clipSettings.clipboardShortcut = .clipboard; clipSettings.clipboardRetentionDays = 99; clipSettings.recordsClipboard = false; try clipSettings.save(to: defaults)
    let reloaded = AppSettings.load(from: defaults)
    try check(reloaded.clipboardRetentionDays == 30 && !reloaded.recordsClipboard, "Clipboard retention clamps and toggle persists")
    var colliding = AppSettings(); colliding.shelfShortcut = .clipboard; colliding.clipboardShortcut = .clipboard; try colliding.save(to: defaults)
    let fixed = AppSettings.load(from: defaults)
    try check(fixed.shelfShortcut == .clipboard && !fixed.anyShortcutConflict, "Clipboard default yields to an existing shortcut")
    try checkClipboardHistory(temporary.appendingPathComponent("clipboard"), check)
    for frame in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -400, width: 1920, height: 1080)] {
        let corners: [(TriggerCorner, CGPoint)] = [(.topLeft, CGPoint(x: frame.minX + 1, y: frame.maxY - 1)), (.topRight, CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)), (.bottomLeft, CGPoint(x: frame.minX + 1, y: frame.minY + 1)), (.bottomRight, CGPoint(x: frame.maxX - 1, y: frame.minY + 1))]
        for (corner, point) in corners {
            try check(corner.contains(point, in: frame), "Selected corner must trigger")
            try check(!corner.contains(CGPoint(x: frame.midX, y: frame.maxY - 1), in: frame), "Menu-bar middle no longer triggers")
            for (other, otherPoint) in corners where other != corner { try check(!corner.contains(otherPoint, in: frame), "Other corners must not trigger") }
            try check(frame.contains(corner.shelfFrame(in: frame)), "Shelf stays within the selected screen")
        }
    }
    print("PASS: clipboard history newest-first order, timestamp separators without source paths, verbatim text, code fences, retention, dedup, shelf badge flag, legacy settings migration")
    print("PASS: Markdown paste; access order, restart persistence, read isolation, deletion, new/imported/edited/image files; configurable shortcut persistence/conflicts; four-corner geometry on offset screens; 3-day shelf retention, 7-card strip with newest on the right")
    print("PASS: CSV quoting, multiline, CRLF, invalid syntax; JSON scalar/container roundtrip; XML attributes/escaping; unique names, atomic save, sorting, import copy")
}

private func checkClipboardHistory(_ directory: URL, _ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
    let store = try FileStore(directory: directory)
    let history = ClipboardHistory(store: store, retentionDays: 3)
    try check(!FileManager.default.fileExists(atPath: history.fileURL.path), "No history file before the first copy")
    let now = Date()
    let swift = ClipboardSource(path: "/Users/demo/project/main.swift", bundleIdentifier: "com.apple.dt.Xcode")
    let note = ClipboardSource(path: "/Applications/Notes.app", bundleIdentifier: "com.apple.Notes")
    try history.record("旧内容", source: note, at: now.addingTimeInterval(-4 * 86_400))
    try history.record("  第一行\n    缩进保留\n\n**粗体**", source: note, at: now.addingTimeInterval(-60))
    try history.record("let a = 1;\nprint(\"```\")\n", source: swift, at: now)
    let text = try readText(history.fileURL)
    try check(!text.contains("旧内容"), "Entries older than the retention window are dropped")
    try check(text.range(of: "let a = 1;")!.lowerBound < text.range(of: "第一行")!.lowerBound, "Newest entry comes first")
    try check(!text.contains("/Users/demo") && !text.contains("Notes.app"), "Source paths are not written")
    try check(text.contains("````swift\nlet a = 1;\nprint(\"```\")\n````\n"), "Code is fenced with a fence longer than its content's backticks")
    try check(text.contains("\n\n  第一行\n    缩进保留\n\n**粗体**\n"), "Ordinary text is kept verbatim")
    let stamp = DateFormatter(); stamp.locale = Locale(identifier: "zh_CN"); stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    try check(text.contains("### \(stamp.string(from: now))\n\n````swift"), "Entry header is the timestamp")
    try check(store.files().contains { $0.isClipboardHistory }, "History file appears on the shelf with its marker")
    try history.record("let a = 1;\nprint(\"```\")\n", source: swift, at: now.addingTimeInterval(5))
    try check(history.entries.count == 2, "Copying the same text again does not duplicate it")
    try check(ClipboardFormatter.language(for: "func a() {\n  return 1\n}", source: note) == "", "Code heuristic fences unknown-source code")
    try check(ClipboardFormatter.language(for: "这是一段普通文字。\n第二行。", source: note) == nil, "Prose is not fenced")
    try check(ClipboardFormatter.language(for: "ls -la", source: ClipboardSource(path: "/System/Applications/Utilities/Terminal.app", bundleIdentifier: "com.apple.Terminal")) == "", "Terminal copies are fenced")
    let reopened = ClipboardHistory(store: store, retentionDays: 1)
    try check(reopened.entries.count == 2, "History survives restart")
    try reopened.prune(now: now.addingTimeInterval(2 * 86_400))
    try check(reopened.entries.isEmpty && readText(reopened.fileURL).contains("暂无记录"), "Shortening retention prunes old entries")
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.clearContents(); board.setString("文字", forType: .string)
    try check(ClipboardMonitor.copiedText(from: board) == "文字", "Plain text copies are captured")
    board.clearContents(); board.writeObjects([directory as NSURL])
    try check(ClipboardMonitor.copiedText(from: board) == nil, "File copies are ignored")
    board.clearContents(); board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil); board.setString("secret", forType: .string)
    try check(ClipboardMonitor.copiedText(from: board) == nil, "Password-manager copies are ignored")
    try reopened.clear()
    try check(ClipboardHistory(store: store, retentionDays: 3).entries.isEmpty, "Clearing removes the hidden record")
}
