import AppKit
import SwiftUI

/// Settings › Font: the typeface for the main window's text. Inter lives in
/// `Fonts/`; `registerBundledFonts()` makes it known to CoreText for this
/// process, so no Info.plist entry is needed.
enum AppFont: String, CaseIterable, Identifiable {
    case system
    case inter

    static let storageKey = "fontFamily"
    /// What a fresh install uses.
    static let standard: AppFont = .inter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .inter: "Inter"
        }
    }

    /// One line for the Settings footer.
    var detail: String {
        switch self {
        case .system: "San Francisco, the macOS font."
        case .inter: "The screen font Linear, Figma and GitHub use."
        }
    }

    /// CoreText family name; nil means the system font.
    var familyName: String? {
        switch self {
        case .system: nil
        case .inter: "Inter"
        }
    }

    /// Call once at launch, before any view draws.
    static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil), !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
            if done, CFArrayGetCount(errors) > 0 {
                print("JPlus: some bundled fonts failed to register:", errors)
            }
            return true
        }
    }

    /// The family at `size` with `weight`, italic if asked; nil for the system
    /// font or if the family isn't available.
    func font(size: CGFloat, weight: Font.Weight, italic: Bool) -> Font? {
        nsFont(size: size, weight: weight, italic: italic).map(Font.init)
    }

    /// `font(size:weight:italic:)` as AppKit sees it, for measuring text.
    func nsFont(size: CGFloat, weight: Font.Weight, italic: Bool) -> NSFont? {
        guard let familyName else { return nil }
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if italic { symbolic.insert(.italic) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [
                NSFontDescriptor.TraitKey.weight: weight.nsWeight.rawValue,
                NSFontDescriptor.TraitKey.symbolic: symbolic.rawValue,
            ],
        ])
        guard let nsFont = NSFont(descriptor: descriptor, size: size),
              nsFont.familyName == familyName else { return nil }
        return nsFont
    }
}

extension EnvironmentValues {
    /// Settings › Font for the main window.
    @Entry var appFont: AppFont = .system
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
