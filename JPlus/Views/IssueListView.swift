import AppKit
import SwiftUI

/// Sendable column sort for issue tables (Swift 6–safe alternative to `KeyPathComparator` in `@State`).
struct IssueSummarySortComparator: SortComparator, Hashable, Sendable {
    enum Column: Hashable, Sendable {
        case issueType, key, summary, status, assignee, updated
    }

    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: IssueSummary, _ rhs: IssueSummary) -> ComparisonResult {
        switch column {
        case .issueType:
            lhs.fields.issueType.name.localizedStandardCompare(rhs.fields.issueType.name)
        case .key:
            lhs.key.localizedStandardCompare(rhs.key)
        case .summary:
            lhs.fields.summary.localizedStandardCompare(rhs.fields.summary)
        case .status:
            lhs.fields.status.name.localizedStandardCompare(rhs.fields.status.name)
        case .assignee:
            (lhs.fields.assignee?.displayName ?? "").localizedStandardCompare(rhs.fields.assignee?.displayName ?? "")
        case .updated:
            lhs.fields.updated.compare(rhs.fields.updated)
        }
    }

    /// `sorted(using:)` only applies `order` for `KeyPathComparator`; custom comparators must flip here.
    func orders(_ lhs: IssueSummary, before rhs: IssueSummary) -> Bool {
        switch order {
        case .forward:
            compare(lhs, rhs) == .orderedAscending
        case .reverse:
            compare(lhs, rhs) == .orderedDescending
        }
    }
}

/// Table of issues with double-click to open. Shared by search and versions.
struct IssueListView<FilterAccessory: View>: View {
    let issues: [IssueSummary]
    let onOpen: (String) -> Void
    /// Controls shown to the left of the filter field, such as a status toggle.
    let filterAccessory: FilterAccessory

