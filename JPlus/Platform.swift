import SwiftUI
#if os(macOS)
import AppKit

typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
#else
import UIKit

typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
#endif

/// The few places AppKit and UIKit differ, behind one name each, so views
/// don't need `#if os(macOS)` for everyday things.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #else
        UIPasteboard.general.image = image
        #endif
    }
}

extension PlatformImage {
    /// The decoded image from a file, or nil if it isn't one.
    static func decoded(contentsOf url: URL) -> PlatformImage? {
        #if os(macOS)
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
        #else
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)), image.cgImage != nil else { return nil }
        return image
        #endif
    }

    /// The decoded image from bytes, or nil if they aren't one.
    static func decoded(from data: Data) -> PlatformImage? {
        #if os(macOS)
        guard let image = NSImage(data: data), image.isValid else { return nil }
        return image
        #else
        guard let image = UIImage(data: data), image.cgImage != nil else { return nil }
        return image
        #endif
    }

    var cgImageValue: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// The background of an editable text area.
    static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// The window's own background, for panels floating over content.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The background of a control such as a search field.
    static var controlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// The system's link color.
    static var link: Color {
        #if os(macOS)
        Color(nsColor: .linkColor)
        #else
        Color(uiColor: .link)
        #endif
    }
}

extension View {
    /// A checkbox on the Mac; a switch elsewhere.
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// A link-styled button on the Mac; a borderless one elsewhere.
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// The window subtitle on the Mac; dropped where the title bar has none.
    func navigationSubtitleIfAvailable(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        self
        #endif
    }

    /// A trailing inspector column where there's room; on an iPhone, a
    /// half-height sheet instead, since `.inspector` there hides the
    /// navigation bar's title and buttons.
    func adaptiveInspector<Inspector: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Inspector) -> some View {
        modifier(AdaptiveInspector(isPresented: isPresented, inspector: content))
    }

    /// Esc: the Mac's exit command; a hardware keyboard's Escape key on iOS.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }

    /// The pointing-hand cursor over a clickable thing, on the Mac.
    func linkPointer() -> some View {
        #if os(macOS)
        pointerStyle(.link)
        #else
        self
        #endif
    }
}

private struct AdaptiveInspector<Inspector: View>: ViewModifier {
    @Binding var isPresented: Bool
    let inspector: () -> Inspector
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            content.sheet(isPresented: $isPresented) {
                inspector()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        } else {
            content.inspector(isPresented: $isPresented, content: inspector)
        }
        #else
        content.inspector(isPresented: $isPresented, content: inspector)
        #endif
    }
}

/// Opens Settings: its own window on the Mac, a sheet on iOS. Call it like
/// `openSettings()`.
struct OpenAppSettingsAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var openAppSettings = OpenAppSettingsAction {}
}

extension View {
    /// Provides `openAppSettings` to everything inside; on iOS, also hosts
    /// the Settings sheet. Apply after the environment Settings needs.
    func appSettings() -> some View { modifier(AppSettingsHost()) }
}

private struct AppSettingsHost: ViewModifier {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.environment(\.openAppSettings, OpenAppSettingsAction { openSettings() })
    }
    #else
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .environment(\.openAppSettings, OpenAppSettingsAction { isPresented = true })
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented = false }
                            }
                        }
                }
            }
    }
    #endif
}

enum Device {
    /// "this Mac", "this iPhone" or "this iPad", for messages about what's
    /// stored locally.
    static var this: String {
        #if os(macOS)
        "this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }
}

/// Opens a web page in the default browser.
@MainActor
func openInBrowser(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
