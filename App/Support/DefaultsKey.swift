// The app's own preferences, beyond HomeClerkSettings: every key in one place, so two features
// can't pick the same name and it's clear what HomeClerk keeps in its defaults.

enum DefaultsKey {
    // Setup and behavior
    static let setupComplete = "SetupComplete"
    /// The What's New edition last shown.
    static let whatsNewSeen = "WhatsNewSeen"
    static let startOllama = "StartOllama"
    static let indexInSpotlight = "IndexInSpotlight"
    static let weeklyDigest = "WeeklyDigest"
    static let lastWeeklyDigest = "LastWeeklyDigest"
    static let dueSoonNotices = "DueSoonNotices"
    /// Bills already given a due-soon notice, as "path|due date".
    static let noticedDue = "NoticedDue"
    static let mailRuleInbox = "MailRuleInbox"
    /// "I back up another way" — Tidy Up stops mentioning backups.
    static let backupAcknowledged = "BackupAcknowledged"
    /// Warned once a month as Claude spending nears the limit.
    static func claudeLimitWarned(month: String) -> String { "ClaudeLimitWarned-\(month)" }

    // Remembered answers and history
    static let keepAnyway = "KeepAnyway"
    static let leaveAsIs = "LeaveAsIs"
    static let savedSearches = "SavedSearches"
    static let modelTimings = "ModelTimings"

    // Where you left the window
    static let selectedSection = "SelectedSection"
    static let reviewInspector = "ReviewInspector"
    static let reviewListWidth = "ReviewListWidth"
    static let filedInspector = "FiledInspector"
    static let filedListWidth = "FiledListWidth"
    static let tidyMode = "TidyMode"
    /// Settings ▸ Rules lists folder rules and keep periods by name instead of by priority.
    static let rulesByName = "RulesByName"
    static let upcomingShowsPaid = "UpcomingShowsPaid"
    static let spendingGrouping = "SpendingGrouping"
    static let spendingRange = "SpendingRange"
}
