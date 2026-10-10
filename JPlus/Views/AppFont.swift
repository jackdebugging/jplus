import AppKit
import SwiftUI

/// Settings › Font: the typeface for the main window's text. The three
/// bundled families live in `Fonts/`; `registerBundledFonts()` makes them
/// known to CoreText for this process, so no Info.plist entry is needed.
enum AppFont: String, CaseIterable, Identifiable {
    case system
    case inter
    case atkinson
    case plex

    static let storageKey = "fontFamily"
    /// What a fresh install uses.
    static let standard: AppFont = .inter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .inter: "Inter"
        case .atkinson: "Atkinson Hyperlegible"
        case .plex: "IBM Plex Sans"
        }
    }

    /// One line for the Settings footer.
    var detail: String {
        switch self {
        case .system: "San Francisco, the macOS font."
        case .inter: "The screen font Linear, Figma and GitHub use."
        case .atkinson: "Made for legibility, with letters that are hard to confuse."
        case .plex: "IBM's humanist sans, easy on the eyes for long reading."
        }
    }

    /// CoreText family name; nil means the system font.
    var familyName: String? {
        switch self {
        case .system: nil
        case .inter: "Inter"
        case .atkinson: "Atkinson Hyperlegible Next"
        case .plex: "IBM Plex Sans"
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
        return Font(nsFont)
    }
}

extension EnvironmentValues {
    /// Settings › Font for the main window.
    @Entry var appFont: AppFont = .system
}

private extension Font.Weight {
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
