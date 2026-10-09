import SwiftUI

/// Settings › Text Size: ten steps around macOS's standard 13-point text.
/// macOS ignores Dynamic Type, so the app sizes its own text: the main
/// window's default font follows the step, and views use
/// `.scaledFont(.callout)` where they would use `.font(.callout)`.
enum TextSize {
    static let storageKey = "textSize"
    /// Body text point size at each step of the slider.
    static let bodyPointSizes: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22]
    /// 13 pt, the size macOS uses everywhere.
    static let standardStep = 3

    static func clamped(_ step: Int) -> Int {
        min(max(step, 0), bodyPointSizes.count - 1)
    }

    static func pointSize(forStep step: Int) -> CGFloat {
        bodyPointSizes[clamped(step)]
    }

    /// How much bigger than standard; 1 at the standard step.
    static func scale(forStep step: Int) -> CGFloat {
        pointSize(forStep: step) / bodyPointSizes[standardStep]
    }

    /// Push buttons, pop-up menus and segmented controls ignore the font, so
    /// their control size steps with the text instead.
    fileprivate static func controlSize(forStep step: Int) -> ControlSize {
        switch pointSize(forStep: step) {
        case ..<12: .small
        case ..<18: .regular
        default: .large
        }
    }

    /// Sidebar rows have three sizes of their own; nil keeps the one set in
    /// System Settings › Appearance.
    fileprivate static func sidebarRowSize(forStep step: Int) -> SidebarRowSize? {
        switch pointSize(forStep: step) {
        case ..<13: .small
        case ..<15: nil
        default: .large
        }
    }
}

extension EnvironmentValues {
    /// Text Size as a multiple of the standard size.
    @Entry var textSizeScale: CGFloat = 1
}

extension View {
    /// Sizes a window's text by the Text Size step.
    func textSize(step: Int) -> some View {
        modifier(TextSizeModifier(step: step))
    }

    /// `.font(_:)` that follows Settings › Text Size.
    func scaledFont(_ font: ScaledFont) -> some View {
        modifier(ScaledFontModifier(font: font))
    }
}

private struct TextSizeModifier: ViewModifier {
    let step: Int

    func body(content: Content) -> some View {
        let scale = TextSize.scale(forStep: step)
        content
            .environment(\.textSizeScale, scale)
            // At the standard size, leave fonts and sizes to AppKit's defaults.
            .transformEnvironment(\.font) { font in
                if scale != 1 { font = ScaledFont.body.font(scale: scale) }
            }
            .transformEnvironment(\.controlSize) { size in
                if scale != 1 { size = TextSize.controlSize(forStep: step) }
            }
            .transformEnvironment(\.sidebarRowSize) { size in
                if let rowSize = TextSize.sidebarRowSize(forStep: step) { size = rowSize }
            }
    }
}

private struct ScaledFontModifier: ViewModifier {
    let font: ScaledFont
    @Environment(\.textSizeScale) private var scale

    func body(content: Content) -> some View {
        content.font(font.font(scale: scale))
    }
}

/// A system font that grows and shrinks with Text Size. It mirrors the parts
/// of `Font` the app uses, so `.font(.caption.weight(.semibold))` becomes
/// `.scaledFont(.caption.weight(.semibold))`.
struct ScaledFont {
    private enum Base {
        case style(Font.TextStyle)
        case size(CGFloat)
    }

    private var base: Base
    private var weight: Font.Weight?
    private var design: Font.Design?
    private var isItalic = false

    private init(_ base: Base, weight: Font.Weight? = nil, design: Font.Design? = nil) {
        self.base = base
        self.weight = weight
        self.design = design
    }

    static let largeTitle = ScaledFont(.style(.largeTitle))
    static let title = ScaledFont(.style(.title))
    static let title2 = ScaledFont(.style(.title2))
    static let title3 = ScaledFont(.style(.title3))
    static let headline = ScaledFont(.style(.headline))
    static let subheadline = ScaledFont(.style(.subheadline))
    static let body = ScaledFont(.style(.body))
    static let callout = ScaledFont(.style(.callout))
    static let footnote = ScaledFont(.style(.footnote))
    static let caption = ScaledFont(.style(.caption))
    static let caption2 = ScaledFont(.style(.caption2))

    /// `size` is the point size at the standard step.
    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> ScaledFont {
        ScaledFont(.size(size), weight: weight, design: design)
    }

    func weight(_ weight: Font.Weight) -> ScaledFont {
        var font = self
        font.weight = weight
        return font
    }

    func bold() -> ScaledFont { weight(.bold) }

    func monospaced() -> ScaledFont {
        var font = self
        font.design = .monospaced
        return font
    }

    func italic() -> ScaledFont {
        var font = self
        font.isItalic = true
        return font
    }

    /// The font at `scale` times its standard size.
    func font(scale: CGFloat) -> Font {
        let font: Font = switch base {
        case .style(let style) where scale == 1:
            // Exactly the text style, so the standard step looks as it always has.
            .system(style, design: design, weight: weight)
        case .style(let style):
            .system(size: style.macPointSize * scale, weight: weight ?? style.macWeight, design: design)
        case .size(let size):
            .system(size: size * scale, weight: weight, design: design)
        }
        return isItalic ? font.italic() : font
    }
}

private extension Font.TextStyle {
    /// Text styles have fixed sizes on macOS.
    var macPointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    var macWeight: Font.Weight {
        switch self {
        case .headline: .bold
        case .caption2: .medium
        default: .regular
        }
    }
}

/// `ContentUnavailableView` with a title and description that follow Text
/// Size; the system view keeps fixed fonts. Takes the same arguments.
struct ScaledContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            // The system view's own fonts, scaled.
            label.scaledFont(.largeTitle.bold())
        } description: {
            description.scaledFont(.body)
        } actions: {
            actions
        }
    }
}

extension ScaledContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init {
            SwiftUI.Label(title, systemImage: systemImage)
        } description: {
            description
        }
    }
}

/// A list section header that follows Text Size; List draws a plain title
/// at a fixed size.
struct ScaledSectionHeader: View {
    let title: Text
    @Environment(\.textSizeScale) private var scale

    var body: some View {
        if scale == 1 {
            // List's own header font, untouched.
            title
        } else {
            title.font(ScaledFont.subheadline.bold().font(scale: scale))
        }
    }
}
