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

        // Rounded tile in the board's square colour.
        let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
        tile.addClip()
        NSColor(red: 0.94, green: 0.90, blue: 0.81, alpha: 1).setFill()
        rect.fill()

        // Warm off-white token disc, like a red piece on the board.
        let inset = size * 0.13
        let disc = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
        NSColor(red: 1.00, green: 0.97, blue: 0.96, alpha: 1).setFill()
        disc.fill()
        NSColor(red: 0.35, green: 0.22, blue: 0.08, alpha: 0.22).setStroke()
        disc.lineWidth = size * 0.012
        disc.stroke()

        // The new King symbol, centred.
        let k = size * 0.46
        king.draw(in: NSRect(x: (size - k) / 2, y: (size - k) / 2, width: k, height: k),
                  from: .zero, operation: .sourceOver, fraction: 1)

        return image
    }

    /// The new king symbol (king.svg), tinted the deep carmine of the red pieces.
    private static func loadKing() -> NSImage? {
        func tinted(_ url: URL) -> NSImage? {
            guard let raw = NSImage(contentsOf: url) else { return nil }
            let size = raw.size
            return NSImage(size: size, flipped: false) { rect in
                raw.draw(in: rect)
                NSColor(red: 0.75, green: 0.11, blue: 0.09, alpha: 1).set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        if let url = Bundle.module.url(forResource: "king", withExtension: "svg"),
           let img = tinted(url) { return img }
        if let resURL = Bundle.main.resourceURL {
            let url = resURL
                .appendingPathComponent("Drott_Drott.bundle")
                .appendingPathComponent("king.svg")
            if let img = tinted(url) { return img }
        }
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
