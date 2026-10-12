import Foundation
import Observation

/// Indexes the day pages under the Daily Priorities folder, loads the ones
/// on screen, and writes edits back. Every write re-reads the page first and
/// saves over its current version, retrying if someone else saved in
/// between, so two people ticking boxes at once don't lose each other's
/// changes.
@Observable
final class PrioritiesModel {
    /// The root folder, once loaded.
    private(set) var folder: ConfluenceFolder?
    /// Every day page under the folder, newest first. Titles only; bodies
    /// load when a day is shown.
    private(set) var index: [PriorityDayRef] = []
    /// Loaded day pages by page id.
    private(set) var pages: [String: PriorityDay] = [:]
    /// Days in the main pane, top first: the selected day, then each earlier
    /// day loaded below it — the last few at first, more with Load Previous Day.
    private(set) var shownIDs: [String] = []
    private(set) var loadingPageIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Ids of items with a save in flight.
    private(set) var busyItemIDs: Set<String> = []
    /// True while a new day's page is being created.
    private(set) var isCreatingDay = false

    private var client: JiraClient?
    private var folderID = ""
    /// Month folder titles → ids, from the last load.
    private var monthFolderIDs: [String: String] = [:]
    /// Writes run one after another, so edits to the same page don't race.
    private var lastWrite: Task<Void, Never>?
    private var generation = 0
    /// How many days the main pane opens with.
    private let initialDayCount = 5

    private var siteURL: URL { client?.credentials.siteURL ?? URL(string: "https://atlassian.net")! }

    var todayTitle: String { PriorityNaming.dayTitle(for: Date()) }
    var todayRef: PriorityDayRef? { ref(titled: todayTitle) }
    var selectedID: String? { shownIDs.first }
    var shownDays: [PriorityDay] { shownIDs.compactMap { pages[$0] } }

    func ref(titled title: String) -> PriorityDayRef? { index.first { $0.title == title } }
    func ref(for date: Date) -> PriorityDayRef? { ref(titled: PriorityNaming.dayTitle(for: date)) }

    /// The next earlier day after the last one shown.
    var previousRef: PriorityDayRef? {
        guard let last = shownIDs.last, let position = index.firstIndex(where: { $0.pageID == last }) else { return nil }
        let next = index.index(after: position)
        return next < index.endIndex ? index[next] : nil
    }

    /// The most recent day before `date`, which a new day can copy from.
    func dayBefore(_ date: Date) -> PriorityDayRef? {
        let title = PriorityNaming.dayTitle(for: date)
        return index.first { $0.title < title }
    }

    // MARK: - Loading

    func load(client: JiraClient, folderID: String) async {
        self.client = client
        self.folderID = folderID
        generation += 1
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        var cancelled = false
        // A cancelled load doesn't count as loaded, so the spinner stays until it runs again.
        defer { if myGeneration == generation { isLoading = false; if !cancelled { hasLoaded = true } } }
        do {
            async let folder = client.confluenceFolder(id: folderID)
            let children = try await client.confluenceFolderChildren(id: folderID)
            let months = children.filter { $0.type == "folder" && PriorityNaming.isMonthTitle($0.title) }
            let listed = try await withThrowingTaskGroup(of: (String, [ConfluenceChild]).self) { group in
                for month in months {
                    group.addTask { (month.id, try await client.confluenceFolderChildren(id: month.id)) }
                }
                var listed: [(String, [ConfluenceChild])] = []
                for try await entry in group { listed.append(entry) }
                return listed
            }
            let root = try await folder
            guard myGeneration == generation else { return }
            self.folder = root
            monthFolderIDs = Dictionary(months.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })
            index = listed
                .flatMap { monthID, children in
                    children.compactMap { child -> PriorityDayRef? in
                        guard child.type == "page", PriorityNaming.isDayTitle(child.title),
                              let day = PriorityNaming.day(fromTitle: child.title) else { return nil }
                        return PriorityDayRef(pageID: child.id, title: child.title, day: day, monthFolderID: monthID)
                    }
                }
                .sorted { $0.title > $1.title }

            // Keep what was on screen if it still exists; otherwise open the
            // last few days, starting from today or the latest day.
            let known = Set(index.map(\.pageID))
            shownIDs = shownIDs.filter(known.contains)
            if shownIDs.isEmpty, let first = todayRef ?? index.first,
               let start = index.firstIndex(where: { $0.pageID == first.pageID }) {
                shownIDs = index[start...].prefix(initialDayCount).map(\.pageID)
            }
            pages = pages.filter { known.contains($0.key) }
            await withTaskGroup(of: Void.self) { group in
                for id in shownIDs { group.addTask { await self.loadPage(id) } }
            }
        } catch where error.isCancellation {
            cancelled = true
        } catch {
            guard myGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let client else { return }
        await load(client: client, folderID: folderID)
    }

