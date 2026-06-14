import AppKit

// MARK: - App icon / logo
//
// A Drott logo built from the red King piece on a board-themed rounded tile.
// Used as the Dock icon at runtime; `DROTT_MAKEICON=1 swift run` writes a PNG
// asset to the working directory.

enum AppIcon {

    /// Render the logo at the given pixel size.
    static func makeImage(size: CGFloat = 512) -> NSImage? {
        guard let king = loadKing() else { return nil }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        // Rounded tile with the dark→wood gradient of the board.
        let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
        tile.addClip()
        let gradient = NSGradient(colors: [
            NSColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1),
            NSColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1),
        ])
        gradient?.draw(in: rect, angle: -90)

        // Pale beige disc behind the king (echoes the piece tokens on the board).
        let inset = size * 0.13
        let disc = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
        NSColor(red: 0.94, green: 0.90, blue: 0.81, alpha: 1).setFill()
        disc.fill()
        NSColor(red: 0.35, green: 0.22, blue: 0.08, alpha: 0.25).setStroke()
        disc.lineWidth = size * 0.012
        disc.stroke()

        // The King, centred.
        let k = size * 0.58
        king.draw(in: NSRect(x: (size - k) / 2, y: (size - k) / 2, width: k, height: k),
                  from: .zero, operation: .sourceOver, fraction: 1)

        return image
    }

    private static func loadKing() -> NSImage? {
        if let resURL = Bundle.main.resourceURL {
            let url = resURL
                .appendingPathComponent("Drott_Drott.bundle")
                .appendingPathComponent("red_king.png")
            if let img = NSImage(contentsOf: url) { return img }
        }
        if let url = Bundle.module.url(forResource: "red_king", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return nil
    }

    /// Apply the logo as the running app's Dock icon.
    static func applyToDock() {
        if let icon = makeImage(size: 512) { NSApp.applicationIconImage = icon }
    }

    /// `DROTT_MAKEICON=1 swift run` → writes AppIcon.png (1024²) and exits.
    static func exportIfRequested() {
        guard ProcessInfo.processInfo.environment["DROTT_MAKEICON"] == "1" else { return }
        guard let img = makeImage(size: 1024),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("icon export failed\n".utf8))
            exit(1)
        }
        let path = ProcessInfo.processInfo.environment["DROTT_ICON_OUT"] ?? "AppIcon.png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
