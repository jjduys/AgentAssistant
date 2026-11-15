import AppKit
import UniformTypeIdentifiers

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ShelfDismissalPolicy {
    private(set) var deadline: Date?
    mutating func update(inside: Bool, dragging: Bool, now: Date) {
        if inside || dragging { deadline = nil }
        else if deadline == nil { deadline = now.addingTimeInterval(3) }
    }
    func shouldDismiss(at now: Date) -> Bool { deadline.map { now >= $0 } ?? false }
}

/// 吊栏卡片条的几何：左旧右新，最多同时显示 7 张，其余折叠在左侧。
struct ShelfStripLayout {
    static let cardWidth: CGFloat = 112, spacing: CGFloat = 24, inset: CGFloat = 8, maxVisible = 7
    static var pitch: CGFloat { cardWidth + spacing }
    static func visibleCount(total: Int, availableWidth: CGFloat) -> Int {
        guard total > 0 else { return 0 }
        let fit = Int(floor((availableWidth - 2 * inset + spacing) / pitch))
        return max(1, min(maxVisible, total, fit))
    }
    static func width(cards count: Int) -> CGFloat { count <= 0 ? 0 : CGFloat(count) * pitch - spacing + 2 * inset }
    static func cardX(_ index: Int) -> CGFloat { inset + CGFloat(index) * pitch }
    /// 初始滚动位置：贴住最右侧，让最新的文件可见。
    static func newestOffset(total: Int, viewport: CGFloat) -> CGFloat { max(0, width(cards: total) - viewport) }
}

