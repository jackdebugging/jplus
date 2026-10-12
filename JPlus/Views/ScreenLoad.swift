import SwiftUI

extension View {
    /// Like `.task`, for loading what a screen shows: the load runs to the end
    /// even if SwiftUI cancels the view's task. On an iPhone the slide-in
    /// that opens a screen can cancel its first task, which left lists
    /// spinning with nothing to restart them. Use plain `.task` for work
    /// that should stop, such as a search a newer keystroke replaces.
    func loadTask(_ action: @escaping @MainActor () async -> Void) -> some View {
        task { await Task { await action() }.value }
    }

    /// `loadTask` that runs again when `id` changes. An earlier run still
    /// finishes, so the action must ignore results for an id that's no
    /// longer current.
    func loadTask<ID: Equatable>(id: ID, _ action: @escaping @MainActor () async -> Void) -> some View {
        task(id: id) { await Task { await action() }.value }
    }
}
