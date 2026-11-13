import AppKit
import ArtelCore
import Observation
import SwiftUI

/// Current font settings, readable from views and AppKit code without the app model.
/// `AppModel` keeps it in sync with `state.settings.fonts`.
@MainActor
@Observable
final class AppFonts {
    static let shared = AppFonts()
    var settings = FontSettings()
}

extension FontChoice {
    /// The font, falling back to the system (monospaced) font if the family is missing.
    func nsFont(monospaced: Bool, weight: NSFont.Weight = .regular) -> NSFont {
        let size = CGFloat(size)
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            guard weight != .regular else { return font }
            return NSFontManager.shared.convert(font, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        }
        return monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    func font(monospaced: Bool) -> Font {
        if let family { return .custom(family, fixedSize: CGFloat(size)) }
        return .system(size: CGFloat(size), design: monospaced ? .monospaced : .default)
    }
}

enum FontFamilies {
    /// All installed families, alphabetically.
    @MainActor static let all: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// Families with fixed-pitch faces (for terminals and code).
    @MainActor static let monospaced: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
}
