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
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TCenter-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = try FileStore(directory: temporary)
    let a = try store.create(name: "a.txt", data: Data("one".utf8)); let b = try store.create(name: "a.txt", data: Data("two".utf8))
    try check(a != b && store.files().count == 2, "Unique file names")
    try store.save("updated", to: a); try check(readText(a) == "updated", "Atomic text persistence")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: b.path)
    try check(store.files().last?.url.standardizedFileURL.path == a.standardizedFileURL.path, "Old-to-new sort")
    let copy = try store.importFile(a); try check(readText(copy) == "updated" && copy != a, "Import copies original")
    print("PASS: CSV quoting, multiline, CRLF, invalid syntax; JSON scalar/container roundtrip; XML attributes/escaping; unique names, atomic save, sorting, import copy")
}