    init(issues: [IssueSummary], onOpen: @escaping (String) -> Void,
         @ViewBuilder filterAccessory: () -> FilterAccessory) {
        self.issues = issues
        self.onOpen = onOpen
        self.filterAccessory = filterAccessory()
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont
    @State private var selection: Set<IssueSummary.ID> = []
    @State private var sortOrder = [IssueSummarySortComparator(column: .updated, order: .reverse)]
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool

    private var filterExpanded: Bool {
        filterFocused || !filterText.isEmpty
    }

    private var filteredIssues: [IssueSummary] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return issues }
        return issues.filter { $0.matchesLocalFilter(needle) }
    }

    /// `Table`'s `sortOrder` binding drives header indicators and clicks; row order must be applied locally.
    private var displayedIssues: [IssueSummary] {
        guard let active = sortOrder.first else { return filteredIssues }
        return filteredIssues.sorted { active.orders($0, before: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            issueTable
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            if !filterExpanded { Spacer(minLength: 0) }

            filterAccessory

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText, prompt: Text("Filter this list"))
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                        filterFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(filterFocused ? 0.45 : 0.22))
            )
            .frame(maxWidth: filterExpanded ? .infinity : 200)

            if filterExpanded, !filterText.isEmpty {
                Text("\(displayedIssues.count) of \(issues.count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.22), value: filterExpanded)
    }

    /// Widths of the columns around Summary, each fitted to its widest cell
    /// (or header) in the rows on screen, so Summary takes whatever is left
    /// however the window is sized.
    private struct ColumnWidths {
        var key: CGFloat = 0
        var status: CGFloat = 0
        var assignee: CGFloat = 0
        var updated: CGFloat = 0
    }

    private var columnWidths: ColumnWidths {
        /// Space a table cell adds around its content.
        let cellInset: CGFloat = 16
        /// A header's title plus its sort indicator.
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let sortIndicatorWidth: CGFloat = 18
        let issues = displayedIssues
        func fitted(_ header: String, _ widths: [CGFloat]) -> CGFloat {
            let title = ceil((header as NSString).size(withAttributes: [.font: headerFont]).width) + sortIndicatorWidth
            return max(title, widths.max() ?? 0) + cellInset
        }
        let body = ScaledFont.body
        let badge = ScaledFont.caption.weight(.bold)
        var widths = ColumnWidths()
        widths.key = fitted("Key", issues.map { body.monospaced().width(of: $0.key, scale: textScale, family: appFont) })
        widths.status = fitted("Status", Set(issues.map { $0.fields.status.name.uppercased() }).map {
            badge.width(of: $0, scale: textScale, family: appFont) + 16
        })
        widths.assignee = fitted("Assignee", issues.map { issue in
            if let assignee = issue.fields.assignee {
                return 18 + 6 + body.width(of: assignee.displayName, scale: textScale, family: appFont)
            }
            return body.width(of: "Unassigned", scale: textScale, family: appFont)
        })
        widths.updated = fitted("Updated", Set(issues.map { $0.fields.updated.formatted(.relative(presentation: .named)) }).map {
            body.width(of: $0, scale: textScale, family: appFont)
        })
        return widths
    }

    private var issueTable: some View {
        let widths = columnWidths
        return Table(displayedIssues, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", sortUsing: IssueSummarySortComparator(column: .issueType)) { issue in
                IssueTypeBadge(name: issue.fields.issueType.name, iconOnly: true)
            }
            // Every column but Summary fits its contents; Summary takes what's left.
            .width(24 * textScale)

            TableColumn("Key", sortUsing: IssueSummarySortComparator(column: .key)) { issue in
                // The system mono font whatever Settings › Font says, as the width above assumes.
                Text(issue.key).scaledFont(.body.monospaced())
            }
            .width(widths.key)

            TableColumn("Summary", sortUsing: IssueSummarySortComparator(column: .summary)) { issue in
                Text(issue.fields.summary).lineLimit(1).help(issue.fields.summary)
            }

            TableColumn("Status", sortUsing: IssueSummarySortComparator(column: .status)) { issue in
                StatusBadge(status: issue.fields.status)
            }
            .width(widths.status)

            TableColumn("Assignee", sortUsing: IssueSummarySortComparator(column: .assignee)) { issue in
                PersonCell(user: issue.fields.assignee)
            }
            .width(widths.assignee)

            TableColumn("Updated", sortUsing: IssueSummarySortComparator(column: .updated)) { issue in
                Text(issue.fields.updated, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .help(issue.fields.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .width(widths.updated)
        }
        .contextMenu(forSelectionType: IssueSummary.ID.self) { ids in
            if let key = key(for: ids) {
                Button("Open \(key)") { onOpen(key) }
                if let client = session.client {
                    let url = client.browseURL(for: key)
                    Button("Open in Jira") { openURL(url) }
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let key = key(for: ids) { onOpen(key) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func key(for ids: Set<IssueSummary.ID>) -> String? {
        guard let id = ids.first else { return nil }
        return issues.first { $0.id == id }?.key
    }
}

extension IssueListView where FilterAccessory == EmptyView {
    init(issues: [IssueSummary], onOpen: @escaping (String) -> Void) {
        self.init(issues: issues, onOpen: onOpen) { EmptyView() }
    }
}

private extension IssueSummary {
    func matchesLocalFilter(_ needle: String) -> Bool {
        if key.localizedCaseInsensitiveContains(needle) { return true }
        if fields.summary.localizedCaseInsensitiveContains(needle) { return true }
        if fields.status.name.localizedCaseInsensitiveContains(needle) { return true }
        if fields.issueType.name.localizedCaseInsensitiveContains(needle) { return true }
        if let assignee = fields.assignee?.displayName, assignee.localizedCaseInsensitiveContains(needle) { return true }
        return false
    }
}

/// Footer under an `IssueListView`: count, load-more, spinner, error.
struct IssueListFooter: View {
    let query: IssueQuery
    let onLoadMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if query.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Text(query.issues.count == 1 ? "1 issue" : "\(query.issues.count) issues")
                    .foregroundStyle(.secondary)
                if query.hasMore {
                    Button("Load More", action: onLoadMore)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .scaledFont(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
