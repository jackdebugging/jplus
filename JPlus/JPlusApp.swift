import SwiftUI

@main
struct JPlusApp: App {
    @State private var session = SessionStore()
    @State private var settings = SettingsStore()
    @AppStorage(TextSize.storageKey) private var textSizeStep = TextSize.standardStep
    @AppStorage(AppFont.storageKey) private var appFont = AppFont.standard

    init() {
        AppFont.registerBundledFonts()
        TextSize.installEqualsShortcut()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(settings)
                .textSize(step: textSizeStep, font: appFont)
                .task { await settings.load() }
                .task { await session.restore() }
                .frame(minWidth: 480, minHeight: 360)
                .background(WindowFrameAutosave(name: "JPlusMainWindow"))
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Ticket…") {
                    NotificationCenter.default.post(name: .jplusNewTicket, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!session.isSignedIn)
            }
            CommandMenu("Go") {
                Button("Search") {
                    NotificationCenter.default.post(name: .jplusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!session.isSignedIn)
                Button("Go to Issue or Version…") {
                    NotificationCenter.default.post(name: .jplusCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!session.isSignedIn)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Make Text Bigger") { textSizeStep = TextSize.clamped(textSizeStep + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(textSizeStep >= TextSize.largestStep)
                Button("Make Text Smaller") { textSizeStep = TextSize.clamped(textSizeStep - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(textSizeStep <= 0)
                Button("Make Text Standard Size") { textSizeStep = TextSize.standardStep }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(textSizeStep == TextSize.standardStep)
            }
            CommandGroup(after: .appSettings) {
                Button("Switch Account…") { session.signOut() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!session.isSignedIn)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(session)
        }
    }
}