final class ShelfController: NSWindowController {
    let store: FileStore
    var openFile: ((URL) -> Void)?
    var accessFile: ((URL) -> Void)?
    var triggerCorner = TriggerCorner.topLeft
    var deleteFile: ((URL) -> Void)?
    var importFiles: (([URL]) -> Void)?
    var paste: (() -> Void)?
    var addMenu: NSMenu?
    var isStatusBarEvent: ((NSEvent) -> Bool)?
    var isPointerOverTrigger: (() -> Bool)?
    private let canvas = ShelfCanvas()
    private let scrollView = NSScrollView()
    private let cards = NSView()
    private let addButton = NSButton()
    private var showingAddMenu = false
    private let empty = NSTextField(labelWithString: "拖入文件，或按 ⌘V 粘贴")
    private var dismissTimer: Timer?
    private var dismissal = ShelfDismissalPolicy()
    private var dragActive = false
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var signature = ""
    private let olderLabel = NSTextField(labelWithString: "")
    private let newerLabel = NSTextField(labelWithString: "")
    private var stripWidth: NSLayoutConstraint!
    private var boundsObserver: Any?
    /// 折叠提示与卡片条两侧预留的宽度。
    private static let foldGutter: CGFloat = 76
    init(store: FileStore) {
        self.store = store
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 84), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.contentView = canvas
        canvas.onPointerChanged = { [weak self] _ in self?.updateDismissal() }
        canvas.onDragChanged = { [weak self] active in self?.dragActive = active; self?.updateDismissal() }
        canvas.onDrop = { [weak self] urls in self?.importFiles?(urls) }; canvas.onPaste = { [weak self] in self?.paste?() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false; scrollView.drawsBackground = false; scrollView.scrollerStyle = .overlay; scrollView.hasHorizontalScroller = true; scrollView.hasVerticalScroller = false; scrollView.autohidesScrollers = true; scrollView.documentView = cards
        canvas.addSubview(scrollView)
        addButton.translatesAutoresizingMaskIntoConstraints = false; addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "添加"); addButton.contentTintColor = .white; addButton.isBordered = false; addButton.toolTip = "添加：新建文档或导入文件"; addButton.setAccessibilityLabel("添加"); addButton.target = self; addButton.action = #selector(showAddMenu); canvas.addSubview(addButton)
        empty.translatesAutoresizingMaskIntoConstraints = false; empty.font = .systemFont(ofSize: 11, weight: .medium); empty.textColor = .white.withAlphaComponent(0.65); canvas.addSubview(empty)
        for (label, tip) in [(olderLabel, "鼠标移到左侧查看更早的文件"), (newerLabel, "鼠标移到右侧回到最新的文件")] {
            label.translatesAutoresizingMaskIntoConstraints = false; label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = .white.withAlphaComponent(0.75); label.toolTip = tip; label.isHidden = true; canvas.addSubview(label)
        }
        olderLabel.alignment = .right; newerLabel.alignment = .left
        let centered = scrollView.centerXAnchor.constraint(equalTo: canvas.centerXAnchor); centered.priority = .defaultHigh
        stripWidth = scrollView.widthAnchor.constraint(equalToConstant: 0); stripWidth.priority = .init(999)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 4), scrollView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: Self.foldGutter), scrollView.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -Self.foldGutter), centered, stripWidth,
            addButton.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -12), addButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor), addButton.widthAnchor.constraint(equalToConstant: 28), addButton.heightAnchor.constraint(equalToConstant: 28),
            empty.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            olderLabel.trailingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: -6), olderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: 6),
            newerLabel.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 6), newerLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: 6)
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.updateFoldLabels() }
    }
    /// 当前折叠在左侧（更早）和右侧（更新）的卡片数量。
    var foldedCounts: (older: Int, newer: Int) {
        let origin = scrollView.contentView.bounds.minX, width = scrollView.contentView.bounds.width
        let mids = cards.subviews.map(\.frame.midX)
        return (mids.filter { $0 < origin }.count, mids.filter { $0 > origin + width }.count)
    }
    private func updateFoldLabels() {
        let (older, newer) = foldedCounts
        olderLabel.stringValue = "‹ 更早 \(older)"; olderLabel.isHidden = older == 0
        newerLabel.stringValue = "更新 \(newer) ›"; newerLabel.isHidden = newer == 0
    }
    /// 鼠标停在卡片条左侧（或折叠提示上）时向更早的文件滚动，停在右侧时回到更新的文件。
    private func autoScrollTowardPointer() {
        guard let window, window.isVisible, !dragActive, NSEvent.pressedMouseButtons == 0 else { return }
        let strip = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil)), mouse = NSEvent.mouseLocation
        guard mouse.y >= strip.minY, mouse.y <= strip.maxY else { return }
        let clip = scrollView.contentView, maxX = max(0, cards.frame.width - clip.bounds.width), edge: CGFloat = 40, step: CGFloat = 34
        var target = clip.bounds.minX
        if mouse.x >= strip.minX - Self.foldGutter, mouse.x <= strip.minX + edge { target = max(0, target - step) }
        else if mouse.x >= strip.maxX - edge, mouse.x <= strip.maxX + Self.foldGutter { target = min(maxX, target + step) }
        guard target != clip.bounds.minX else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1; context.timingFunction = CAMediaTimingFunction(name: .linear)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(on screen: NSScreen) {
        let visible = screen.visibleFrame
        window?.setFrame(triggerCorner.shelfFrame(in: visible), display: true)
        refresh(force: true); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
        dismissTimer?.invalidate(); dismissal = ShelfDismissalPolicy()
        updateDismissal()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateDismissal(); self?.autoScrollTowardPointer() }
        dismissTimer = timer; RunLoop.main.add(timer, forMode: .common)
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.hideShelf() }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, self.window?.isVisible == true else { return event }
                if event.type == .keyDown, event.window === self.window, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" { self.paste?(); return nil }
                if !self.showingAddMenu && event.type != .keyDown && event.window !== self.window && !(self.isStatusBarEvent?(event) ?? false) { self.hideShelf() }
                return event
            }
        }
    }
    func refresh(force: Bool = false) {
        let files = store.recentFiles(); let next = files.map { "\($0.url.path):\($0.modified.timeIntervalSince1970):\($0.lastAccessed.timeIntervalSince1970)" }.joined(separator: "|")
        guard force || next != signature else { return }; signature = next
        cards.subviews.forEach { $0.removeFromSuperview() }; empty.isHidden = !files.isEmpty
        canvas.layoutSubtreeIfNeeded()
        // 左旧右新：最多同时显示 7 张，超出部分折叠在左侧，初始停在最新的一端。
        let available = canvas.bounds.width - Self.foldGutter * 2 - 12 - 28
        let visible = ShelfStripLayout.visibleCount(total: files.count, availableWidth: available)
        stripWidth.constant = ShelfStripLayout.width(cards: visible)
        canvas.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize.width
        cards.frame = NSRect(x: 0, y: 0, width: max(ShelfStripLayout.width(cards: files.count), viewport), height: 76)
        for (index, file) in files.enumerated() {
            let card = FileCard(file: file, frame: NSRect(x: ShelfStripLayout.cardX(index), y: 0, width: ShelfStripLayout.cardWidth, height: 76))
            card.onDragChanged = { [weak self] active in self?.dragActive = active; self?.updateDismissal() }
            card.onAccess = { [weak self] in self?.accessFile?(file.url) }
            card.open = { [weak self] in self?.openFile?(file.url) }; card.remove = { [weak self] in self?.deleteFile?(file.url) }; cards.addSubview(card)
        }
        scrollView.contentView.scroll(to: NSPoint(x: ShelfStripLayout.newestOffset(total: files.count, viewport: viewport), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateFoldLabels()
    }
    @objc private func showAddMenu() {
        guard let addMenu else { return }
        showingAddMenu = true; dismissal = ShelfDismissalPolicy()
        defer { showingAddMenu = false; updateDismissal() }
        addMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.minY), in: addButton)
    }
    private func updateDismissal() {
        guard let window, window.isVisible, !showingAddMenu else { return }
        if dragActive && NSEvent.pressedMouseButtons == 0 { dragActive = false }
        dismissal.update(inside: window.frame.contains(NSEvent.mouseLocation) || (isPointerOverTrigger?() ?? false), dragging: dragActive, now: Date())
        if dismissal.shouldDismiss(at: Date()) { hideShelf() }
    }
    @objc func hideShelf() {
        dismissTimer?.invalidate(); dismissTimer = nil; dragActive = false; dismissal = ShelfDismissalPolicy(); window?.orderOut(nil)
    }
    deinit {
        dismissTimer?.invalidate()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

}

