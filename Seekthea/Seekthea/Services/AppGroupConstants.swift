import Foundation

enum AppGroupConstants {
    static let suiteName = "group.com.himatsubu.Seekthea"
    static let pendingSourcesKey = "pendingSources"
}

struct PendingSource: Codable {
    let url: URL
    let detectedFeedURL: URL?
    let title: String?
    let addedAt: Date
}

/// App Group経由で共有されるpending sourcesの読み書き
enum PendingSourcesStore {
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupConstants.suiteName)
    }

    static func save(_ sources: [PendingSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        sharedDefaults?.set(data, forKey: AppGroupConstants.pendingSourcesKey)
    }

    static func load() -> [PendingSource] {
        guard let data = sharedDefaults?.data(forKey: AppGroupConstants.pendingSourcesKey),
              let sources = try? JSONDecoder().decode([PendingSource].self, from: data) else {
            return []
        }
        return sources
    }

    static func clear() {
        sharedDefaults?.removeObject(forKey: AppGroupConstants.pendingSourcesKey)
    }

    static func append(_ source: PendingSource) {
        var current = load()
        current.append(source)
        save(current)
    }
}
