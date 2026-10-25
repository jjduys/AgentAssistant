import AppKit
import Darwin

func runUITests() throws {
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/ui-check")
    let storage = output.appendingPathComponent("fixtures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = try FileStore(directory: storage)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func render(_ window: NSWindow, _ name: String) throws {
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Cannot render \(name)") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
    let samples = [
        ("01-便签.md", "# 随时继续\n\n把零散想法挂在这里。\n\n- 自动保存\n- 拖到其他软件\n\n**重要内容**与 `代码`\n\n```swift\nlet idea = \"Hello\"\n```"),
        ("02-数据.json", "{\"project\":\"TCenter\",\"enabled\":true,\"items\":[{\"name\":\"便签\",\"count\":3}],\"empty\":null}"),
        ("03-结构.xml", "<?xml version=\"1.0\"?><workspace name=\"TCenter\"><note status=\"draft\">随时记录</note><!--保留注释--></workspace>"),
        ("04-任务.csv", "名称,状态,备注\n便签中心,完成,自动保存\n拖放文件,待验收,\"包含,逗号\"\n"),
        ("05-文字.txt", "临时文字\n关闭窗口后仍会保留。")
    ]
    for (name, contents) in samples {
        let url = try store.create(name: name, data: Data(contents.utf8)); let editor = try EditorController(file: MountedFile(url: url), store: store)
        let window = editor.window!; try render(window, String(name.prefix(2)))
        let views = descendants(window.contentView!)
        if let segmented = views.first(where: { $0 is NSSegmentedControl }) as? NSSegmentedControl {
            segmented.selectedSegment = 1; segmented.sendAction(segmented.action!, to: segmented.target); try render(window, String(name.prefix(2)) + "-alternate")
            segmented.selectedSegment = 0; segmented.sendAction(segmented.action!, to: segmented.target)
        }
        if name.hasSuffix("txt"), let text = descendants(window.contentView!).first(where: { $0 is NSTextView }) as? NSTextView {
            text.string = "编辑后已保存"; editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text)); guard editor.flush(), try readText(url) == "编辑后已保存" else { throw AppError.message("Text UI save failed") }
        }
        if name.hasSuffix("csv"), let table = views.first(where: { $0 is NSTableView }) as? NSTableView, let field = table.view(atColumn: 1, row: 1, makeIfNecessary: true) as? NSTextField {
            field.stringValue = "表格已编辑"; field.sendAction(field.action!, to: field.target); guard editor.flush(), try CSVCodec.parse(readText(url))[1][0] == "表格已编辑" else { throw AppError.message("CSV UI save failed") }
        }
        if name.hasSuffix("json"), let tree = descendants(window.contentView!).first(where: { $0 is NSOutlineView }) as? NSOutlineView {
            guard let field = tree.view(atColumn: 2, row: 7, makeIfNecessary: true) as? TreeField else { throw AppError.message("JSON edit field missing") }
            field.stringValue = "修改后的项目"; field.sendAction(field.action!, to: field.target)
            guard editor.flush(), try JSONNode.parse(readText(url)).children.last?.value == "修改后的项目" else { throw AppError.message("JSON UI save failed") }
        }
        if name.hasSuffix("xml"), let tree = descendants(window.contentView!).first(where: { $0 is NSOutlineView }) as? NSOutlineView {
            guard let field = tree.view(atColumn: 2, row: 2, makeIfNecessary: true) as? TreeField else { throw AppError.message("XML edit field missing") }
            field.stringValue = "Edited & saved"; field.sendAction(field.action!, to: field.target)
            guard editor.flush(), try XMLDocument(xmlString: readText(url), options: .nodeLoadExternalEntitiesNever).rootElement()?.attribute(forName: "name")?.stringValue == "Edited & saved" else { throw AppError.message("XML UI save failed") }
        }
        editor.close()
    }
    let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
        NSGradient(starting: .systemBlue, ending: .systemTeal)?.draw(in: rect, angle: 25)
        ("TCenter 图片便签" as NSString).draw(at: NSPoint(x: 140, y: 165), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: NSColor.white]); return true
    }
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let imageURL = try store.create(name: "06-图片.png", data: png)
    let imageEditor = try EditorController(file: MountedFile(url: imageURL), store: store); try render(imageEditor.window!, "06-image"); imageEditor.close()
    let shelf = ShelfController(store: store)
    let menuDelegate = AppDelegate(); shelf.addMenu = menuDelegate.additionMenu()
    guard let newItems = shelf.addMenu?.items.first?.submenu?.items,
          newItems.compactMap({ $0.representedObject as? String }) == ["md", "txt", "json", "xml", "csv"],
          newItems.allSatisfy({ $0.target === menuDelegate && $0.action != nil }),
          let importItem = shelf.addMenu?.items.last, importItem.title == "导入文件…", importItem.target === menuDelegate, importItem.action != nil else { throw AppError.message("Shelf addition menu must reuse creation/import actions") }
    shelf.present(on: NSScreen.main!); try render(shelf.window!, "shelf")
    guard let addButton = descendants(shelf.window!.contentView!).first(where: { ($0 as? NSButton)?.toolTip == "添加：新建文档或导入文件" }) as? NSButton,
          !addButton.isHidden, addButton.isEnabled, addButton.target === shelf, addButton.action != nil,
          let scrollView = descendants(shelf.window!.contentView!).first(where: { $0 is NSScrollView }),
          addButton.frame.width == 28, addButton.frame.minX > scrollView.frame.maxX else { throw AppError.message("Shelf add button missing or overlapping files") }
    let emptyStorage = output.appendingPathComponent("empty-fixtures-\(UUID().uuidString)")
    let emptyShelf = ShelfController(store: try FileStore(directory: emptyStorage)); emptyShelf.addMenu = menuDelegate.additionMenu(); emptyShelf.present(on: NSScreen.main!)
    try render(emptyShelf.window!, "shelf-empty")
    guard descendants(emptyShelf.window!.contentView!).contains(where: { ($0 as? NSButton)?.toolTip == addButton.toolTip && !$0.isHidden }) else { throw AppError.message("Empty shelf must allow adding files") }
    emptyShelf.close()
    guard shelf.window?.backgroundColor == .clear, abs(shelf.window!.frame.width - (NSScreen.main!.visibleFrame.width - 20)) < 1 else { throw AppError.message("Shelf transparency/width failed") }
    // Pure interaction clock checks avoid moving the user's actual mouse.
    var policy = ShelfDismissalPolicy(); let t = Date()
    policy.update(inside: true, dragging: false, now: t)
    guard !policy.shouldDismiss(at: t.addingTimeInterval(30)) else { throw AppError.message("Hover must hold shelf open") }
    policy.update(inside: false, dragging: false, now: t)
    guard !policy.shouldDismiss(at: t.addingTimeInterval(2.9)), policy.shouldDismiss(at: t.addingTimeInterval(3)) else { throw AppError.message("Leave must start a three-second countdown") }
    policy.update(inside: true, dragging: false, now: t.addingTimeInterval(2))
    guard !policy.shouldDismiss(at: t.addingTimeInterval(10)) else { throw AppError.message("Re-entry must cancel countdown") }
    policy.update(inside: false, dragging: true, now: t.addingTimeInterval(10))
    guard !policy.shouldDismiss(at: t.addingTimeInterval(20)) else { throw AppError.message("Dragging must hold shelf open") }
    policy.update(inside: false, dragging: false, now: t.addingTimeInterval(20))
    guard !policy.shouldDismiss(at: t.addingTimeInterval(22)), policy.shouldDismiss(at: t.addingTimeInterval(23)) else { throw AppError.message("Drag end outside must restart countdown") }
    shelf.close()
    var importedScreenshots = 0
    var copies: [URL] = []
    let incoming = output.appendingPathComponent("screenshots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    let accept: (URL) -> Bool = { url in
        do { copies.append(try store.importFile(url)); importedScreenshots += 1; return true } catch { return false }
    }
    let existing = incoming.appendingPathComponent("截图-history.png")
    try png.write(to: existing)
    let monitor = ScreenshotMonitor(excluding: storage, watchDirectory: incoming, importImage: accept)
    defer { withExtendedLifetime(monitor) {} }
    monitor.start()
    try png.write(to: incoming.appendingPathComponent("截图-outside-session.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
    guard importedScreenshots == 0 else { throw AppError.message("Idle monitor imported historical/new files") }
    monitor.beginCaptureSession()
    try png.write(to: incoming.appendingPathComponent("ordinary-image.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
    guard importedScreenshots == 0 else { throw AppError.message("Generic image was mistaken for a screenshot") }
    let synthetic = incoming.appendingPathComponent("截图-current-session.png")
    try png.write(to: synthetic)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.2))
    guard importedScreenshots == 1 else { throw AppError.message("Active session failed to import exactly one screenshot: \(importedScreenshots)") }
    try FileManager.default.removeItem(at: copies[0])
    // New monitor reads the durable ledger: deleting the managed copy must not reset history.
    let restarted = ScreenshotMonitor(excluding: storage, watchDirectory: incoming, importImage: accept)
    defer { withExtendedLifetime(restarted) {} }
    restarted.start(); restarted.beginCaptureSession()
    try png.write(to: incoming.appendingPathComponent("截图-renamed-copy.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.2))
    guard importedScreenshots == 1 else { throw AppError.message("Deleted screenshot resurrected after restart/rename") }
    restarted.cancelCaptureSession()
    let alternate = NSImage(size: NSSize(width: 64, height: 32), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }
    let differentPNG = NSBitmapImageRep(data: alternate.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    restarted.beginCaptureSession(); restarted.cancelCaptureSession()
    try differentPNG.write(to: incoming.appendingPathComponent("截图-canceled.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
    guard importedScreenshots == 1 else { throw AppError.message("Canceled session imported an image") }
    restarted.beginCaptureSession(duration: 0.1)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
    try differentPNG.write(to: incoming.appendingPathComponent("截图-expired.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
    guard importedScreenshots == 1 else { throw AppError.message("Expired session imported an image") }
    restarted.beginCaptureSession()
    try differentPNG.write(to: incoming.appendingPathComponent("截图-next-session.png"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.2))
    guard importedScreenshots == 2 else { throw AppError.message("A genuinely new screenshot was rejected") }
    guard shelf.window!.frame.height == 84 else { throw AppError.message("Shelf height must remain 84") }
    var clipboardImports = 0
    let clipboardStorage = output.appendingPathComponent("clipboard-fixtures-\(UUID().uuidString)")
    let clipboardMonitor = ScreenshotMonitor(excluding: clipboardStorage, watchDirectory: incoming, importClipboard: { _ in clipboardImports += 1; return true }, importImage: { _ in false })
    defer { withExtendedLifetime(clipboardMonitor) {} }
    clipboardMonitor.start()
    clipboardMonitor.receiveClipboard(changeCount: 10000001, types: ["public.png"], png: png, targetClipboard: true)
    guard clipboardImports == 0 else { throw AppError.message("Clipboard image imported outside capture session") }
    clipboardMonitor.beginCaptureSession(clipboardRequested: true)
    clipboardMonitor.receiveClipboard(changeCount: 10000002, types: ["public.png"], png: png, targetClipboard: true)
    guard clipboardImports == 1 else { throw AppError.message("System PNG without screenshot-specific type was missed") }
    clipboardMonitor.beginCaptureSession(clipboardRequested: false)
    clipboardMonitor.receiveClipboard(changeCount: 10000003, types: ["public.png"], png: differentPNG, targetClipboard: false)
    guard clipboardImports == 1 else { throw AppError.message("Ordinary copied image imported into file capture session") }
    clipboardMonitor.cancelCaptureSession(); clipboardMonitor.beginCaptureSession(clipboardRequested: true)
    clipboardMonitor.receiveClipboard(changeCount: 10000004, types: ["public.png"], png: png, targetClipboard: true)
    guard clipboardImports == 1 else { throw AppError.message("Clipboard screenshot persistent dedup failed") }
    print("PASS: clipboard-target ordinary PNG capture; no session exclusion; ordinary copy exclusion; clipboard dedup; HEIF extension supported: \(imageExtensions.contains("heif"))")
    print("PASS: hover, leave, re-entry and drag countdown policy; session-only screenshot intake; history and generic-image exclusion; cancellation/timeout; persistent dedup after deleting copy, restarting and renaming; new screenshot accepted.")
    print("Rendered shelf and MD / JSON / XML / CSV / TXT editors; checked alternate views, text and table persistence. Artifacts: \(output.path)")
}