    /// Shows one day on its own, as picked from the day list.
    func select(_ pageID: String) async {
        guard selectedID != pageID || shownIDs.count > 1 else { return }
        shownIDs = [pageID]
        if pages[pageID] == nil { await loadPage(pageID) }
    }

    /// Adds the next earlier day below the ones shown.
    func loadPrevious() async {
        guard let ref = previousRef else { return }
        shownIDs.append(ref.pageID)
        if pages[ref.pageID] == nil { await loadPage(ref.pageID) }
    }

    private func loadPage(_ pageID: String) async {
        guard let client, let ref = index.first(where: { $0.pageID == pageID }) else { return }
        loadingPageIDs.insert(pageID)
        defer { loadingPageIDs.remove(pageID) }
        do {
            let page = try await client.confluencePage(id: pageID)
            pages[pageID] = PriorityDay(page: page, day: ref.day, siteURL: client.credentials.siteURL)
        } catch where error.isCancellation {
            return
        } catch {
            errorMessage = "Couldn't load \(ref.title): \(error.localizedDescription)"
        }
    }

    // MARK: - New day

    /// Creates the page for `date`, inside its month's folder (made if
    /// needed). Refuses a date that already has a page. With `copyingFrom`,
    /// that day's unfinished items start the new page.
    @discardableResult
    func createDay(_ date: Date, copyingFrom source: PriorityDayRef? = nil) async -> Bool {
        guard let client, let spaceID = folder?.spaceId else { return false }
        let title = PriorityNaming.dayTitle(for: date)
        if let existing = ref(titled: title) {
            errorMessage = "\(title) already exists."
            await select(existing.pageID)
            return false
        }
        isCreatingDay = true
        defer { isCreatingDay = false }
        errorMessage = nil
        do {
            var items: [ADFNode] = []
            if let source {
                let page = try await client.confluencePage(id: source.pageID)
                items = page.document.taskItems.filter { !$0.isDone }.map { ADFNode.taskItem($0.content) }
            }

            let monthTitle = PriorityNaming.monthTitle(for: date)
            let monthID: String
            if let known = monthFolderIDs[monthTitle] {
                monthID = known
            } else if let found = try await client.confluenceFolderChildren(id: folderID)
                        .first(where: { $0.type == "folder" && $0.title == monthTitle }) {
                // Someone else started the month since the last load.
                monthID = found.id
            } else {
                monthID = try await client.createConfluenceFolder(title: monthTitle, spaceID: spaceID, parentID: folderID).id
            }
            monthFolderIDs[monthTitle] = monthID

            // Someone else may have made the day since the last load.
            if let child = try await client.confluenceFolderChildren(id: monthID)
                .first(where: { $0.type == "page" && $0.title == title }) {
                insert(PriorityDayRef(pageID: child.id, title: title, day: date, monthFolderID: monthID))
                errorMessage = "\(title) already exists."
                await select(child.id)
                return false
            }

            let document = ADFNode(type: "doc", content: items.isEmpty ? [] : [ADFNode.taskList(items)])
            let created = try await client.createConfluencePage(title: title, spaceID: spaceID, parentID: monthID, document: document)
            // Read it back so the page has its links and normalized body.
            let page = (try? await client.confluencePage(id: created.id)) ?? created
            insert(PriorityDayRef(pageID: page.id, title: title, day: date, monthFolderID: monthID))
            pages[page.id] = PriorityDay(page: page, day: date, siteURL: client.credentials.siteURL)
            shownIDs = [page.id]
            return true
        } catch {
            errorMessage = "Couldn't create \(title): \(error.localizedDescription)"
            return false
        }
    }

