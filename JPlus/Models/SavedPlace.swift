import Foundation

/// What the main window was showing, saved so the app reopens there: the
/// sidebar item, plus the issues and versions opened on top of it.
struct SavedPlace: Codable, Equatable {
    enum Screen: Codable, Equatable {
        case myIssues, mentions, account, search, versions, newTicket, priorities
        case issue(String)
        /// Saved by id and looked up again on launch, so its counts are current.
        case version(projectKey: String, versionID: String)
    }

    var sidebar: Screen
    /// Bottom first.
    var stack: [Screen]

    /// Deeper stacks keep only their top screens.
    static let maxStackDepth = 20
}
