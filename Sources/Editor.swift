import AppKit

final class EditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let file: MountedFile
    let store: FileStore
    var onClose: (() -> Void)?
    var onAccess: (() -> Void)?
    private let body = NSView()
    private let status = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["编辑", "源码"], trackingMode: .selectOne, target: nil, action: nil)
    private let textView = NSTextView()
    private var table: NSTableView?
    private var outline: NSOutlineView?
    private var rows: [[String]] = []
    private var json: JSONNode?
    private var xml: XMLDocument?
    private var xmlRoot: XMLTreeNode?
    private var currentText = ""
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private var sourceMode = false
    private var loading = false
    private var controls: NSStackView!

    init(file: MountedFile, store: FileStore) throws {
        self.file = file; self.store = store
        if !file.isImage { currentText = try readText(file.url) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = file.name; window.minSize = NSSize(width: 620, height: 420); window.isReleasedWhenClosed = false
        window.representedURL = file.url
        super.init(window: window); window.delegate = self; window.center()
        let root = EditorBackgroundView(); window.contentView = root
        controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 10; controls.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let tag = NSTextField(labelWithString: file.ext.uppercased()); tag.font = .monospacedSystemFont(ofSize: 11, weight: .bold); tag.textColor = .secondaryLabelColor
        controls.addArrangedSubview(tag)
        if ["csv", "json", "xml", "md", "markdown"].contains(file.ext) {
            mode.setLabel(file.ext == "csv" ? "表格" : file.ext == "json" || file.ext == "xml" ? "树状" : "编辑", forSegment: 0)
            mode.setLabel(["md", "markdown"].contains(file.ext) ? "预览" : "源码", forSegment: 1)
            mode.target = self; mode.action = #selector(switchEditorMode); mode.selectedSegment = 0; controls.addArrangedSubview(mode)
        }
        if file.ext == "csv" {
            addButton("＋ 行", #selector(addRow)); addButton("＋ 列", #selector(addColumn)); addButton("删除行", #selector(removeRow)); addButton("删除列", #selector(removeColumn))
        } else if file.ext == "json" || file.ext == "xml" {
            addButton("＋ 节点", #selector(addNode)); addButton("删除节点", #selector(removeNode))
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); controls.addArrangedSubview(spacer)
        addButton("在 Finder 显示", #selector(reveal))
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for view in [controls!, body, status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor), controls.leadingAnchor.constraint(equalTo: root.leadingAnchor), controls.trailingAnchor.constraint(equalTo: root.trailingAnchor), controls.heightAnchor.constraint(equalToConstant: 50),
            body.topAnchor.constraint(equalTo: controls.bottomAnchor), body.leadingAnchor.constraint(equalTo: root.leadingAnchor), body.trailingAnchor.constraint(equalTo: root.trailingAnchor), body.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10), status.heightAnchor.constraint(equalToConstant: 16)
        ])
        if file.isImage { showImage() } else { rebuild() }
        if status.stringValue.isEmpty { setSaved() }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func addButton(_ title: String, _ action: Selector) { controls.addArrangedSubview(NSButton(title: title, target: self, action: action)) }
    private func mount(_ view: NSView) {
        body.subviews.forEach { $0.removeFromSuperview() }; view.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor), view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor)])
    }
    private func scroll(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = view; return scroll
    }
    private func showImage() {
        let imageView = NSImageView(); imageView.image = NSImage(contentsOf: file.url); imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        mount(imageView); status.stringValue = "图片预览 · 从挂载线拖动图片可发送到其他软件"
    }
    private func showSource() {
        loading = true; textView.isRichText = false; textView.allowsUndo = true; textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular); textView.textColor = .labelColor; textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 22, height: 20); textView.string = currentText; textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroller = scroll(textView); scroller.hasHorizontalScroller = false; mount(scroller); loading = false
    }
    private func rebuild() {
        table = nil; outline = nil
        if sourceMode { showSource(); return }
        do {
            switch file.ext {
            case "csv": rows = try CSVCodec.parse(currentText); showTable()
            case "json": json = try JSONNode.parse(currentText); showTree()
            case "xml":
                xml = try XMLDocument(xmlString: currentText, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]); xml?.characterEncoding = "UTF-8"; xmlRoot = XMLTreeNode(xml!); showTree()
            default: showSource()
            }
        } catch {
            sourceMode = true; mode.selectedSegment = 1; showSource(); status.stringValue = "格式有误，已打开源码：\(error.localizedDescription)"
        }
    }
    @objc private func switchEditorMode() {
        window?.makeFirstResponder(nil)
        if ["md", "markdown"].contains(file.ext) {
            if mode.selectedSegment == 1 { showMarkdown() } else { showSource() }; return
        }
        sourceMode = mode.selectedSegment == 1; rebuild()
    }
    func textDidChange(_ notification: Notification) {
        guard !loading else { return }; currentText = textView.string; changed()
    }
    private func changed() {
        dirty = true; window?.isDocumentEdited = true; status.stringValue = "正在保存…"; status.textColor = .secondaryLabelColor
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in _ = self?.flush() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    @discardableResult func flush() -> Bool {
        saveWork?.cancel(); guard dirty else { return true }
        do { try store.save(currentText, to: file.url); dirty = false; window?.isDocumentEdited = false; setSaved(); return true }
        catch { status.stringValue = "保存失败：\(error.localizedDescription)"; status.textColor = .systemRed; return false }
    }
    private func setSaved() {
        status.textColor = .secondaryLabelColor
        status.stringValue = "已自动保存 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) · UTF-8"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        guard flush() else { showError(AppError.message("文件尚未保存，窗口将保留。请检查存储目录和可用空间，然后重试。"), window: sender); return false }; return true
    }
    func windowWillClose(_ notification: Notification) { saveWork?.cancel(); onClose?() }
    func windowDidBecomeKey(_ notification: Notification) { onAccess?() }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }

    // CSV keeps every row as data; column letters avoid treating the first record as metadata.
    private func showTable() {
        let t = NSTableView(); t.delegate = self; t.dataSource = self; t.rowHeight = 29; t.usesAlternatingRowBackgroundColors = true; t.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]; t.allowsMultipleSelection = true
        let count = max(rows.map(\.count).max() ?? 1, 1)
        let index = NSTableColumn(identifier: .init("index")); index.title = "行"; index.width = 48; t.addTableColumn(index)
        for i in 0..<count { let c = NSTableColumn(identifier: .init(String(i))); c.title = columnName(i); c.width = 170; c.minWidth = 70; t.addTableColumn(c) }
        t.columnAutoresizingStyle = .noColumnAutoresizing; table = t; mount(scroll(t))
    }
    private func columnName(_ index: Int) -> String { var i = index + 1, s = ""; while i > 0 { i -= 1; s = String(UnicodeScalar(65 + i % 26)!) + s; i /= 26 }; return s }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if id == "index" { let label = NSTextField(labelWithString: String(row + 1)); label.textColor = .secondaryLabelColor; label.alignment = .center; return label }
        guard let col = Int(id) else { return nil }
        let field = NSTextField(string: col < rows[row].count ? rows[row][col] : ""); field.isBordered = false; field.backgroundColor = .clear; field.font = .monospacedSystemFont(ofSize: 13, weight: .regular); field.target = self; field.action = #selector(csvCellChanged(_:)); field.tag = row; field.identifier = .init(String(col)); field.delegate = self
        return field
    }
    @objc private func csvCellChanged(_ sender: NSTextField) {
        guard let col = Int(sender.identifier?.rawValue ?? ""), rows.indices.contains(sender.tag) else { return }
        while rows[sender.tag].count <= col { rows[sender.tag].append("") }; rows[sender.tag][col] = sender.stringValue
        currentText = CSVCodec.encode(rows); changed()
    }
    private func requireStructured() -> Bool { if sourceMode { NSSound.beep(); status.stringValue = "请先切换到表格或树状视图。"; return false }; window?.makeFirstResponder(nil); return true }
    @objc private func addRow() { guard requireStructured() else { return }; rows.append(Array(repeating: "", count: max(rows.map(\.count).max() ?? 1, 1))); csvUpdated() }
    @objc private func addColumn() { guard requireStructured() else { return }; let count = rows.map(\.count).max() ?? 1; for i in rows.indices { while rows[i].count < count { rows[i].append("") }; rows[i].append("") }; csvUpdated() }
    @objc private func removeRow() { guard requireStructured(), let t = table else { return }; for i in t.selectedRowIndexes.reversed() { rows.remove(at: i) }; if rows.isEmpty { rows = [[""]] }; csvUpdated() }
    @objc private func removeColumn() {
        guard requireStructured() else { return }
        let alert = NSAlert(); alert.messageText = "删除哪一列？"; alert.informativeText = "输入列字母，例如 A。该列所有行的数据都会删除。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.uppercased(); guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }), value.count <= 4 else { return }
        let col = value.utf8.reduce(0) { $0 * 26 + Int($1 - 64) } - 1
        for i in rows.indices where col < rows[i].count { rows[i].remove(at: col) }; csvUpdated()
    }
    private func csvUpdated() { currentText = CSVCodec.encode(rows); changed(); showTable() }

    private func showTree() {
        let tree = NSOutlineView(); tree.delegate = self; tree.dataSource = self; tree.rowHeight = 29; tree.usesAlternatingRowBackgroundColors = true
        for (id, title, width) in [("key", "字段 / 节点", 300.0), ("type", "类型", 115.0), ("value", "值（双击编辑）", 430.0)] {
            let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = width; tree.addTableColumn(col)
        }
        tree.outlineTableColumn = tree.tableColumns[0]; outline = tree; mount(scroll(tree)); tree.expandItem(nil, expandChildren: true)
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return 1 }; if let n = item as? JSONNode { return n.children.count }; return (item as? XMLTreeNode)?.children.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return file.ext == "json" ? json! as Any : xmlRoot! as Any }
        if let n = item as? JSONNode { return n.children[index] }; return (item as! XMLTreeNode).children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { if let n = item as? JSONNode { return !n.children.isEmpty }; return !(item as! XMLTreeNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let column = tableColumn!.identifier.rawValue
        if let n = item as? JSONNode {
            if column == "type" {
                let popup = NodeTypePopup(); popup.node = n; popup.addItems(withTitles: ["object", "array", "string", "number", "boolean", "null"]); popup.selectItem(withTitle: n.kind); popup.target = self; popup.action = #selector(typeChanged(_:)); popup.isBordered = false; return popup
            }
            let field = TreeField(); field.jsonNode = n; field.column = column; field.stringValue = column == "key" ? n.key : n.isContainer ? "\(n.children.count) 项" : n.value
            field.isEditable = column == "key" ? n.parent?.kind == "object" : !n.isContainer && n.kind != "null"; configureTreeField(field); return field
        }
        let n = item as! XMLTreeNode; let field = TreeField(); field.xmlNode = n; field.column = column
        field.stringValue = column == "key" ? n.label : column == "type" ? n.kind : n.value
        field.isEditable = column == "key" ? n.node.kind == .element || n.node.kind == .attribute : column == "value" && [.text, .attribute, .comment].contains(n.node.kind)
        configureTreeField(field); return field
    }
    private func configureTreeField(_ field: TreeField) { field.isBordered = false; field.backgroundColor = .clear; field.font = .monospacedSystemFont(ofSize: 13, weight: .regular); field.target = self; field.action = #selector(treeCellChanged(_:)); field.delegate = self }
    @objc private func treeCellChanged(_ field: TreeField) {
        if let n = field.jsonNode {
            let old = field.column == "key" ? n.key : n.value
            if field.column == "key" { n.key = field.stringValue } else { n.value = field.stringValue }
            do { currentText = try json!.encode(); changed() }
            catch { if field.column == "key" { n.key = old } else { n.value = old }; field.stringValue = old; showError(error, window: window) }
        } else if let n = field.xmlNode {
            let old = field.column == "key" ? n.node.name : n.node.stringValue
            if field.column == "key" { n.node.name = field.stringValue.hasPrefix("@") ? String(field.stringValue.dropFirst()) : field.stringValue } else { n.node.stringValue = field.stringValue }
            do { try updateXML() }
            catch { if field.column == "key" { n.node.name = old } else { n.node.stringValue = old }; field.stringValue = field.column == "key" ? n.label : n.value; showError(error, window: window) }
        }
    }
    @objc private func typeChanged(_ popup: NodeTypePopup) {
        guard let n = popup.node, let kind = popup.titleOfSelectedItem, n.kind != kind else { return }
        if !n.children.isEmpty || !n.value.isEmpty {
            let alert = NSAlert(); alert.messageText = "更改类型并清空当前值？"; alert.informativeText = "该节点现有的值和子节点会被替换。"; alert.addButton(withTitle: "更改"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { popup.selectItem(withTitle: n.kind); return }
        }
        n.kind = kind; n.children = []; n.value = kind == "number" ? "0" : kind == "boolean" ? "false" : ""; updateJSON()
    }
    private func updateJSON() { do { currentText = try json!.encode(); changed(); outline?.reloadData(); outline?.expandItem(nil, expandChildren: true) } catch { showError(error, window: window) } }
    private func updateXML() throws {
        guard let xml else { return }; let candidate = xml.xmlString
        _ = try XMLDocument(xmlString: candidate, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        currentText = candidate; changed()
    }
    @objc private func addNode() {
        guard requireStructured(), let tree = outline else { return }
        if file.ext == "json" {
            let selected = tree.item(atRow: tree.selectedRow) as? JSONNode ?? json!
            guard let parent = selected.isContainer ? selected : selected.parent else { status.stringValue = "先将根节点类型改为 object 或 array。"; return }
            var key = parent.kind == "array" ? String(parent.children.count) : "newField"; var i = 2
            while parent.children.contains(where: { $0.key == key }) { key = "newField\(i)"; i += 1 }
            let child = JSONNode(key: key, object: ""); child.parent = parent; parent.children.append(child); updateJSON()
        } else {
            let selected = tree.item(atRow: tree.selectedRow) as? XMLTreeNode
            guard let parent = (selected?.node as? XMLElement) ?? (selected?.node.parent as? XMLElement) ?? xml?.rootElement() else { return }
            let menu = NSMenu(); for (title, tag) in [("子元素", 0), ("属性", 1), ("文本", 2)] { let item = NSMenuItem(title: title, action: #selector(addXMLKind(_:)), keyEquivalent: ""); item.target = self; item.tag = tag; item.representedObject = parent; menu.addItem(item) }
            menu.popUp(positioning: nil, at: NSPoint(x: 260, y: controls.bounds.midY), in: controls)
        }
    }
    @objc private func addXMLKind(_ sender: NSMenuItem) {
        guard let parent = sender.representedObject as? XMLElement else { return }
        let newNode: XMLNode
        if sender.tag == 1 { var name = "attribute", i = 2; while parent.attribute(forName: name) != nil { name = "attribute\(i)"; i += 1 }; newNode = XMLNode.attribute(withName: name, stringValue: "") as! XMLNode; parent.addAttribute(newNode) }
        else { newNode = sender.tag == 0 ? XMLElement(name: "element", stringValue: "") : XMLNode.text(withStringValue: "文本") as! XMLNode; parent.addChild(newNode) }
        do { try updateXML(); xmlRoot = XMLTreeNode(xml!); showTree() } catch { newNode.detach(); showError(error, window: window) }
    }
    @objc private func removeNode() {
        guard requireStructured(), let tree = outline else { return }
        if let n = tree.item(atRow: tree.selectedRow) as? JSONNode, let parent = n.parent {
            parent.children.removeAll { $0 === n }; if parent.kind == "array" { for (i, child) in parent.children.enumerated() { child.key = String(i) } }; updateJSON()
        } else if let n = tree.item(atRow: tree.selectedRow) as? XMLTreeNode, n.node !== xml, n.node !== xml?.rootElement() {
            n.node.detach(); do { try updateXML(); xmlRoot = XMLTreeNode(xml!); showTree() } catch { showError(error, window: window) }
        }
    }
    private func showMarkdown() {
        let preview = NSTextView(); preview.isEditable = false; preview.textContainerInset = NSSize(width: 30, height: 24); preview.autoresizingMask = [.width]; preview.isVerticallyResizable = true
        let result = NSMutableAttributedString(); var inCode = false
        for line in currentText.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            let heading = !inCode && (1...6).contains(hashes) && line.dropFirst(hashes).hasPrefix(" ")
            var content = heading ? String(line.dropFirst(hashes + 1)) : line
            if !inCode && (content.hasPrefix("- ") || content.hasPrefix("* ")) { content = "• " + content.dropFirst(2) }
            let font: NSFont = inCode ? .monospacedSystemFont(ofSize: 13, weight: .regular) : heading ? .systemFont(ofSize: CGFloat(30 - hashes * 3), weight: .bold) : .systemFont(ofSize: 15)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.paragraphSpacing = heading ? 10 : 4
            let part = NSMutableAttributedString(string: content + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            if inCode { part.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: NSRange(location: 0, length: part.length)) }
            else {
                for (pattern, attribute, value) in [("\\*\\*(.+?)\\*\\*", NSAttributedString.Key.font, NSFont.boldSystemFont(ofSize: 15) as Any), ("`([^`]+)`", .font, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) as Any)] {
                    if let regex = try? NSRegularExpression(pattern: pattern) { for match in regex.matches(in: part.string, range: NSRange(location: 0, length: part.length)).reversed() { let inner = (part.string as NSString).substring(with: match.range(at: 1)); part.replaceCharacters(in: match.range, with: NSAttributedString(string: inner, attributes: [attribute: value, .foregroundColor: NSColor.labelColor])) } }
                }
            }
            result.append(part)
        }
        preview.textStorage?.setAttributedString(result); mount(scroll(preview)); status.stringValue = "Markdown 基础预览 · 标题、列表、粗体、代码 · 编辑内容自动保存"
    }
}

extension EditorController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Persist table edits while typing, without reloading the active cell.
        if let field = obj.object as? NSTextField, !(field is TreeField), Int(field.identifier?.rawValue ?? "") != nil { csvCellChanged(field) }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? TreeField { treeCellChanged(field) }
        else if let field = obj.object as? NSTextField { csvCellChanged(field) }
    }
}

final class TreeField: NSTextField { weak var jsonNode: JSONNode?; weak var xmlNode: XMLTreeNode?; var column = "" }
final class NodeTypePopup: NSPopUpButton { weak var node: JSONNode? }
final class EditorBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}
