import AppKit

enum DashStyle: String, CaseIterable {
    case solid
    case dashed
    case dotted

    var title: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        }
    }
}

/// Appearance of a line. Every line keeps its own style, so changing the
/// settings only affects lines drawn afterwards and colours can be mixed.
struct LineStyle: Equatable {
    var color: NSColor
    /// Width in points. 0.5 is "hairline": clamped to one device pixel at draw
    /// time so it stays crisp on both Retina and 1× displays.
    var width: CGFloat
    var dash: DashStyle

    static let `default` = LineStyle(color: presetColors[0].color, width: 1, dash: .solid)

    static let presetColors: [(name: String, color: NSColor)] = [
        ("Red", rgb(0xFF0000)),
        ("Orange", rgb(0xFF8000)),
        ("Yellow", rgb(0xFFD500)),
        ("Green", rgb(0x00C853)),
        ("Cyan", rgb(0x00B8D9)),
        ("Blue", rgb(0x2979FF)),
        ("Magenta", rgb(0xFF00FF)),
        ("White", rgb(0xFFFFFF)),
        ("Black", rgb(0x000000)),
    ]

    static let widths: [CGFloat] = [0.5, 1, 1.5, 2, 3, 4]

    static func title(forWidth width: CGFloat) -> String {
        if width == 0.5 { return "½ pt  (hairline)" }
        if width == width.rounded() { return "\(Int(width)) pt" }
        return "\(width) pt"
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        let tolerance: CGFloat = 1.0 / 255
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
            && abs(a.alphaComponent - b.alphaComponent) < tolerance
    }
}

/// The style used for the next line, persisted in UserDefaults.
final class LineSettings {
    static let shared = LineSettings()
    static let didChange = Notification.Name("LineSettings.didChange")

    private enum Keys {
        static let color = "lineColor"
        static let width = "lineWidth"
        static let dash = "lineDash"
    }

    var style: LineStyle {
        didSet {
            guard style != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private init() {
        style = Self.load()
    }

    private static func load() -> LineStyle {
        let defaults = UserDefaults.standard
        var style = LineStyle.default
        if let rgba = defaults.array(forKey: Keys.color) as? [Double], rgba.count == 4 {
            style.color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        if let width = defaults.object(forKey: Keys.width) as? Double, width > 0 {
            style.width = width
        }
        if let dash = defaults.string(forKey: Keys.dash).flatMap(DashStyle.init(rawValue:)) {
            style.dash = dash
        }
        return style
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let color = style.color.usingColorSpace(.sRGB) {
            let rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            defaults.set(rgba.map(Double.init), forKey: Keys.color)
        }
        defaults.set(Double(style.width), forKey: Keys.width)
        defaults.set(style.dash.rawValue, forKey: Keys.dash)
    }
}
