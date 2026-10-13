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
    /// On iPhone and iPad the day list is a sheet, opened only when asked for.
    @State private var showsDayListSheet = false
    private let usesDayListSheet = true
    #else
    private let usesDayListSheet = false
    #endif

    private var showsDayList: Bool {
        get {
            #if os(iOS)
            return showsDayListSheet
            #else
            return showsDayListColumn
            #endif
        }
        nonmutating set {
            #if os(iOS)
            showsDayListSheet = newValue
            #else
            showsDayListColumn = newValue
            #endif
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
    /// Where a new priority is being typed: under the one Return was pressed in.
    @State private var newItemSpot: NewItemSpot?
    /// The item swiped open to show its actions, on iOS.
    @State private var swipedOpenID: String?
    #if os(iOS)
    @State private var addFieldHeight: CGFloat = 0
    private static let addFieldID = "addField"
    #endif

    private var folderID: String? { PriorityNaming.folderID(from: folderInput) }

    var body: some View {
        content
            .navigationTitle("Daily Priorities")
            .adaptiveInspector(isPresented: Binding(get: { showsDayList && folderID != nil }, set: { showsDayList = $0 })) {
                PriorityDayList(model: model)
                    .inspectorColumnWidth(min: 180, ideal: 220, max: 320)
            }
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
                    Button(showsDayList ? "Hide Days" : "Show Days", systemImage: usesDayListSheet ? "calendar" : "sidebar.right") {
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
            .onChange(of: model.selectedID) {
                // Picking a day from the sheet shows it.
                if usesDayListSheet { showsDayList = false }
            }
            .loadTask(id: folderID) {
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
        } catch where error.isCancellation {
            return
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
        ScrollViewReader { proxy in
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
            #if os(iOS)
            // The keyboard doesn't make room as a new priority grows a line, so
            // keep the field's last line in view.
            .onChange(of: addFieldHeight) { old, new in
                guard isAddFieldFocused, new > old else { return }
                withAnimation { proxy.scrollTo(Self.addFieldID, anchor: .bottom) }
            }
            // Scrolling closes a row swiped open, as in Mail.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in
                if swipedOpenID != nil { swipedOpenID = nil }
            }
            #endif
        }
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
                        let spot = NewItemSpot(pageID: day.pageID, afterID: item.id)
                        PriorityItemRow(
                            item: item,
                            day: day,
                            canMoveToToday: model.todayRef.map { $0.pageID != day.pageID } ?? false,
                            isBusy: model.busyItemIDs.contains(item.id),
                            model: model,
                            swipedOpenID: $swipedOpenID,
                            onReturn: { newItemSpot = spot }
                        )
                        if newItemSpot == spot {
                            NewPriorityRow { text in
                                // The next one starts under the one just added.
                                newItemSpot = model.add(text, to: day, after: item.id)
                                    .map { NewItemSpot(pageID: day.pageID, afterID: $0) }
                            } onEnd: { text in
                                #if os(iOS)
                                // On iOS, as in Reminders there, leaving it keeps what was typed.
                                model.add(text, to: day, after: item.id)
                                #endif
                                if newItemSpot == spot { newItemSpot = nil }
                            }
                        }
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
            // Return adds it and stays for the next; the checkmark in the
            // navigation bar adds it and closes the keyboard.
            TextField("New Priority", text: $newText, axis: .vertical)
                .lineLimit(1...4)
                .focused($isAddFieldFocused)
                .onChange(of: newText) { old, new in
                    guard isReturnKeystroke(from: old, to: new) else { return }
                    newText = old
                    add(to: day)
                }
        }
        .padding(.vertical, 10)
        .id(Self.addFieldID)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addFieldHeight = $0 }
        .toolbar {
            if isAddFieldFocused {
                ToolbarItem(placement: .confirmationAction) {
                    DoneEditingButton {
                        add(to: day, refocus: false)
                        isAddFieldFocused = false
                    }
                }
            }
        }
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

    /// `refocus` puts the cursor back in the field for the next entry.
    private func add(to day: PriorityDay, refocus: Bool = true) {
        guard model.add(newText, to: day) != nil else { return }
        newText = ""
        if refocus { isAddFieldFocused = true }
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

private struct NewItemSpot: Equatable {
    let pageID: String
    let afterID: String
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

/// One checkbox line, edited as in Reminders: a click or tap edits it (one
/// on a link opens the link), the change saves when you're done, and Return
/// saves it and starts a new priority below. On the Mac the caret goes where
/// the click landed. On iOS it looks like a reminder (a round check, and a
/// hairline beneath), and swiping it left shows Edit and Delete.
private struct PriorityItemRow: View {
    let item: PriorityItem
    let day: PriorityDay
    /// Today has a page and this item is on another day.
    let canMoveToToday: Bool
    let isBusy: Bool
    let model: PrioritiesModel
    /// The item swiped open to show its actions (iOS); one at a time.
    @Binding var swipedOpenID: String?
    /// Return was pressed in an edit: start a new priority below.
    let onReturn: () -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont
    @Environment(\.openURL) private var openURL
    /// The current click landed on a link, so it opens that instead of editing.
    @State private var clickedLink = false
    #if os(macOS)
    /// Where in the text the click that started editing landed, for the caret.
    @State private var editClick: CGPoint?
    #endif

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
        .modifier(SwipeToRevealActions(
            isOpen: Binding(
                get: { swipedOpenID == item.id },
                set: { open in
                    if open { swipedOpenID = item.id } else if swipedOpenID == item.id { swipedOpenID = nil }
                }
            ),
            isEnabled: !isEditing,
            onEdit: beginEdit,
            onDelete: { model.remove(item, from: day) }
        ))
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
                    #if os(macOS)
                    .onSubmit(submitEdit)
                    // There's nothing to cancel: what's typed is kept, as in Reminders.
                    .onEscape(perform: commitEdit)
                    .onChange(of: isFocused) { if isFocused { placeCaret() } else { commitEdit() } }
                    .endsEditingOnClickOutside(isFocused: isFocused, text: draft)
                    #else
                    .onChange(of: draft) { old, new in
                        guard isReturnKeystroke(from: old, to: new) else { return }
                        draft = old
                        submitEdit()
                    }
                    .onEscape { isEditing = false }
                    .onChange(of: isFocused) { if !isFocused { commitEdit() } }
                    // Return starts a new priority below; the checkmark saves.
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            DoneEditingButton(action: commitEdit)
                        }
                    }
                    #endif
                    .onDisappear(perform: commitEdit)
            } else {
                Text(ADFInline.attributedString(item.content, textScale: textScale, font: appFont))
                    .strikethrough(item.isDone && Self.strikesDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // One click edits, as in Reminders. It runs alongside link
                    // handling so links still open, and a link click doesn't edit.
                    .environment(\.openURL, OpenURLAction { url in
                        clickedLink = true
                        openURL(url)
                        return .handled
                    })
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        // A link opens during the same click; look once it has.
                        DispatchQueue.main.async {
                            if !clickedLink { tapped(at: tap.location) }
                            clickedLink = false
                        }
                    })
            }
            if isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .contextMenu {
            #if os(macOS)
            Button("Edit", systemImage: "pencil", action: beginEdit)
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.remove(item, from: day)
            }
            #else
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
            #endif
        }
    }

    #if os(iOS)
    static let lineSpacing: CGFloat = 12
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
    static let lineSpacing: CGFloat = 8
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

    private func tapped(at location: CGPoint) {
        #if os(macOS)
        editClick = location
        beginEdit()
        #else
        // A tap while a row is swiped open only closes it, as in Mail.
        if swipedOpenID != nil {
            swipedOpenID = nil
        } else {
            beginEdit()
        }
        #endif
    }

    /// Return: save, and start a new priority below unless it was emptied.
    private func submitEdit() {
        let isBlank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commitEdit()
        if !isBlank { onReturn() }
    }

    #if os(macOS)
    /// Puts the caret where the click that started editing landed, or at the
    /// end, instead of selecting everything as a text field does on focus.
    private func placeCaret() {
        let click = editClick
        editClick = nil
        whenEditing(draft) { window, editor in
            var index = (editor.string as NSString).length
            if let click {
                // The click was measured from the text's top-left corner; find
                // that corner in the field, which shows the same text.
                let start = window.convertFromScreen(editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil))
                let point = NSPoint(x: start.minX + click.x, y: start.maxY - click.y)
                index = editor.characterIndexForInsertion(at: editor.convert(point, from: nil))
            }
            editor.setSelectedRange(NSRange(location: index, length: 0))
        }
    }
    #endif

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        if draft != item.plainText {
            model.setText(draft, item: item, in: day)
        }
    }
}

