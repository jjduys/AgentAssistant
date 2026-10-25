import AppKit
import CoreFoundation

let supportedExtensions: Set<String> = ["md", "markdown", "json", "xml", "txt", "csv", "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp"]
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp"]

struct MountedFile {
    let url: URL
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var isImage: Bool { imageExtensions.contains(ext) }
    var modified: Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
}

final class FileStore {
    let directory: URL
    var onChange: (() -> Void)?
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TCenter/Files", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func files() -> [MountedFile] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: .skipsHiddenFiles)) ?? [])
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { MountedFile(url: $0) }.sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified }
    }
    func uniqueURL(_ name: String) -> URL {
        let clean = URL(fileURLWithPath: name).lastPathComponent
        var url = directory.appendingPathComponent(clean)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return url
    }
    @discardableResult func importFile(_ source: URL) throws -> URL {
        guard supportedExtensions.contains(source.pathExtension.lowercased()), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw AppError.message("不支持这个文件：\(source.lastPathComponent)") }
        let target = uniqueURL(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        onChange?(); return target
    }
    @discardableResult func create(name: String, data: Data) throws -> URL {
        let url = uniqueURL(name); try data.write(to: url, options: .atomic); onChange?(); return url
    }
    func save(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic); onChange?() }
    func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil); onChange?() }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

enum CSVCodec {
    static func parse(_ text: String) throws -> [[String]] {
        if text.isEmpty { return [[""]] }
        let chars = Array(text); var rows: [[String]] = [], row: [String] = [], field = "", i = 0
        var quoted = false, closed = false, lastWasBreak = false
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
                lastWasBreak = false
            } else if c == "," {
                row.append(field); field = ""; closed = false; lastWasBreak = false
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false; lastWasBreak = true
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true; lastWasBreak = false }
            else {
                if closed || c == "\"" { throw AppError.message("CSV 引号格式不正确，请在源码视图修正。") }
                field.append(c); lastWasBreak = false
            }
            i += 1
        }
        if quoted { throw AppError.message("CSV 包含未闭合的引号。") }
        if !lastWasBreak { row.append(field); rows.append(row) }
        return rows.isEmpty ? [[""]] : rows
    }
    static func encode(_ rows: [[String]]) -> String {
        rows.map { $0.map { value in
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }.joined(separator: ",") }.joined(separator: "\n")
    }
}

final class JSONNode: NSObject {
    var key: String
    var kind: String
    var value: String
    var children: [JSONNode]
    weak var parent: JSONNode?
    init(key: String, object: Any) {
        self.key = key; value = ""; children = []; kind = "null"
        super.init()
        if let dict = object as? [String: Any] {
            kind = "object"; children = dict.keys.sorted().map { JSONNode(key: $0, object: dict[$0]!) }
        } else if let array = object as? [Any] {
            kind = "array"; children = array.enumerated().map { JSONNode(key: String($0.offset), object: $0.element) }
        } else if let string = object as? String { kind = "string"; value = string }
        else if let number = object as? NSNumber {
            kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"; value = kind == "boolean" ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        children.forEach { $0.parent = self }
    }
    var isContainer: Bool { kind == "object" || kind == "array" }
    func object() throws -> Any {
        switch kind {
        case "object":
            var result: [String: Any] = [:]
            for child in children {
                guard result[child.key] == nil else { throw AppError.message("JSON 字段名重复：\(child.key)") }
                result[child.key] = try child.object()
            }; return result
        case "array": return try children.map { try $0.object() }
        case "string": return value
        case "number":
            guard let number = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw AppError.message("请输入合法 JSON 数字。") }; return number
        case "boolean": guard value == "true" || value == "false" else { throw AppError.message("布尔值只能为 true 或 false。") }; return value == "true"
        default: return NSNull()
        }
    }
    static func parse(_ text: String) throws -> JSONNode { JSONNode(key: "根节点", object: try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) }
    func encode() throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object(), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self) }
}

final class XMLTreeNode: NSObject {
    let node: XMLNode
    var children: [XMLTreeNode] = []
    init(_ node: XMLNode) {
        self.node = node; super.init()
        if let element = node as? XMLElement { children += (element.attributes ?? []).map(XMLTreeNode.init) }
        children += (node.children ?? []).map(XMLTreeNode.init)
    }
    var label: String {
        switch node.kind {
        case .document: return "文档"
        case .attribute: return "@" + (node.name ?? "")
        case .text: return "#text"
        case .comment: return "#comment"
        default: return node.name ?? "节点"
        }
    }
    var kind: String {
        switch node.kind { case .document: return "document"; case .element: return "element"; case .attribute: return "attribute"; case .text: return "text"; case .comment: return "comment"; default: return "other" }
    }
    var value: String { node.kind == .element || node.kind == .document ? "" : node.stringValue ?? "" }
}

func readText(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
    throw AppError.message("文件不是 UTF-8 或带 BOM 的 UTF-16 文本。请转换编码后导入。")
}

func showError(_ error: Error, window: NSWindow? = nil) {
    let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
