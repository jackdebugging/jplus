import Foundation
import Observation

/// Loads the recent day pages under the Daily Priorities folder and writes
/// edits back. Every write re-reads the page first and saves over its
/// current version, retrying once if someone else saved in between, so two
/// people ticking boxes at once don't lose each other's changes.
@Observable
final class PrioritiesModel {
    private(set) var days: [PriorityDay] = []
    /// The root folder, once loaded.
    private(set) var folder: ConfluenceFolder?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Ids of items with a save in flight.
    private(set) var busyItemIDs: Set<String> = []
    /// True while today's page is being created.
    private(set) var isCreatingToday = false
    /// How many recent days to show; grows with Show More.
    private(set) var dayLimit = PrioritiesModel.dayPageSize

    static let dayPageSize = 14

    private var client: JiraClient?
    private var folderID = ""
    private var spaceID: String?
    /// Month folder titles → ids, from the last load.
    private var monthFolderIDs: [String: String] = [:]
    /// Writes run one after another, so edits to the same page don't race.
    private var lastWrite: Task<Void, Never>?
    private var generation = 0

    private var siteURL: URL { client?.credentials.siteURL ?? URL(string: "https://atlassian.net")! }

    var todayTitle: String { PriorityNaming.dayTitle(for: Date()) }
    var today: PriorityDay? { days.first { $0.title == todayTitle } }
    var hasMore: Bool { days.count >= dayLimit }

    // MARK: - Loading

    func load(client: JiraClient, folderID: String) async {
        self.client = client
        self.folderID = folderID
        generation += 1
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if myGeneration == generation { isLoading = false; hasLoaded = true } }
        do {
            async let folder = client.confluenceFolder(id: folderID)
            let children = try await client.confluenceFolderChildren(id: folderID)
            let root = try await folder
            self.folder = root
            spaceID = root.spaceId
            let months = children
                .filter { $0.type == "folder" && PriorityNaming.isMonthTitle($0.title) }
                .sorted { $0.title > $1.title }
            monthFolderIDs = Dictionary(months.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })

            // Newest months first, until enough days are found.
            var pages: [ConfluenceChild] = []
            for month in months where pages.count < dayLimit {
                let days = try await client.confluenceFolderChildren(id: month.id)
                    .filter { $0.type == "page" && PriorityNaming.isDayTitle($0.title) }
                pages += days
            }
            let wanted = pages.sorted { $0.title > $1.title }.prefix(dayLimit)
            let siteURL = client.credentials.siteURL
            let loaded = try await withThrowingTaskGroup(of: ConfluencePage.self) { group in
                for child in wanted {
                    group.addTask { try await client.confluencePage(id: child.id) }
                }
                var pages: [ConfluencePage] = []
                for try await page in group { pages.append(page) }
                return pages
            }
            guard myGeneration == generation else { return }
            days = loaded
                .compactMap { page in PriorityNaming.day(fromTitle: page.title).map { PriorityDay(page: page, day: $0, siteURL: siteURL) } }
                .sorted { $0.title > $1.title }
        } catch {
            guard myGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let client else { return }
        await load(client: client, folderID: folderID)
    }

    func showMore() async {
        dayLimit += Self.dayPageSize
        await reload()
    }

    // MARK: - Edits

    func setDone(_ done: Bool, item: PriorityItem, in day: PriorityDay) {
        // Flip it on screen right away; the save catches up.
        if let index = days.firstIndex(of: day) {
            days[index].document = day.document.replacingTaskItems { current, node in
                current.id == item.id ? node.settingTaskState(done: done) : node
            }
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

    /// Adds a priority to today's page, creating the page (and its month
    /// folder) when today hasn't started yet.
    func add(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ADFNode.taskItem(ADFNode.inlineContent(from: trimmed, siteURL: siteURL))
        await append(items: [item], message: "Added: \(trimmed.prefix(60))")
    }

    /// Moves an item from an earlier day onto today's page.
    func moveToToday(_ item: PriorityItem, from day: PriorityDay) async {
        guard day.title != todayTitle else { return }
        await append(items: [ADFNode.taskItem(item.content, done: item.isDone, id: item.id)], message: "Moved from \(day.title): \(item.plainText.prefix(50))")
        guard errorMessage == nil else { return }
        remove(item, from: day)
    }

    /// Copies every unfinished item from the most recent earlier day onto today.
    func carryOverOpenItems() async {
        guard let previous = days.first(where: { $0.title != todayTitle }) else { return }
        let open = previous.items.filter { !$0.isDone }
        let existing = Set(today?.items.map(\.id) ?? [])
        let items = open.filter { !existing.contains($0.id) }.map { ADFNode.taskItem($0.content, id: $0.id) }
        guard !items.isEmpty else { return }
        await append(items: items, message: "Carried over \(items.count) from \(previous.title)")
    }

    private func append(items: [ADFNode], message: String) async {
        if let today {
            write(page: today.pageID, itemID: nil, message: message) { $0.appendingTaskItem(items) }
            await lastWrite?.value
        } else {
            await createToday(with: items)
        }
    }

    private func createToday(with items: [ADFNode]) async {
        guard let client, let spaceID else { return }
        isCreatingToday = true
        defer { isCreatingToday = false }
        errorMessage = nil
        do {
            let now = Date()
            let monthTitle = PriorityNaming.monthTitle(for: now)
            let monthID: String
            if let known = monthFolderIDs[monthTitle] {
                monthID = known
            } else {
                // Someone else may have started the month since the last load.
                let children = try await client.confluenceFolderChildren(id: folderID)
                if let found = children.first(where: { $0.type == "folder" && $0.title == monthTitle }) {
                    monthID = found.id
                } else {
                    monthID = try await client.createConfluenceFolder(title: monthTitle, spaceID: spaceID, parentID: folderID).id
                }
                monthFolderIDs[monthTitle] = monthID
            }
            let document = ADFNode(type: "doc", content: [ADFNode.taskList(items)])
            let page = try await client.createConfluencePage(title: todayTitle, spaceID: spaceID, parentID: monthID, document: document)
            // Read it back so the page has its links and normalized body.
            let fresh = (try? await client.confluencePage(id: page.id)) ?? page
            let day = PriorityDay(page: fresh, day: now, siteURL: client.credentials.siteURL)
            days.removeAll { $0.title == day.title }
            days.insert(day, at: 0)
        } catch {
            if let jiraError = error as? JiraError, case .http(400, _) = jiraError, let today = await findToday() {
                // Title already taken: today's page was created elsewhere. Add to it instead.
                days.insert(today, at: 0)
                write(page: today.pageID, itemID: nil, message: "Added") { $0.appendingTaskItem(items) }
                await lastWrite?.value
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func findToday() async -> PriorityDay? {
        guard let client, let monthID = monthFolderIDs[PriorityNaming.monthTitle(for: Date())],
              let children = try? await client.confluenceFolderChildren(id: monthID),
              let child = children.first(where: { $0.type == "page" && $0.title == todayTitle }),
              let page = try? await client.confluencePage(id: child.id)
        else { return nil }
        return PriorityDay(page: page, day: Date(), siteURL: client.credentials.siteURL)
    }

    /// Queues a change to a page: fetch, transform, save; once more on a
    /// version conflict. The page on screen is replaced by what was saved.
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
                    if let index = days.firstIndex(where: { $0.pageID == pageID }) {
                        days[index].version = saved.version.number
                        days[index].document = document
                    }
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
