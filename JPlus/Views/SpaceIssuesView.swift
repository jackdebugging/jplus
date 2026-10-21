import SwiftUI

/// Open issues in one Jira space (project), most recently updated first.
struct SpaceIssuesView: View {
    let project: JiraProject
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var query = IssueQuery()

    private var jql: String {
        "project = \"\(project.key)\" AND resolution = Unresolved ORDER BY updated DESC"
    }

    var body: some View {
        content
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await run() } }
                        .keyboardShortcut("r", modifiers: .command)
                    if let client = session.client {
                        Button("Open in Jira", systemImage: "safari") {
                            openURL(client.browseURL(jql: jql))
                        }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Open these issues in Jira (⇧⌘O)")
                    }
                }
            }
            .loadTask { if !query.hasRun { await run() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = query.errorMessage {
            ScaledContentUnavailableView {
                Label("Couldn't Load \(project.name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await run() } }
            }
        } else if (query.isLoading || !query.hasRun) && query.issues.isEmpty {
            ProgressView("Loading \(project.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.hasRun && query.issues.isEmpty {
            ScaledContentUnavailableView("No Open Issues", systemImage: "checkmark.circle",
                                         description: Text("\(project.name) has no unresolved issues."))
        } else {
            VStack(spacing: 0) {
                IssueListView(issues: query.issues, onOpen: onOpenIssue)
                Divider()
                IssueListFooter(query: query) {
                    Task { if let client = session.client { await query.loadMore(using: client) } }
                }
            }
        }
    }

    private func run() async {
        guard let client = session.client else { return }
        await query.run(jql, using: client)
    }
}