final class ShelfCanvas: NSView {
    var onPointerChanged: ((Bool) -> Void)?
    var onDragChanged: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onPaste: (() -> Void)?
    private var dragging = false
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL, .png, .tiff, .string]) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointerChanged?(true) }
    override func mouseExited(with event: NSEvent) { onPointerChanged?(false) }
    override func draw(_ dirtyRect: NSRect) {
        let rope = NSBezierPath(); rope.move(to: NSPoint(x: 0, y: bounds.height - 4)); rope.curve(to: NSPoint(x: bounds.width, y: bounds.height - 4), controlPoint1: NSPoint(x: bounds.width * 0.33, y: bounds.height - 12), controlPoint2: NSPoint(x: bounds.width * 0.66, y: bounds.height - 12)); rope.lineWidth = 0.9; NSColor(calibratedWhite: 0.65, alpha: 0.85).setStroke(); rope.stroke()
        if dragging { NSColor.systemTeal.setStroke(); let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 20, yRadius: 20); p.lineWidth = 3; p.stroke() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragging = true; onDragChanged?(true); needsDisplay = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragging = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragging = false; onDragChanged?(false); needsDisplay = true
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { onDrop?(urls); return true }
        NotificationCenter.default.post(name: .init("AgentAssistantPasteboardDrop"), object: sender.draggingPasteboard); return true
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { window?.orderOut(nil) } else { super.keyDown(with: event) } }
    @objc func paste(_ sender: Any?) { onPaste?() }
}

