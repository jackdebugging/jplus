import SwiftUI

/// The team's daily priorities, kept as one Confluence page per day under a
/// shared folder (a `yyyy-MM` folder per month, a `yyyy-MM-dd` page per
/// day). The main pane opens on the last five days, with earlier days loaded
/// below them on request; the day list on the right holds every day.
struct PrioritiesView: View {
    let onOpenIssue: (String) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL
    /// Link to (or id of) the root folder, per account.
    @AppStorage("prioritiesFolderURL") private var folderInput = ""
    @AppStorage("prioritiesShowsDayList") private var showsDayListColumn = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// On an iPhone the day list is a sheet, opened only when asked for.
    @State private var showsDayListSheet = false
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    private var showsDayList: Bool {
        get {
            #if os(iOS)
            if isCompact { return showsDayListSheet }
            #endif
            return showsDayListColumn
        }
        nonmutating set {
            #if os(iOS)
            if isCompact { showsDayListSheet = newValue; return }
            #endif
            showsDayListColumn = newValue
        }
    }
    @State private var model = PrioritiesModel()
    @State private var newText = ""
    @State private var isChoosingFolder = false
    @State private var folderDraft = ""
    /// Looking for the team's folder by name, when none is set.
    @State private var isFindingFolder = false
    /// The search ran and found nothing to use; the user picks instead.
    @State private var findFailureMessage: String?
    @State private var isPickingNewDay = false
    @State private var newDayDate = Date()
    @State private var copiesOpenItems = false
    @FocusState private var isAddFieldFocused: Bool

    private var folderID: String? { PriorityNaming.folderID(from: folderInput) }

