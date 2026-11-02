import AppKit
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static let shelf = KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
    static let latest = KeyboardShortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey | optionKey), keyLabel: "Return")
    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + keyLabel
    }
    var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return keyCode < 128 && !keyLabel.isEmpty && modifiers & ~allowed == 0 && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }
    static func capture(_ event: NSEvent) -> KeyboardShortcut? {
        var modifiers: UInt32 = 0
        for (flag, carbon): (NSEvent.ModifierFlags, Int) in [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc", 76: "Enter", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = names[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
}

enum TriggerCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self { case .topLeft: return "左上角"; case .topRight: return "右上角"; case .bottomLeft: return "左下角"; case .bottomRight: return "右下角" }
    }
    var isTop: Bool { self == .topLeft || self == .topRight }
    // A small corner target, independent of menu-bar and Dock visibility.
    func contains(_ point: NSPoint, in frame: NSRect) -> Bool {
        let size: CGFloat = 32
        let left = self == .topLeft || self == .bottomLeft
        return NSRect(x: left ? frame.minX : frame.maxX - size, y: isTop ? frame.maxY - size : frame.minY, width: size, height: size).contains(point)
    }
    func shelfFrame(in visible: NSRect) -> NSRect {
        NSRect(x: visible.minX + 10, y: isTop ? visible.maxY - 88 : visible.minY + 4, width: visible.width - 20, height: 84)
    }
}

struct AppSettings: Codable, Equatable {
    var shelfShortcut = KeyboardShortcut.shelf
    var latestShortcut = KeyboardShortcut.latest
    var triggerCorner = TriggerCorner.topLeft
    // Keep the legacy preference key so existing shortcuts and corner choices survive.
    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: "TCenter.settings"), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.shelfShortcut.isValid, value.latestShortcut.isValid,
              !value.shortcutsConflict else { return Self() }
        return value
    }
    var shortcutsConflict: Bool { shelfShortcut.keyCode == latestShortcut.keyCode && shelfShortcut.modifiers == latestShortcut.modifiers }
    func save(to defaults: UserDefaults = .standard) throws { defaults.set(try JSONEncoder().encode(self), forKey: "TCenter.settings") }
}

final class ShortcutRecorder: NSButton {
    var shortcut: KeyboardShortcut { didSet { recording = false; title = shortcut.display } }
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    init(shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.display; bezelStyle = .rounded; target = self; action = #selector(startRecording)
        toolTip = "点击后按组合键；至少包含 Control、Option 或 Command。Esc 取消。"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func startRecording() { recording = true; title = "请按快捷键…"; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { recording = false; title = shortcut.display; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = shortcut.display; return }
        guard let value = KeyboardShortcut.capture(event) else { NSSound.beep(); return }
        shortcut = value; recording = false
    }
}

final class SettingsController: NSWindowController, NSWindowDelegate {
    private let shelfRecorder: ShortcutRecorder
    private let latestRecorder: ShortcutRecorder
    private let corner = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    var onApply: ((AppSettings) throws -> Void)?
    var onClose: (() -> Void)?
    init(settings: AppSettings) {
        shelfRecorder = ShortcutRecorder(shortcut: settings.shelfShortcut)
        latestRecorder = ShortcutRecorder(shortcut: settings.latestShortcut)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AgentAssistant 设置"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center(); window.contentView = EditorBackgroundView()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        corner.addItems(withTitles: TriggerCorner.allCases.map(\.title))
        corner.selectItem(at: TriggerCorner.allCases.firstIndex(of: settings.triggerCorner)!)
        for (title, control) in [("展开 / 收起吊栏", shelfRecorder as NSView), ("打开最近访问文件", latestRecorder as NSView), ("鼠标触发位置", corner as NSView)] {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 180).isActive = true
            control.widthAnchor.constraint(equalToConstant: 230).isActive = true
            let row = NSStackView(views: [label, control]); row.spacing = 12; root.addArrangedSubview(row)
        }
        let hint = NSTextField(wrappingLabelWithString: "点击快捷键后按新的组合键，Esc 取消录入。设置窗口打开时，全局快捷键暂停。鼠标进入所选屏幕角落的 32 × 32 点区域时展开吊栏。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor; root.addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        message.font = .systemFont(ofSize: 12); message.textColor = .systemRed; root.addArrangedSubview(message); message.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetSettings))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings))
        let save = NSButton(title: "保存", target: self, action: #selector(applySettings)); save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, cancel, save]); buttons.spacing = 12; root.addArrangedSubview(buttons)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func resetSettings() { shelfRecorder.shortcut = .shelf; latestRecorder.shortcut = .latest; corner.selectItem(at: 0); message.stringValue = "" }
    @objc private func cancelSettings() { close() }
    @objc private func applySettings() {
        guard !shelfRecorder.recording, !latestRecorder.recording else { message.stringValue = "请先完成快捷键录入，或按 Esc 取消录入。"; return }
        let value = AppSettings(shelfShortcut: shelfRecorder.shortcut, latestShortcut: latestRecorder.shortcut, triggerCorner: TriggerCorner.allCases[corner.indexOfSelectedItem])
        guard !value.shortcutsConflict else { message.stringValue = "两个功能不能使用相同的快捷键。"; return }
        do { try onApply?(value); close() } catch { message.stringValue = error.localizedDescription }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