#if os(macOS)
/// Calls `body` once the field showing `text` is being edited. A newly
/// focused field gets the field editor a turn or two of the run loop later,
/// more while rows around it come and go.
private func whenEditing(_ text: String, tries: Int = 5, _ body: @escaping (NSWindow, NSTextView) -> Void) {
    DispatchQueue.main.async {
        if let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView, editor.string == text {
            window.layoutIfNeeded()
            body(window, editor)
        } else if tries > 0 {
            whenEditing(text, tries: tries - 1, body)
        }
    }
}

private extension View {
    /// While the field is focused, a click anywhere else in the app ends its
    /// edit, as in Reminders; the click still does what it would. `text` is
    /// what the field shows, to know it once it's being edited.
    func endsEditingOnClickOutside(isFocused: Bool, text: String) -> some View {
        modifier(EndsEditingOnClickOutside(isFocused: isFocused, text: text))
    }
}

private struct EndsEditingOnClickOutside: ViewModifier {
    let isFocused: Bool
    let text: String

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused, initial: true) { if isFocused { start() } else { stop() } }
            .onDisappear(perform: stop)
    }

    private func start() {
        whenEditing(text) { _, editor in
            guard monitor == nil else { return }
            let field = editor.delegate as? NSView ?? editor
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak field] event in
                // Only while this field is still the one being edited.
                guard let field, let window = field.window,
                      let editor = window.firstResponder as? NSTextView,
                      (editor.delegate as? NSView ?? editor) === field else { return event }
                if event.window === window, field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                window.makeFirstResponder(nil)
                return event
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

#endif

/// A priority being typed under another, as after Return in Reminders.
/// Return adds it and starts the next one below; blank text isn't added. On
/// the Mac, Esc or a click elsewhere drops it unsaved; on iOS, leaving it
/// keeps what was typed, as Reminders does there.
private struct NewPriorityRow: View {
    /// Return was pressed with this text.
    let onSubmit: (String) -> Void
    /// The row was left with this text in it.
    let onEnd: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            line
                .padding(.vertical, 10)
            Divider()
                .padding(.leading, PriorityItemRow.checkWidth + 12)
        }
        #else
        line
        #endif
    }

    private var line: some View {
        HStack(alignment: Self.alignment, spacing: PriorityItemRow.lineSpacing) {
            #if os(iOS)
            Image(systemName: "circle")
                .scaledFont(.title3.weight(.light))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .frame(width: PriorityItemRow.checkWidth)
            #else
            Toggle("", isOn: .constant(false))
                .checkboxToggleStyle()
                .labelsHidden()
                .disabled(true)
            #endif
            TextField("New Priority", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isFocused)
                #if os(macOS)
                .onSubmit(submit)
                .endsEditingOnClickOutside(isFocused: isFocused, text: text)
                #else
                .onChange(of: text) { old, new in
                    guard isReturnKeystroke(from: old, to: new) else { return }
                    text = old
                    submit()
                }
                .toolbar {
                    if isFocused {
                        ToolbarItem(placement: .confirmationAction) {
                            DoneEditingButton { isFocused = false }
                        }
                    }
                }
                #endif
                .onEscape(perform: end)
                .onChange(of: isFocused) { if !isFocused { end() } }
        }
        // After the Return that made this row has finished with the field it came from.
        .onAppear { DispatchQueue.main.async { isFocused = true } }
    }

    #if os(iOS)
    /// As in the add row: an empty multi-line field has no first baseline
    /// here, so lining up on it drops the field a line.
    private static let alignment = VerticalAlignment.center
    #else
    private static let alignment = VerticalAlignment.firstTextBaseline
    #endif

    // Each empties the field first, so the focus change that follows doesn't
    // hand the same text on again.
    private func submit() {
        let value = text
        text = ""
        onSubmit(value)
    }

    private func end() {
        let value = text
        text = ""
        onEnd(value)
    }
}