final class FileCard: NSView, NSDraggingSource {
    var onDragChanged: ((Bool) -> Void)?
    var onAccess: (() -> Void)?
    let file: MountedFile
    var open: (() -> Void)?
    var remove: (() -> Void)?
    private var start: NSPoint = .zero
    private var didDrag = false
    private var hover = false
    private let closeButton = NSButton()
    private let preview: NSImage?
    private let excerpt: String
    init(file: MountedFile, frame: NSRect) {
        self.file = file; preview = file.isImage ? NSImage(contentsOf: file.url) : nil
        if !file.isImage, let handle = try? FileHandle(forReadingFrom: file.url) { let data = (try? handle.read(upToCount: 1800)) ?? Data(); excerpt = String(decoding: data, as: UTF8.self); try? handle.close() } else { excerpt = "" }
        super.init(frame: frame)
        toolTip = (file.isClipboardHistory ? "\(file.name)（剪贴板历史，自动记录复制的文字）" : file.name) + "\n点击打开 · 拖动到其他软件 · × 移至废纸篓"
        setAccessibilityLabel(file.isClipboardHistory ? "剪贴板历史 \(file.name)" : file.name)
        closeButton.frame = NSRect(x: 97, y: 46, width: 15, height: 15); closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "移至废纸篓"); closeButton.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1); closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(deleteClicked); closeButton.toolTip = "将挂载副本移至废纸篓"; closeButton.isHidden = true; addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)) }
    override func mouseEntered(with event: NSEvent) { hover = true; closeButton.isHidden = false; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; closeButton.isHidden = true; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let imageHeight: CGFloat
        if let preview { imageHeight = min(46, max(12, 104 * preview.size.height / max(preview.size.width, 1))) }
        else { imageHeight = 46 }
        let rect = NSRect(x: 3, y: 61 - imageHeight, width: 106, height: imageHeight)
        closeButton.frame.origin.y = rect.maxY - 10
        NSGraphicsContext.saveGraphicsState(); let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.4); shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill(); NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).addClip()
        if let preview {
            let size = preview.size; let scale = min((rect.width - 4) / max(size.width, 1), (rect.height - 4) / max(size.height, 1)); let target = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale); preview.draw(in: target)
        } else {
            NSColor.white.setFill(); rect.fill()
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            (excerpt as NSString).draw(in: rect.insetBy(dx: 5, dy: 5), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 3.5, weight: .regular), .foregroundColor: NSColor.black, .paragraphStyle: p])
        }
        NSGraphicsContext.restoreGraphicsState()
        if file.isClipboardHistory { drawClipboardBadge(in: rect) }
        (hover ? NSColor.systemTeal : file.isClipboardHistory ? NSColor.systemOrange : NSColor.black.withAlphaComponent(0.25)).setStroke(); let border = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10); border.lineWidth = hover ? 1.5 : 1; border.stroke()
        let pin = NSRect(x: 53, y: 55, width: 6, height: 20); NSGradient(starting: .white, ending: .gray)?.draw(in: NSBezierPath(roundedRect: pin, xRadius: 3, yRadius: 3), angle: 0)
        let p = NSMutableParagraphStyle(); p.alignment = .left; p.lineBreakMode = .byTruncatingMiddle
        let labelShadow = NSShadow(); labelShadow.shadowColor = .black.withAlphaComponent(0.85); labelShadow.shadowBlurRadius = 3; labelShadow.shadowOffset = NSSize(width: 0, height: -1)
        let date = DateFormatter.localizedString(from: file.lastAccessed, dateStyle: .none, timeStyle: .short)
        let timeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .shadow: labelShadow]
        let timeWidth = ceil((date as NSString).size(withAttributes: timeAttributes).width)
        (file.name as NSString).draw(in: NSRect(x: 3, y: max(0, rect.minY - 12), width: 102 - timeWidth - 5, height: 11), withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: p, .shadow: labelShadow])
        (date as NSString).draw(in: NSRect(x: 109 - timeWidth, y: max(0, rect.minY - 11), width: timeWidth + 2, height: 10), withAttributes: timeAttributes)

    }
    /// Clipboard-history cards carry an orange clipboard badge so they stand apart from ordinary Markdown notes.
    private func drawClipboardBadge(in rect: NSRect) {
        let badge = NSRect(x: rect.maxX - 22, y: rect.minY + 4, width: 18, height: 18)
        NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "剪贴板历史")?.withSymbolConfiguration(config) {
            let size = symbol.size; symbol.draw(in: NSRect(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil); guard !didDrag, hypot(point.x - start.x, point.y - start.y) > 5 else { return }; didDrag = true
        let item = NSDraggingItem(pasteboardWriter: file.url as NSURL); let image = preview ?? NSWorkspace.shared.icon(forFile: file.url.path)
        item.setDraggingFrame(NSRect(x: point.x - 35, y: point.y - 25, width: 70, height: 50), contents: image)
        onDragChanged?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { if !didDrag { open?() } }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragChanged?(false); if !operation.isEmpty { onAccess?() } }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    @objc private func deleteClicked() { remove?() }
}
