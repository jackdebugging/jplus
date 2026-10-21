import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        @Bindable var session = session
        content
            .sheet(isPresented: $session.isSwitchingAccount) {
                AccountPickerView(onCancel: { session.isSwitchingAccount = false })
                    .environment(session)
                    #if os(macOS)
                    .frame(minWidth: 620, minHeight: 520)
                    #endif
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .restoring:
            // Only lasts while saved accounts are read from the Keychain.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            AccountPickerView()
        case .signedIn(let user):
            if let accountID = session.currentAccountID {
                HomeView(user: user)
                    .id(accountID)
                    .defaultAppStorage(AccountDefaults.store(for: accountID))
                    .demoLinkNotice()
            }
        }
    }
}

extension View {
    /// In the App Review demo, links to the demo site (Open in Jira, Open in
    /// Confluence, a version's page) explain that it has no web pages instead
    /// of opening a browser on a site that doesn't exist.
    func demoLinkNotice() -> some View { modifier(DemoLinkNotice()) }
}

private struct DemoLinkNotice: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard DemoSite.isDemo(url) else { return .systemAction }
                isShowing = true
                return .handled
            })
            .alert("Sample Data", isPresented: $isShowing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is JPlus's built-in demo, so there's no web page to open. With a real Jira site, this opens the page in your browser.")
            }
    }
}
