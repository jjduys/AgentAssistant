import AppKit
import Darwin
import Carbon

@MainActor func runUITests() throws {
    let menuIcon = BrandIcon.statusIcon()
    guard menuIcon.isTemplate, menuIcon.size == NSSize(width: 22, height: 22),
          menuIcon.accessibilityDescription == "AgentAssistant 智能体助手" else { throw AppError.message("Assistant menu-bar icon branding/template failed") }
    for size in [16, 32, 128, 256, 512, 1024] {
        let bitmap = BrandIcon.appIcon(size: size)
        guard bitmap.pixelsWide == size, bitmap.pixelsHigh == size,
              bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01,
              bitmap.colorAt(x: size / 2, y: size / 2)!.alphaComponent > 0.99,
              bitmap.representation(using: .png, properties: [:]) != nil else { throw AppError.message("Assistant app icon rendering failed at \(size)") }
    }
    print("PASS: AgentAssistant template menu icon and 16–1024 px app icon rendering, transparency and PNG encoding")
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
        ("02-数据.json", "{\"project\":\"AgentAssistant\",\"enabled\":true,\"items\":[{\"name\":\"便签\",\"count\":3}],\"empty\":null}"),
        ("03-结构.xml", "<?xml version=\"1.0\"?><workspace name=\"AgentAssistant\"><note status=\"draft\">随时记录</note><!--保留注释--></workspace>"),
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
        ("AgentAssistant 图片便签" as NSString).draw(at: NSPoint(x: 140, y: 165), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: NSColor.white]); return true
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
    for corner in TriggerCorner.allCases {
        shelf.triggerCorner = corner; shelf.present(on: NSScreen.main!)
        guard shelf.window!.frame == corner.shelfFrame(in: NSScreen.main!.visibleFrame) else { throw AppError.message("Shelf not placed at selected edge") }
    }
    try render(shelf.window!, "shelf-bottom"); shelf.close()
    let settingsUI = SettingsController(settings: AppSettings())
    var applied: AppSettings?
    settingsUI.onApply = { applied = $0 }
    settingsUI.showWindow(nil)
    try render(settingsUI.window!, "settings")
    let settingsViews = descendants(settingsUI.window!.contentView!)
    let recorders = settingsViews.compactMap { $0 as? ShortcutRecorder }
    guard recorders.count == 2, let cornerPopup = settingsViews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton,
          let saveButton = settingsViews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "保存" }) else { throw AppError.message("Settings controls missing") }
    recorders[1].performClick(nil)
    let recordedEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0, windowNumber: settingsUI.window!.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
    guard recorders[1].performKeyEquivalent(with: recordedEvent), recorders[1].shortcut.keyCode == 38, !recorders[1].recording else { throw AppError.message("Shortcut recorder failed") }
    recorders[0].shortcut = recorders[1].shortcut
    saveButton.performClick(nil)
    guard applied == nil, settingsUI.window!.isVisible else { throw AppError.message("Duplicate shortcuts were accepted") }
    recorders[0].shortcut = .shelf; cornerPopup.selectItem(at: 3); saveButton.performClick(nil)
    guard applied?.triggerCorner == .bottomRight, applied?.latestShortcut == recorders[1].shortcut else { throw AppError.message("Settings did not apply captured values") }
    print("PASS: settings rendering, shortcut recording, duplicate rejection, corner selection; shelf placement on all four corners")
    var importedScreenshots = 0
    let unavailableMonitor = ScreenshotMonitor(excluding: storage, watchDirectory: output.appendingPathComponent("missing-\(UUID().uuidString)"), importImage: { _ in false })
    unavailableMonitor.start()
    guard !unavailableMonitor.status.hasPrefix("无法读取") else { throw AppError.message("Idle startup must not access screenshot directory") }
    unavailableMonitor.beginCaptureSession()
    guard unavailableMonitor.status.hasPrefix("无法读取") else { throw AppError.message("Capture session must validate screenshot directory access") }
    defer { withExtendedLifetime(unavailableMonitor) {} }
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
    // Exercise the application actions and Carbon routing with isolated files and uncommon shortcuts.
    // Screenshot monitoring stays disabled; no system clipboard or real user documents are changed.
    let integrationStore = try FileStore(directory: output.appendingPathComponent("actions-\(UUID().uuidString)"))
    let integrationSettings = AppSettings(
        shelfShortcut: KeyboardShortcut(keyCode: 80, modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F19"),
        latestShortcut: KeyboardShortcut(keyCode: 79, modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F18"), triggerCorner: .topLeft)
    let demoPower = DemoPowerService()
    let appDelegate = AppDelegate(store: integrationStore, settings: integrationSettings, monitorsScreenshots: false, powerService: demoPower)
    appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { withExtendedLifetime(appDelegate) {} }
    let powerMenu = appDelegate.contextMenu()
    guard powerMenu.items[1].isSeparatorItem, powerMenu.items[4].isSeparatorItem,
          powerMenu.items[3].title == "刷新状态", !powerMenu.items[0].isEnabled,
          powerMenu.items[2].target is SleepMenuController else { throw AppError.message("Sleep menu must contain the three requested entries before existing actions") }
    func waitForPowerTitle(_ title: String) throws {
        let deadline = Date(timeIntervalSinceNow: 5)
        while powerMenu.items[0].title != title && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
        guard powerMenu.items[0].title == title else { throw AppError.message("Sleep menu did not update to \(title): \(powerMenu.items[0].title)") }
    }
    try waitForPowerTitle("永不睡眠：已关闭")
    guard powerMenu.items[2].title == "开启永不睡眠" else { throw AppError.message("Wrong sleep toggle label") }
    NSApp.sendAction(powerMenu.items[2].action!, to: powerMenu.items[2].target, from: powerMenu.items[2])
    try waitForPowerTitle("永不睡眠：已开启")
    guard try demoPower.readEnabled(), powerMenu.items[2].title == "关闭永不睡眠" else { throw AppError.message("Sleep menu action did not enable the backend") }
    try demoPower.setEnabled(false)
    NSApp.sendAction(powerMenu.items[3].action!, to: powerMenu.items[3].target, from: powerMenu.items[3])
    try waitForPowerTitle("永不睡眠：已关闭")
    print("PASS: actual context-menu entries/order; disabled status row; toggle enable/disable labels and action; refresh observes external change (isolated memory backend, no system writes)")
    func sendHotKey(_ id: UInt32) throws {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &event) == noErr, let event else { throw AppError.message("Cannot create hotkey test event") }
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x54434E54, id: id)
        guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr,
              SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr else { throw AppError.message("Hotkey handler did not route action \(id)") }
    }
    var registrationProbe: ShelfHotKey? = ShelfHotKey(shortcut: integrationSettings.latestShortcut, identifier: 99) {}
    guard registrationProbe?.isRegistered == false else { throw AppError.message("App latest shortcut not registered or conflict undetected") }
    registrationProbe = nil
    try sendHotKey(2) // Empty store opens shelf instead of crashing.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("# 粘贴场景\n\n正文", forType: .string)
    NotificationCenter.default.post(name: .init("AgentAssistantPasteboardDrop"), object: pasteboard)
    guard let note = integrationStore.latestFile(), note.ext == "md", try readText(note.url) == "# 粘贴场景\n\n正文" else { throw AppError.message("Application paste did not create Markdown") }
    try sendHotKey(2)
    guard let noteWindow = NSApp.windows.first(where: { $0.representedURL == note.url && $0.isVisible }) else { throw AppError.message("Latest shortcut did not open text editor") }
    noteWindow.miniaturize(nil); try sendHotKey(2)
    guard !noteWindow.isMiniaturized else { throw AppError.message("Latest shortcut must restore minimized editor") }
    let preview = try integrationStore.create(name: "latest.png", data: png)
    try sendHotKey(2)
    guard let previewWindow = NSApp.windows.first(where: { $0.representedURL == preview && $0.isVisible }), descendants(previewWindow.contentView!).contains(where: { $0 is NSImageView }) else { throw AppError.message("Latest shortcut did not preview image") }
    // A CLI-launched UI harness cannot become the active macOS app reliably.
    // Inject the window delegate notification, as the editor edit tests inject their notifications.
    noteWindow.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: noteWindow))
    guard integrationStore.latestFile()?.url.standardizedFileURL.path == note.url.standardizedFileURL.path else { throw AppError.message("Editor reactivation failed to update access time; key=\(NSApp.keyWindow?.title ?? "nil"), order=\(integrationStore.files().map { "\($0.name):\($0.lastAccessed.timeIntervalSince1970)" })") }
    try sendHotKey(2)
    guard NSApp.windows.filter({ $0.representedURL == note.url }).count == 1 else { throw AppError.message("Latest shortcut duplicated existing editor") }
    try sendHotKey(1); try sendHotKey(1)
    noteWindow.performClose(nil); previewWindow.performClose(nil)
    print("PASS: Carbon registration/conflict and independent action routing; actual application Markdown paste; latest text editor/image preview; minimized-window restore; injected editor activation callback; existing-window reuse; empty store")
    print("Rendered shelf, settings and MD / JSON / XML / CSV / TXT editors; checked alternate views, text and table persistence. Artifacts: \(output.path)")
}