#if os(iOS)
/// Whether an edit is the Return key: one character more, and it's a line
/// break. (Return types one into a multi-line field instead of submitting.)
private func isReturnKeystroke(from old: String, to new: String) -> Bool {
    new.count == old.count + 1 && new.filter(\.isNewline).count == old.filter(\.isNewline).count + 1
}

/// Swiping a row left reveals Edit and Delete behind it, as in Mail; a swipe
/// back, a tap, scrolling or opening another row closes it.
private struct SwipeToRevealActions: ViewModifier {
    @Binding var isOpen: Bool
    /// Off while the row is being edited, so drags select text.
    let isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    private static let buttonWidth: CGFloat = 74
    private static let openOffset = -2 * buttonWidth

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                HStack(spacing: 0) {
                    button("Edit", tint: .green, action: onEdit)
                    button("Delete", tint: .red, action: onDelete)
                }
                .frame(width: max(0, -offset))
                .clipped()
            }
            .gesture(SidewaysPan(isEnabled: isEnabled, allowsRightward: isOpen) {
                startOffset = offset
                isOpen = true
            } onChanged: { translation in
                let target = startOffset + translation
                // Past fully open it stretches, with resistance.
                offset = target < Self.openOffset ? Self.openOffset + (target - Self.openOffset) / 3 : min(0, target)
            } onEnded: { translation, velocity in
                let target = startOffset + translation
                settle(open: velocity < -300 || (velocity < 300 && target < Self.openOffset / 2))
            })
            .onChange(of: isOpen) { if !isOpen { settle(open: false) } }
            .onChange(of: isEnabled) { if !isEnabled { isOpen = false } }
    }

    private func button(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            isOpen = false
            action()
        } label: {
            // The color takes its share of what's revealed; the title keeps its size.
            tint
                .overlay {
                    Text(title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize()
                }
                .clipped()
        }
        .buttonStyle(.plain)
    }

    private func settle(open: Bool) {
        withAnimation(.snappy) { offset = open ? Self.openOffset : 0 }
        if isOpen != open { isOpen = open }
    }
}

/// A pan that starts only when the finger moves sideways, so the page still
/// scrolls under it; leftward only, unless the row is open.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let allowsRightward: Bool
    let onBegan: () -> Void
    let onChanged: (_ translation: CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.allowsRightward = allowsRightward
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            onChanged(translation)
        case .ended, .cancelled:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsRightward = false

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) && (velocity.x < 0 || allowsRightward)
        }
    }
}

/// The checkmark Reminders shows in the navigation bar while you type: it
/// saves, which leaves the keyboard's Return key for line breaks.
private struct DoneEditingButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .confirm, action: action)
        } else {
            Button("Done", action: action)
                .fontWeight(.semibold)
        }
    }
}
#endif
