import CoreGraphics

/// The modifier key combination that switches the overlay into drawing mode.
enum DrawModifier: String, CaseIterable {
    case shift
    case option
    case controlShift
    case optionShift

    static let `default`: DrawModifier = .shift

    var title: String {
        switch self {
        case .shift: "Shift  (⇧)"
        case .option: "Option  (⌥)"
        case .controlShift: "Control + Shift  (⌃⇧)"
        case .optionShift: "Option + Shift  (⌥⇧)"
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .controlShift: "⌃⇧"
        case .optionShift: "⌥⇧"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .shift: [.maskShift]
        case .option: [.maskAlternate]
        case .controlShift: [.maskControl, .maskShift]
        case .optionShift: [.maskAlternate, .maskShift]
        }
    }
}