    var body: some View {
        content
            .navigationTitle("Daily Priorities")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Day", systemImage: "calendar.badge.plus") {
                        newDayDate = Date()
                        copiesOpenItems = false
                        isPickingNewDay = true
                    }
                    .help("Start a day's priorities")
                    .disabled(model.folder == nil)
                    .popover(isPresented: $isPickingNewDay, arrowEdge: .bottom) { newDayPicker }
                    Button(showsDayList ? "Hide Days" : "Show Days", systemImage: isCompact ? "calendar" : "sidebar.right") {
                        showsDayList.toggle()
                    }
                    .help(showsDayList ? "Hide the list of days" : "Show the list of days")
                    .disabled(folderID == nil)
                }
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
            .adaptiveInspector(isPresented: Binding(get: { showsDayList && folderID != nil }, set: { showsDayList = $0 })) {
                PriorityDayList(model: model)
                    .inspectorColumnWidth(min: 180, ideal: 220, max: 320)
            }
            .onChange(of: model.selectedID) {
                // Picking a day from the sheet shows it.
                if isCompact { showsDayList = false }
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
            ScaledContentUnavailableView {
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
        } else if let message = model.errorMessage, model.index.isEmpty, model.folder == nil {
            ScaledContentUnavailableView {
                Label("Couldn't Load Priorities", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        } else if model.isLoading && !model.hasLoaded {
            ProgressView("Loading priorities…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.index.isEmpty {
            ScaledContentUnavailableView {
                Label("No Days Yet", systemImage: "checklist")
            } description: {
                Text("Start today's page to list the team's priorities.")
            } actions: {
                Button("New Day…") {
                    newDayDate = Date()
                    isPickingNewDay = true
                }
            }
        } else {
            days
        }
    }

    // MARK: - Days

    private var days: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .scaledFont(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if model.todayRef == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                        Text("There's no page for today yet.").foregroundStyle(.secondary)
                        Button("Start Today") {
                            Task { await model.createDay(Date()) }
                        }
                        .disabled(model.isCreatingDay)
                    }
                    .scaledFont(.callout)
                }
                ForEach(model.shownDays) { day in
                    daySection(day, isSelected: day.pageID == model.selectedID)
                }
                if let loading = model.shownIDs.first(where: model.loadingPageIDs.contains),
                   let ref = model.index.first(where: { $0.pageID == loading }) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(ref.title)…").foregroundStyle(.secondary)
                    }
                    .scaledFont(.callout)
                }
                previousDayButton
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var previousDayButton: some View {
        if let previous = model.previousRef {
            Button {
                Task { await model.loadPrevious() }
            } label: {
                Label("Load Previous Day (\(longDate(previous.day)))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!model.loadingPageIDs.isEmpty)
            .help("Show \(previous.title) below")
        } else if !model.shownIDs.isEmpty {
            Text("No earlier days.")
                .scaledFont(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func daySection(_ day: PriorityDay, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dayHeader(day)
            if day.items.isEmpty {
                Text(isSelected ? "Nothing listed yet." : "No priorities were listed.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(day.items) { item in
                        PriorityItemRow(
                            item: item,
                            day: day,
                            canMoveToToday: model.todayRef.map { $0.pageID != day.pageID } ?? false,
                            isBusy: model.busyItemIDs.contains(item.id),
                            model: model
                        )
                    }
                }
            }
            if isSelected {
                addField(for: day)
            }
        }
    }

    #if os(iOS)
    /// Rows carry their own padding and separator, as in Reminders.
    private static let rowSpacing: CGFloat = 0

    /// Reminders' section header: the day in bold (Today in the accent
    /// color), its date beneath, the count and a menu on the right.
    private func dayHeader(_ day: PriorityDay) -> some View {
        let isToday = Calendar.current.isDateInToday(day.day)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(day.day))
                    .scaledFont(.title2.bold())
                    .foregroundStyle(isToday ? Color.accentColor : .primary)
                Text(headerDate(day.day))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !day.items.isEmpty {
                Text(day.openCount == 0 ? "All done" : "\(day.items.count - day.openCount) of \(day.items.count)")
                    .scaledFont(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button("Open in Confluence", systemImage: "safari") { openURL(day.webURL) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .scaledFont(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(day.title)")
        }
    }

    /// The date under a day's name, without repeating a weekday it already shows.
    private func headerDate(_ day: Date) -> String {
        let calendar = Calendar.current
        let named = calendar.isDateInToday(day) || calendar.isDateInYesterday(day) || calendar.isDateInTomorrow(day)
        if !named, calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.month(.wide).day())
        }
        return named ? longDate(day) : day.formatted(.dateTime.month(.wide).day().year())
    }

    /// Reminders' "New Reminder" row, typed into in place.
    private func addField(for day: PriorityDay) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .scaledFont(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: PriorityItemRow.checkWidth)
            TextField("New Priority", text: $newText, axis: .vertical)
                .lineLimit(1...4)
                .focused($isAddFieldFocused)
                .onSubmit { add(to: day) }
                .submitLabel(.done)
        }
        .padding(.vertical, 10)
    }
    #else
    private static let rowSpacing: CGFloat = 6

    private func dayHeader(_ day: PriorityDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(dayLabel(day.day))
                .scaledFont(.title3.weight(.semibold))
            Text(longDate(day.day))
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
            if !day.items.isEmpty {
                Text("\(day.items.count - day.openCount) of \(day.items.count) done")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            Spacer(minLength: 8)
            Button("Open in Confluence", systemImage: "arrow.up.right.square") { openURL(day.webURL) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(day.title) in Confluence")
        }
    }

    private func addField(for day: PriorityDay) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("Add a priority…", text: $newText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isAddFieldFocused)
                .onSubmit { add(to: day) }
        }
        .padding(.top, 2)
    }
    #endif

    private func add(to day: PriorityDay) {
        let text = newText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        newText = ""
        Task {
            await model.add(text, to: day)
            isAddFieldFocused = true
        }
    }

    // MARK: - New day

    private var newDayPicker: some View {
        let existing = model.ref(for: newDayDate)
        let source = model.dayBefore(newDayDate)
        return VStack(alignment: .leading, spacing: 12) {
            Text("New Day")
                .scaledFont(.headline)
            DatePicker("Date", selection: $newDayDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            if let existing {
                HStack(spacing: 6) {
                    Label("\(existing.title) already exists.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Button("Open It") {
                        isPickingNewDay = false
                        Task { await model.select(existing.pageID) }
                    }
                    .linkButtonStyle()
                }
                .scaledFont(.callout)
            } else if let source {
                Toggle("Copy unfinished items from \(longDate(source.day))", isOn: $copiesOpenItems)
                    .scaledFont(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPickingNewDay = false }
                Button("Create \(PriorityNaming.dayTitle(for: newDayDate))") {
                    let date = newDayDate
                    let copyFrom = copiesOpenItems ? source : nil
                    isPickingNewDay = false
                    Task { await model.createDay(date, copyingFrom: copyFrom) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(existing != nil || model.isCreatingDay)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Labels

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    /// "Wednesday, October 7", with the year when it isn't this year.
    private func longDate(_ day: Date) -> String {
        if Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    // MARK: - Folder

    private var folderChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Priorities Folder")
                .scaledFont(.headline)
            Text("Paste the Confluence folder's link, e.g. …/wiki/spaces/VPE1/folder/123456.")
                .scaledFont(.callout)
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

/// Every day under the folder, newest first and grouped by month, shown
/// on the right. Picking one shows it on its own in the main pane.
private struct PriorityDayList: View {
    let model: PrioritiesModel

    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    private var months: [(key: String, value: [PriorityDayRef])] {
        Dictionary(grouping: model.index) { PriorityNaming.monthTitle(for: $0.day) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { id in if let id { Task { await model.select(id) } } }
        )) {
            ForEach(months, id: \.key) { _, days in
                Section {
                    ForEach(days) { ref in
                        HStack(spacing: 6) {
                            Text(ref.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            Spacer(minLength: 4)
                            if ref.title == model.todayTitle {
                                Text("Today")
                                    .scaledFont(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(ref.pageID)
                        .help(ref.title)
                        .contextMenu {
                            if let client = session.client {
                                Button("Open in Confluence", systemImage: "safari") {
                                    openURL(ref.webURL(on: client.credentials.siteURL))
                                }
                            }
                        }
                    }
                } header: {
                    ScaledSectionHeader(title: Text(days[0].day.formatted(.dateTime.month(.wide).year())))
                }
            }
        }
        .overlay {
            if model.isLoading && model.index.isEmpty {
                ProgressView()
            }
        }
    }
}

/// One checkbox line. Double-click (or Edit… in the menu) to change its text.
/// On iOS it looks like a reminder: a round check, and a hairline beneath.
private struct PriorityItemRow: View {
    let item: PriorityItem
    let day: PriorityDay
    /// Today has a page and this item is on another day.
    let canMoveToToday: Bool
    let isBusy: Bool
    let model: PrioritiesModel

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont

    #if os(iOS)
    private static let openSymbol = "circle"
    private static let doneSymbol = "checkmark.circle"
    #else
    private static let openSymbol = "square"
    private static let doneSymbol = "checkmark.square"
    #endif

    /// Width of the check column, which the add row lines up with.
    static let checkWidth: CGFloat = 26

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            line
                .padding(.vertical, 10)
            Divider()
                .padding(.leading, Self.checkWidth + 12)
        }
        #else
        line
        #endif
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.lineSpacing) {
            check

            if isEditing {
                TextField("Priority", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onSubmit(commitEdit)
                    .onEscape { isEditing = false }
                    .onChange(of: isFocused) { if !isFocused { commitEdit() } }
            } else {
                Text(ADFInline.attributedString(item.content, textScale: textScale, font: appFont))
                    .strikethrough(item.isDone && Self.strikesDone)
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
            Button(item.isDone ? "Mark Not Done" : "Mark Done", systemImage: item.isDone ? Self.openSymbol : Self.doneSymbol) {
                model.setDone(!item.isDone, item: item, in: day)
            }
            if canMoveToToday {
                Button("Move to Today", systemImage: "arrow.uturn.forward") {
                    Task { await model.moveToToday(item, from: day) }
                }
            }
            Button("Copy Text", systemImage: "doc.on.doc") {
                Clipboard.copy(item.plainText)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.remove(item, from: day)
            }
        }
    }

    #if os(iOS)
    private static let lineSpacing: CGFloat = 12
    /// Reminders greys finished items without striking them through.
    private static let strikesDone = false

    /// Reminders' round check: an empty ring, filled when done.
    private var check: some View {
        Button {
            model.setDone(!item.isDone, item: item, in: day)
        } label: {
            Image(systemName: item.isDone ? "largecircle.fill.circle" : "circle")
                .scaledFont(.title3.weight(.light))
                .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: Self.checkWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(item.plainText)
        .accessibilityValue(item.isDone ? "Done" : "Not done")
        .accessibilityAddTraits(.isToggle)
    }
    #else
    private static let lineSpacing: CGFloat = 8
    private static let strikesDone = true

    private var check: some View {
        Toggle("", isOn: Binding(
            get: { item.isDone },
            set: { model.setDone($0, item: item, in: day) }
        ))
        .checkboxToggleStyle()
        .labelsHidden()
        .disabled(isBusy)
        .accessibilityLabel(item.plainText)
    }
    #endif

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