    private func insert(_ ref: PriorityDayRef) {
        index.removeAll { $0.title == ref.title }
        index.append(ref)
        index.sort { $0.title > $1.title }
    }

    // MARK: - Edits

    func setDone(_ done: Bool, item: PriorityItem, in day: PriorityDay) {
        // Flip it on screen right away; the save catches up.
        pages[day.pageID]?.document = day.document.replacingTaskItems { current, node in
            current.id == item.id ? node.settingTaskState(done: done) : node
        }
        write(page: day.pageID, itemID: item.id, message: done ? "Done: \(item.plainText.prefix(60))" : "Reopened: \(item.plainText.prefix(60))") { document in
            document.replacingTaskItems { current, node in
                current.id == item.id ? node.settingTaskState(done: done) : node
            }
        }
    }

    func setText(_ text: String, item: PriorityItem, in day: PriorityDay) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(item, from: day) }
        let content = ADFNode.inlineContent(from: trimmed, siteURL: siteURL)
        write(page: day.pageID, itemID: item.id, message: "Edited: \(trimmed.prefix(60))") { document in
            document.replacingTaskItems { current, node in
                current.id == item.id ? ADFNode(type: node.type, attrs: node.attrs, content: content) : node
            }
        }
    }

    func remove(_ item: PriorityItem, from day: PriorityDay) {
        write(page: day.pageID, itemID: item.id, message: "Removed: \(item.plainText.prefix(60))") { document in
            document.replacingTaskItems { current, node in current.id == item.id ? nil : node }
        }
    }

    /// Adds a priority to the end of a day's list.
    func add(_ text: String, to day: PriorityDay) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ADFNode.taskItem(ADFNode.inlineContent(from: trimmed, siteURL: siteURL))
        write(page: day.pageID, itemID: nil, message: "Added: \(trimmed.prefix(60))") { $0.appendingTaskItem([item]) }
        await lastWrite?.value
    }

    /// Moves an item from an earlier day onto today's page, when today has one.
    func moveToToday(_ item: PriorityItem, from day: PriorityDay) async {
        guard let today = todayRef, today.pageID != day.pageID else { return }
        let moved = ADFNode.taskItem(item.content, done: item.isDone, id: item.id)
        write(page: today.pageID, itemID: item.id, message: "Moved from \(day.title): \(item.plainText.prefix(50))") { $0.appendingTaskItem([moved]) }
        await lastWrite?.value
        guard errorMessage == nil else { return }
        remove(item, from: day)
    }

    /// Queues a change to a page: fetch, transform, save; again on a version
    /// conflict. The loaded copy is replaced by what was saved.
    private func write(page pageID: String, itemID: String?, message: String, transform: @escaping (ADFNode) -> ADFNode) {
        guard let client else { return }
        if let itemID { busyItemIDs.insert(itemID) }
        let previous = lastWrite
        lastWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if let itemID { busyItemIDs.remove(itemID) } }
            var attempts = 0
            while true {
                attempts += 1
                do {
                    let current = try await client.confluencePage(id: pageID)
                    let document = transform(current.document)
                    let saved = try await client.updateConfluencePage(id: pageID, title: current.title, version: current.version.number + 1, document: document, message: message)
                    pages[pageID]?.version = saved.version.number
                    pages[pageID]?.document = document
                    errorMessage = nil
                    return
                } catch let error as JiraError where error.isConflict && attempts < 3 {
                    continue
                } catch {
                    errorMessage = "Couldn't save to Confluence: \(error.localizedDescription)"
                    await reload()
                    return
                }
            }
        }
    }
}

private extension ADFNode {
    func settingTaskState(done: Bool) -> ADFNode {
        var attrs = self.attrs ?? [:]
        attrs["state"] = .string(done ? "DONE" : "TODO")
        return ADFNode(type: type, text: text, attrs: attrs, marks: marks, content: content)
    }
}
