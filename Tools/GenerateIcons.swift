import AppKit

@main struct GenerateIcons {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let bitmap = BrandIcon.appIcon(size: size * scale)
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try BrandIcon.appIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: folder.deletingLastPathComponent().appendingPathComponent("AppIcon.png"))
        let status = BrandIcon.statusIcon()
        try NSBitmapImageRep(data: status.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: folder.deletingLastPathComponent().appendingPathComponent("MenuBarIcon.png"))
    }
}
