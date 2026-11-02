import Foundation

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
    for frame in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -400, width: 1920, height: 1080)] {
        let corners: [(TriggerCorner, CGPoint)] = [(.topLeft, CGPoint(x: frame.minX + 1, y: frame.maxY - 1)), (.topRight, CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)), (.bottomLeft, CGPoint(x: frame.minX + 1, y: frame.minY + 1)), (.bottomRight, CGPoint(x: frame.maxX - 1, y: frame.minY + 1))]
        for (corner, point) in corners {
            try check(corner.contains(point, in: frame), "Selected corner must trigger")
            try check(!corner.contains(CGPoint(x: frame.midX, y: frame.maxY - 1), in: frame), "Menu-bar middle no longer triggers")
            for (other, otherPoint) in corners where other != corner { try check(!corner.contains(otherPoint, in: frame), "Other corners must not trigger") }
            try check(frame.contains(corner.shelfFrame(in: frame)), "Shelf stays within the selected screen")
        }
    }
    print("PASS: Markdown paste; access order, restart persistence, read isolation, deletion, new/imported/edited/image files; configurable shortcut persistence/conflicts; four-corner geometry on offset screens")
    print("PASS: CSV quoting, multiline, CRLF, invalid syntax; JSON scalar/container roundtrip; XML attributes/escaping; unique names, atomic save, sorting, import copy")
}
