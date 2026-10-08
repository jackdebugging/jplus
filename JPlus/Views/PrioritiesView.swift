import SwiftUI

/// The team's daily priorities, kept as one Confluence page per day under a
/// shared folder (a `yyyy-MM` folder per month, a `yyyy-MM-dd` page per
/// day). Today's list is editable here; every day is editable in Confluence.
struct PrioritiesView: View {
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    /// Link to (or id of) the root folder, per account.
    @AppStorage("prioritiesFolderURL") private var folderInput = ""
    @State private var model = PrioritiesModel()
    @State private var newText = ""
    @State private var isChoosingFolder = false
    @State private var folderDraft = ""
    /// Looking for the team's folder by name, when none is set.
    @State private var isFindingFolder = false
    /// The search ran and found nothing to use; the user picks instead.
    @State private var findFailureMessage: String?
    @FocusState private var isAddFieldFocused: Bool

    private var folderID: String? { PriorityNaming.folderID(from: folderInput) }

    var body: some View {
        content
            .navigationTitle("Daily Priorities")
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(folderID == nil)
                    Button("Choose Folder…", systemImage: "folder.badge.gearshape") {
                        folderDraft = folderInput
                        isChoosingFolder = true
                    }
                    .popover(isPresented: $isChoosingFolder, arrowEdge: .bottom) { folderChooser }
                    if let url = folderWebURL {
                        Button("Open in Confluence", systemImage: "safari") { openURL(url) }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Open the Daily Priorities folder in Confluence (⇧⌘O)")
                    }
                }
            }
            .task(id: folderID) {
                guard let client = session.client else { return }
                if let folderID {
                    await model.load(client: client, folderID: folderID)
                } else {
                    await findFolder(using: client)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                // Ticket links on this site open in the app; anything else goes to the browser.
                if url.host() == session.client?.credentials.siteURL.host(),
                   let key = IssueKey.parse(url.absoluteString) {
                    onOpenIssue(key)
                    return .handled
                }
                return .systemAction
            })
    }

    /// The loaded folder's own link, or the saved link if it is one.
    private var folderWebURL: URL? {
        if let folder = model.folder, let client = session.client { return folder.webURL(on: client.credentials.siteURL) }
        let saved = folderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.hasPrefix("http") ? URL(string: saved) : nil
    }

    /// Looks for "Mobile App(s)" → "Daily Priorities" on the site and uses it
    /// when there's exactly one; otherwise asks the user to choose.
    private func findFolder(using client: JiraClient) async {
        isFindingFolder = true
        findFailureMessage = nil
        defer { isFindingFolder = false }
        do {
            if let folder = try await PriorityNaming.findFolder(using: client) {
                folderInput = folder.webURL(on: client.credentials.siteURL).absoluteString
            } else {
                findFailureMessage = "No \"\(PriorityNaming.folderTitle)\" folder was found inside a \"\(PriorityNaming.parentFolderTitle)s\" folder on \(client.credentials.siteHost)."
            }
        } catch {
            findFailureMessage = "Couldn't search \(client.credentials.siteHost) for the folder. \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var content: some View {
        if folderID == nil, isFindingFolder {
            ProgressView("Finding the team's Daily Priorities folder…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folderID == nil {
            ContentUnavailableView {
                Label("Choose a Daily Priorities Folder", systemImage: "checklist")
            } description: {
                Text((findFailureMessage.map { $0 + " " } ?? "") + "Paste the link to the Confluence folder that holds the team's daily lists. Each month gets a folder inside it and each day a page.")
            } actions: {
                Button("Choose Folder…") {
                    folderDraft = folderInput
                    isChoosingFolder = true
                }
                Button("Search Again") {
                    if let client = session.client { Task { await findFolder(using: client) } }
                }
            }
        } else if let message = model.errorMessage, model.days.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Priorities", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.isLoading && !model.hasLoaded {
            ProgressView("Loading priorities…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            days
        }
    }

    private var days: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                todaySection
                ForEach(model.days.filter { $0.title != model.todayTitle }) { day in
                    daySection(day)
                }
                if model.hasMore {
                    Button("Show Earlier Days") { Task { await model.showMore() } }
                        .buttonStyle(.borderless)
                        .disabled(model.isLoading)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            dayHeader(title: "Today", day: Date(), page: model.today)
            if let today = model.today {
                itemRows(today)
            } else if model.isCreatingToday {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting today's page…").foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Text("Nothing yet. Add the first priority to start today's page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Add a priority…", text: $newText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isAddFieldFocused)
                    .onSubmit(addItem)
            }
            .padding(.top, 2)
            if model.today == nil, let previous = model.days.first, previous.openCount > 0 {
                Button("Carry Over \(previous.openCount) Open from \(dayLabel(previous.day))") {
                    Task { await model.carryOverOpenItems() }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(model.isCreatingToday)
            }
        }
    }

    private func addItem() {
        let text = newText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newText = ""
        Task {
            await model.add(text)
            isAddFieldFocused = true
        }
    }

    // MARK: - Days

    private func daySection(_ day: PriorityDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dayHeader(title: dayLabel(day.day), day: day.day, page: day)
            if day.items.isEmpty {
                Text("No priorities were listed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                itemRows(day)
            }
        }
    }

    private func dayHeader(title: String, day: Date, page: PriorityDay?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let page {
                let done = page.items.count - page.openCount
                if !page.items.isEmpty {
                    Text("\(done) of \(page.items.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer(minLength: 8)
                Button("Open in Confluence", systemImage: "arrow.up.right.square") { openURL(page.webURL) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Open \(page.title) in Confluence")
            }
        }
    }

    private func itemRows(_ day: PriorityDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(day.items) { item in
                PriorityItemRow(item: item, day: day, isToday: day.title == model.todayTitle, isBusy: model.busyItemIDs.contains(item.id), model: model)
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    // MARK: - Folder

    private var folderChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Priorities Folder")
                .font(.headline)
            Text("Paste the Confluence folder's link, e.g. …/wiki/spaces/VPE1/folder/123456.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Folder link", text: $folderDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveFolder)
            HStack {
                Spacer()
                Button("Cancel") { isChoosingFolder = false }
                Button("Use Folder", action: saveFolder)
                    .keyboardShortcut(.defaultAction)
                    .disabled(PriorityNaming.folderID(from: folderDraft) == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func saveFolder() {
        guard PriorityNaming.folderID(from: folderDraft) != nil else { return }
        folderInput = folderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isChoosingFolder = false
    }
}

/// One checkbox line. Double-click (or Edit… in the menu) to change its text.
private struct PriorityItemRow: View {
    let item: PriorityItem
    let day: PriorityDay
    let isToday: Bool
    let isBusy: Bool
    let model: PrioritiesModel

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.isDone },
                set: { model.setDone($0, item: item, in: day) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isBusy)
            .accessibilityLabel(item.plainText)

            if isEditing {
                TextField("Priority", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onSubmit(commitEdit)
                    .onExitCommand { isEditing = false }
                    .onChange(of: isFocused) { if !isFocused { commitEdit() } }
            } else {
                Text(ADFInline.attributedString(item.content))
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEdit)
            }
            if isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .contextMenu {
            Button("Edit…", systemImage: "pencil", action: beginEdit)
            Button(item.isDone ? "Mark Not Done" : "Mark Done", systemImage: item.isDone ? "square" : "checkmark.square") {
                model.setDone(!item.isDone, item: item, in: day)
            }
            if !isToday {
                Button("Move to Today", systemImage: "arrow.uturn.forward") {
                    Task { await model.moveToToday(item, from: day) }
                }
            }
            Button("Copy Text", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.plainText, forType: .string)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.remove(item, from: day)
            }
        }
    }

    private func beginEdit() {
        draft = item.plainText
        isEditing = true
        isFocused = true
    }

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        if draft != item.plainText {
            model.setText(draft, item: item, in: day)
        }
    }
}
