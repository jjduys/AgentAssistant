import AppKit
import CryptoKit
import Darwin

/// A capture session accepts only fresh screenshots. The directory is never an import queue.
final class ScreenshotMonitor {
    private struct Receipt: Codable {
        let identifiers: [String]
        let source: String
        let processedAt: Date
    }
    private let testDirectory: URL?
    private let excludedDirectory: URL
    private let historyURL: URL
    private let importImage: (URL) -> Bool
    private let importClipboard: ((Data) -> Bool)?
    private var receipts: [Receipt] = []
    private var processed = Set<String>()
    private var historyReady = true
    private var folders: [URL] = []
    private var baseline = Set<String>()
    private var sessionStart: Date?
    private var deadline = Date.distantPast
    private var pending: [String: (size: Int, modified: Date, since: Date)] = [:]
    private var clipboardCount = NSPasteboard.general.changeCount
    private var clipboardExpected = false
    private static let captureApplications: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher"]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var localKeys: Any?
    private var globalKeys: Any?
    private var toolbarVisible = false
    private(set) var status = "等待截图操作；历史图片不会自动导入"

    init(excluding directory: URL, watchDirectory: URL? = nil, importClipboard: ((Data) -> Bool)? = nil, importImage: @escaping (URL) -> Bool) {
        testDirectory = watchDirectory; excludedDirectory = directory.standardizedFileURL
        historyURL = directory.deletingLastPathComponent().appendingPathComponent(watchDirectory == nil ? "screenshot-history.json" : "screenshot-history-\(directory.lastPathComponent).json")
        self.importImage = importImage; self.importClipboard = importClipboard
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: historyURL))
                processed = Set(receipts.flatMap(\.identifiers))
            }
        } catch { historyReady = false; status = "截图记录无法读取，已暂停自动挂载；可用 ⌘V" }
    }
    private func configuredClipboardTarget() -> Bool {
        if testDirectory != nil { return false }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        for key in ["target-screenshot", "target"] {
            if let target = CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString) as? String { return target == "clipboard" }
        }
        return false
    }
    private func directories() -> [URL] {
        if let testDirectory { return [testDirectory.standardizedFileURL] }
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // Prefer the screenshot-specific setting; do not scan a previous output folder.
        for key in ["location-screenshot", "location"] {
            if let path = CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString) as? String,
               path.hasPrefix("/") || path.hasPrefix("~") {
                return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL]
            }
        }
        return [FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.standardizedFileURL]
    }
    private func files() throws -> [URL] {
        try folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: .skipsHiddenFiles) }
    }
    private func rebase() -> Bool {
        do { baseline = Set(try files().map { $0.standardizedFileURL.path }); return true }
        catch { status = "无法读取截图目录，自动挂载暂停：\(error.localizedDescription)"; return false }
    }
    func start() {
        folders = directories(); if !configuredClipboardTarget() { _ = rebase() }
        if testDirectory == nil {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       Self.captureApplications.contains(app.bundleIdentifier ?? "") { self?.beginCaptureSession() }
                })
            }
            localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKey(event); return event }
            // Optional: macOS may not deliver global keys without existing accessibility access.
            // Toolbar visibility and workspace notifications remain independent event sources.
            globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handleKey($0) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.scan() }
    }
    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { cancelCaptureSession(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.command, .shift]), [20, 21, 23].contains(event.keyCode) { beginCaptureSession(clipboardRequested: flags.contains(.control) ? true : nil, restart: true) }
    }
    // Internal entry point shared by actual capture events and isolated regression checks.
    func beginCaptureSession(duration: TimeInterval = 120, clipboardRequested: Bool? = nil, restart: Bool = false) {
        guard historyReady else { return }
        if sessionStart != nil && !restart { return }
        cancelCaptureSession(); folders = directories()
        clipboardExpected = clipboardRequested ?? configuredClipboardTarget()
        if !clipboardExpected { guard rebase() else { return } }
        sessionStart = Date(); deadline = Date(timeIntervalSinceNow: duration)
        clipboardCount = NSPasteboard.general.changeCount
        status = clipboardExpected ? "等待本次截图写入剪贴板" : "等待本次截图保存为文件"
    }
    func cancelCaptureSession() {
        sessionStart = nil; deadline = .distantPast; pending.removeAll()
        if historyReady { status = "等待截图操作；历史图片不会自动导入" }
    }
    private func observeToolbar() {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { Self.captureApplications.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
            // Restrict to the toolbar shape, excluding screen-sized overlays and floating thumbnails.
            return width >= 400 && width <= 1100 && height >= 35 && height <= 200
        }
        if visible && !toolbarVisible { beginCaptureSession() }
        if !visible && toolbarVisible, sessionStart != nil { deadline = min(deadline, Date(timeIntervalSinceNow: 30)) }
        toolbarVisible = visible
    }
    private func isScreenshot(_ url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = url.path.withCString { path in key.withCString { getxattr(path, $0, nil, 0, 0, 0) } }
        return size > 0 || ["screenshot", "screen shot", "截屏", "截图", "屏幕快照"].contains { url.lastPathComponent.lowercased().hasPrefix($0) }
    }
    private func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return "file:\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    private func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func persist() throws {
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: historyURL, options: .atomic)
    }
    private func deliver(ids: [String], source: String, action: () -> Bool) {
        guard !ids.contains(where: processed.contains) else { return }
        // Reserve durably before copying. A crash can miss one import but cannot resurrect deleted files.
        let receipt = Receipt(identifiers: ids, source: source, processedAt: Date())
        receipts.append(receipt)
        do { try persist() } catch {
            receipts.removeLast(); status = "截图记录保存失败，未导入：\(error.localizedDescription)"; return
        }
        processed.formUnion(ids)
        if action() { cancelCaptureSession(); status = "已挂载本次截图" }
        else {
            receipts.removeLast(); processed.subtract(ids)
            do { try persist() } catch { historyReady = false }
            status = "本次截图导入失败，可用 ⌘V 重试"
        }
    }
    private func scan() {
        guard historyReady else { return }
        if testDirectory == nil { observeToolbar() }
        guard let start = sessionStart else {
            let current = directories()
            if current != folders { folders = current; if !configuredClipboardTarget() { _ = rebase() } }
            return
        }
        guard Date() <= deadline else { cancelCaptureSession(); return }
        if testDirectory == nil { scanClipboard() }
        guard sessionStart != nil else { return }
        // Clipboard-only capture must not depend on access to Desktop or any output directory.
        if clipboardExpected || configuredClipboardTarget() { return }
        let current = directories()
        if current != folders { folders = current; pending.removeAll(); guard rebase() else { cancelCaptureSession(); return } }
        do {
            for input in try files() {
                guard sessionStart != nil else { break }
                let url = input.standardizedFileURL
                guard !baseline.contains(url.path), !url.path.hasPrefix(excludedDirectory.path + "/"),
                      imageExtensions.contains(url.pathExtension.lowercased()), isScreenshot(url),
                      let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let created = values.creationDate, created >= start,
                      let modified = values.contentModificationDate, let size = values.fileSize, size > 0,
                      let identity = fileIdentity(url), !processed.contains(identity) else { continue }
                if let old = pending[identity], old.size == size, old.modified == modified, Date().timeIntervalSince(old.since) >= 0.8 {
                    let data = try Data(contentsOf: url)
                    guard NSImage(data: data) != nil else { continue }
                    deliver(ids: [identity, digest(data)], source: url.path) { importImage(url) }
                } else if pending[identity]?.size != size || pending[identity]?.modified != modified {
                    pending[identity] = (size, modified, Date())
                }
            }
        } catch { status = "截图读取失败：\(error.localizedDescription)" }
    }
    private func scanClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != clipboardCount else { return }
        let png = board.data(forType: .png) ?? board.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            ?? board.data(forType: NSPasteboard.PasteboardType("public.heic")).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            ?? board.data(forType: NSPasteboard.PasteboardType("public.heif")).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        receiveClipboard(changeCount: board.changeCount, types: (board.types ?? []).map(\.rawValue), png: png, targetClipboard: configuredClipboardTarget())
    }
    // System screenshots can advertise only ordinary PNG/TIFF types. A capture event plus the
    // system's clipboard target (or Control modifier) identifies the intended new result.
    func receiveClipboard(changeCount: Int, types: [String], png: Data?, targetClipboard: Bool) {
        guard sessionStart != nil, Date() <= deadline, changeCount != clipboardCount else { return }
        clipboardCount = changeCount
        let marked = types.contains { $0.lowercased().contains("screencapture") }
        guard marked || clipboardExpected || targetClipboard, let png, NSImage(data: png) != nil else { return }
        deliver(ids: [digest(png)], source: "system-screenshot-clipboard") { importClipboard?(png) ?? false }
    }
    deinit {
        timer?.invalidate()
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
