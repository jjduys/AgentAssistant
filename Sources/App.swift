import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: FileStore!
    private var shelf: ShelfController!
    private var editors: [URL: EditorController] = [:]
    private var timer: Timer?
    private var screenshotMonitor: ScreenshotMonitor?
    private var shelfHotKey: ShelfHotKey?
    private var menuBarHoverTimer: Timer?
    private var pointerWasInMenuBar = false
    private var showingAbout = false
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try FileStore() } catch { showError(error); NSApp.terminate(nil); return }
        installMainMenu()
        shelf = ShelfController(store: store)
        shelf.openFile = { [weak self] in self?.openFile($0) }; shelf.deleteFile = { [weak self] in self?.deleteFile($0) }
        shelf.importFiles = { [weak self] urls in if urls.isEmpty { self?.chooseFiles() } else { self?.importFiles(urls) } }
        shelf.paste = { [weak self] in self?.pasteFrom(.general) }
        shelf.addMenu = additionMenu()
        store.onChange = { [weak self] in guard let self, self.shelf.window?.isVisible == true else { return }; self.shelf.refresh() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button { button.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "TCenter 临时编辑中心"); button.image?.isTemplate = true; button.toolTip = "TCenter · 移入顶部菜单栏展开，⌃⌥空格 展开 / 收起，右键打开菜单"; button.target = self; button.action = #selector(statusClicked); button.sendAction(on: [.leftMouseUp, .rightMouseUp]) }
        shelf.isStatusBarEvent = { [weak self] event in event.window === self?.statusItem.button?.window }
        shelf.isPointerOverTrigger = { [weak self] in self?.menuBarScreen(at: NSEvent.mouseLocation) != nil }
        let hoverTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateMenuBarHover() }
        menuBarHoverTimer = hoverTimer; RunLoop.main.add(hoverTimer, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(receiveDrop(_:)), name: .init("TCenterPasteboardDrop"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in guard let self, self.shelf.window?.isVisible == true else { return }; self.shelf.refresh() }
        screenshotMonitor = ScreenshotMonitor(excluding: store.directory, importClipboard: { [weak self] data in
            guard let self else { return false }; do { _ = try self.store.create(name: "截图-\(Int(Date().timeIntervalSince1970)).png", data: data); self.showShelf(); return true } catch { return false }
        }) { [weak self] url in
            guard let self else { return false }
            do { _ = try self.store.importFile(url); self.showShelf(); return true }
            catch { NSLog("Screenshot import failed: %@", error.localizedDescription); return false }
        }
        screenshotMonitor?.start()
        shelfHotKey = ShelfHotKey { [weak self] in self?.toggleShelf() }
        if shelfHotKey?.isRegistered != true {
            statusItem.button?.toolTip = "TCenter · 鼠标移入展开；快捷键注册失败，详情见关于"
        }
        if CommandLine.arguments.contains("--show") { showShelf() }
    }
    private func installMainMenu() {
        let main = NSMenu(); let app = NSMenuItem(); main.addItem(app); let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "关于 TCenter", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出 TCenter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "编辑"; main.addItem(edit); let menu = NSMenu(title: "编辑"); edit.submenu = menu
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { menu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        let fileItem = NSMenuItem(); fileItem.title = "文件"; main.addItem(fileItem); let fm = NSMenu(title: "文件"); fileItem.submenu = fm
        fm.addItem(withTitle: "导入文件…", action: #selector(chooseFiles), keyEquivalent: "o").target = self
        fm.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { shelf.hideShelf(); let menu = contextMenu(); statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil }
        else { toggleShelf() }
    }
    private func menuBarScreen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            // Cover the menu-bar strip, including its empty space, without overlaying it.
            let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            let rect = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            return rect.contains(point)
        }
    }
    private func updateMenuBarHover() {
        let screen = menuBarScreen(at: NSEvent.mouseLocation)
        let inside = screen != nil
        let entered = inside && !pointerWasInMenuBar
        pointerWasInMenuBar = inside
        guard entered, let screen, statusItem.menu == nil, NSApp.modalWindow == nil,
              !showingAbout, NSEvent.pressedMouseButtons == 0, shelf.window?.isVisible != true else { return }
        shelf.present(on: screen)
    }
    @objc private func toggleShelf() {
        if shelf.window?.isVisible == true { shelf.hideShelf() } else { showShelf() }
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "展开 / 收起挂载线", action: #selector(toggleShelf), keyEquivalent: " ")
        toggle.target = self; toggle.keyEquivalentModifierMask = [.control, .option]
        if shelfHotKey?.isRegistered != true { toggle.title += "（全局快捷键不可用）" }
        menu.addItem(.separator())
        for item in additionMenu().items { menu.addItem(item.copy() as! NSMenuItem) }
        for (title, action) in [("打开存储目录", #selector(revealStore)), ("关于 TCenter", #selector(about))] { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
        menu.addItem(.separator()); menu.addItem(withTitle: "退出 TCenter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); return menu
    }
    func additionMenu() -> NSMenu {
        let menu = NSMenu()
        let newItem = NSMenuItem(title: "新建", action: nil, keyEquivalent: ""); let submenu = NSMenu(); newItem.submenu = submenu
        for ext in ["md", "txt", "json", "xml", "csv"] { let item = submenu.addItem(withTitle: ext.uppercased() + " 文档", action: #selector(createFromMenu(_:)), keyEquivalent: ""); item.target = self; item.representedObject = ext }
        menu.addItem(newItem)
        menu.addItem(withTitle: "导入文件…", action: #selector(chooseFiles), keyEquivalent: "").target = self
        return menu
    }
    @objc private func showShelf() {
        let mouse = NSEvent.mouseLocation; let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        shelf.present(on: screen)
    }
    @objc private func chooseFiles() {
        shelf.hideShelf(); NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }; panel.message = "文件会复制到 TCenter，原文件保留。"
        if panel.runModal() == .OK { importFiles(panel.urls) } else { showShelf() }
    }
    private func importFiles(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls { do { _ = try store.importFile(url) } catch { errors.append(error.localizedDescription) } }
        showShelf(); if !errors.isEmpty { showError(AppError.message(errors.joined(separator: "\n"))) }
    }
    @objc private func createFromMenu(_ sender: NSMenuItem) { if let ext = sender.representedObject as? String { create(ext) } }
    private func create(_ ext: String) {
        shelf.hideShelf(); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "新建 \(ext.uppercased()) 文档"; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); input.stringValue = "未命名"; alert.accessoryView = input; alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { showShelf(); return }
        let base = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "未命名.\(ext)" : base.lowercased().hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
        let initial = ext == "json" ? "{\n  \"note\": \"\"\n}\n" : ext == "xml" ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<note>\n  <text></text>\n</note>\n" : ext == "csv" ? "名称,内容\n便签,\n" : ext == "md" ? "# 便签\n\n" : ""
        do { openFile(try store.create(name: name, data: Data(initial.utf8))) } catch { showError(error) }
    }
    private func openFile(_ inputURL: URL) {
        let url = inputURL.standardizedFileURL
        shelf.hideShelf(); NSApp.activate(ignoringOtherApps: true)
        if let editor = editors[url] { editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); return }
        do {
            let editor = try EditorController(file: MountedFile(url: url), store: store); editors[url] = editor
            editor.onClose = { [weak self] in self?.editors.removeValue(forKey: url) }
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        } catch { showError(error); showShelf() }
    }
    private func deleteFile(_ inputURL: URL) {
        let url = inputURL.standardizedFileURL
        if let editor = editors[url] { editor.window?.makeFirstResponder(nil); guard editor.flush() else { showError(AppError.message("当前修改保存失败，请先处理编辑窗口。")); return }; editor.close() }
        do { try store.trash(url) } catch { showError(error) }
    }
    @objc private func pasteAction() { pasteFrom(.general) }
    @objc private func receiveDrop(_ notification: Notification) { if let pasteboard = notification.object as? NSPasteboard { pasteFrom(pasteboard) } }
    private func pasteFrom(_ pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { importFiles(urls); return }
        do {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; let stamp = formatter.string(from: Date())
            if let png = pasteboard.data(forType: .png) { _ = try store.create(name: "截图-\(stamp).png", data: png) }
            else if let data = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) { _ = try store.create(name: "截图-\(stamp).png", data: png) }
            else if let text = pasteboard.string(forType: .string) { _ = try store.create(name: "便签-\(stamp).txt", data: Data(text.utf8)) }
            else { throw AppError.message("剪贴板中没有可挂载的文件、图片或文字。") }
            showShelf()
        } catch { showError(error) }
    }
    @objc private func revealStore() { NSWorkspace.shared.open(store.directory) }
    @objc private func about() {
        guard !showingAbout else { return }
        showingAbout = true
        shelf.hideShelf()
        // Let the status-item menu finish tracking before bringing up the modal window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.showingAbout = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "TCenter \(self.appVersion)（构建 \(self.appBuild)）"
            alert.informativeText = "临时编辑中心\n\n鼠标移入屏幕顶部菜单栏（含空白处）展开挂绳。\n⌃⌥空格或点击回形针：展开 / 收起\n停留时保持显示，离开后 3 秒收起。\n\n截图监听：\(self.screenshotMonitor?.status ?? "未启动")\n快捷键：\(self.shelfHotKey?.isRegistered == true ? "⌃⌥空格" : "注册失败，可能被其他应用占用")\n\n存储目录：\(self.store.directory.path)"
            alert.addButton(withTitle: "好")
            alert.window.level = .floating
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
            alert.runModal()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for editor in editors.values { editor.window?.makeFirstResponder(nil); if !editor.flush() { showError(AppError.message("有文件保存失败，已取消退出。")); return .terminateCancel } }; return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showShelf(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { importFiles(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success) }
}
