import Foundation

/// 自前の pre-prompt（「Seekthea を使ってみていかがですか？」）→
/// 「気に入っている」と答えたユーザーにのみ Apple 公式のレビュー依頼シートを出すパターン。
/// 「もう少し」と答えたユーザーはサポートページに誘導する。
enum ReviewPromptManager {
    private enum Keys {
        static let firstLaunchDate = "reviewPromptFirstLaunchDate"
        static let lastShownVersion = "reviewPromptLastShownVersion"
        static let lastShownDate = "reviewPromptLastShownDate"
        static let lastDeclinedDate = "reviewPromptLastDeclinedDate"
    }

    private static let minDaysSinceFirstLaunch: TimeInterval = 7
    private static let minReadCount = 20
    private static let cooldownAfterPrompt: TimeInterval = 60
    private static let cooldownAfterDecline: TimeInterval = 180

    static func recordFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.double(forKey: Keys.firstLaunchDate) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.firstLaunchDate)
        }
    }

    static func shouldShowPrompt(readCount: Int) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date()

        let firstLaunchTimestamp = defaults.double(forKey: Keys.firstLaunchDate)
        guard firstLaunchTimestamp > 0 else { return false }
        let firstLaunchDate = Date(timeIntervalSince1970: firstLaunchTimestamp)
        guard now.timeIntervalSince(firstLaunchDate) >= minDaysSinceFirstLaunch * 86400 else { return false }

        guard readCount >= minReadCount else { return false }

        let currentVersion = appVersion
        if defaults.string(forKey: Keys.lastShownVersion) == currentVersion { return false }

        let lastShownTimestamp = defaults.double(forKey: Keys.lastShownDate)
        if lastShownTimestamp > 0 {
            let lastShownDate = Date(timeIntervalSince1970: lastShownTimestamp)
            guard now.timeIntervalSince(lastShownDate) >= cooldownAfterPrompt * 86400 else { return false }
        }

        let lastDeclinedTimestamp = defaults.double(forKey: Keys.lastDeclinedDate)
        if lastDeclinedTimestamp > 0 {
            let lastDeclinedDate = Date(timeIntervalSince1970: lastDeclinedTimestamp)
            guard now.timeIntervalSince(lastDeclinedDate) >= cooldownAfterDecline * 86400 else { return false }
        }

        return true
    }

    static func markShown() {
        let defaults = UserDefaults.standard
        defaults.set(appVersion, forKey: Keys.lastShownVersion)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastShownDate)
    }

    static func markDeclined() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastDeclinedDate)
        markShown()
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    #if DEBUG
    static let debugTriggerNotification = Notification.Name("ReviewPromptManager.debugTrigger")

    struct DebugSnapshot {
        let firstLaunchDate: Date?
        let lastShownVersion: String?
        let lastShownDate: Date?
        let lastDeclinedDate: Date?
    }

    static func debugSnapshot() -> DebugSnapshot {
        let defaults = UserDefaults.standard
        return DebugSnapshot(
            firstLaunchDate: defaults.double(forKey: Keys.firstLaunchDate) > 0 ? Date(timeIntervalSince1970: defaults.double(forKey: Keys.firstLaunchDate)) : nil,
            lastShownVersion: defaults.string(forKey: Keys.lastShownVersion),
            lastShownDate: defaults.double(forKey: Keys.lastShownDate) > 0 ? Date(timeIntervalSince1970: defaults.double(forKey: Keys.lastShownDate)) : nil,
            lastDeclinedDate: defaults.double(forKey: Keys.lastDeclinedDate) > 0 ? Date(timeIntervalSince1970: defaults.double(forKey: Keys.lastDeclinedDate)) : nil
        )
    }

    static func debugReset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.firstLaunchDate)
        defaults.removeObject(forKey: Keys.lastShownVersion)
        defaults.removeObject(forKey: Keys.lastShownDate)
        defaults.removeObject(forKey: Keys.lastDeclinedDate)
    }
    #endif
}
