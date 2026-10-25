import AppKit

/// Isolated live capture check; never writes into the user's mounted notes.
func runCaptureProbe() throws {
    let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("capture-probe")
    let store = try FileStore(directory: output.appendingPathComponent("Files"))
    let label = NSTextField(wrappingLabelWithString: "请使用 Shift+Command+5 完成一次截图。结果仅写入工程测试目录。")
    label.frame = NSRect(x: 24, y: 30, width: 592, height: 160); label.font = .systemFont(ofSize: 15)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "TCenter 截图验证"; window.contentView?.addSubview(label); window.center(); window.makeKeyAndOrderFront(nil)
    let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); item.submenu = NSMenu(); item.submenu?.addItem(withTitle: "退出验证", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); NSApp.mainMenu = menu
    let result: (URL) -> Bool = { url in
        do { let copy = try store.importFile(url); try Data(copy.path.utf8).write(to: output.appendingPathComponent("success.txt")); return true } catch { return false }
    }
    let monitor = ScreenshotMonitor(excluding: store.directory, importClipboard: { data in
        do { let copy = try store.create(name: "live-system-screenshot.png", data: data); try Data(copy.path.utf8).write(to: output.appendingPathComponent("success.txt")); return true } catch { return false }
    }, importImage: result)
    monitor.start()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        label.stringValue = "Shift+Command+5 实机验证\n\n状态：\(monitor.status)\n已接收：\(store.files().count) 张\n\n剪贴板类型：\((NSPasteboard.general.types ?? []).map(\.rawValue).joined(separator: ", "))"
    }
    defer { timer.invalidate(); withExtendedLifetime(monitor) {} }
    NSApp.activate(ignoringOtherApps: true); NSApp.run()
}
