import UIKit
import UniformTypeIdentifiers

// Share Extension用のApp Group定数と共有ストア
// メインアプリのAppGroupConstants.swiftと同じ定義を維持すること
private enum SharedConstants {
    static let suiteName = "group.com.himatsubu.Seekthea"
    static let pendingSourcesKey = "pendingSources"
}

private struct PendingSource: Codable {
    let url: URL
    let detectedFeedURL: URL?
    let title: String?
    let addedAt: Date
}

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedURL()
    }

    private func handleSharedURL() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            close()
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                        guard let url = data as? URL else {
                            self?.close()
                            return
                        }
                        Task {
                            await self?.processURL(url)
                        }
                    }
                    return
                }
            }
        }
        close()
    }

    private func processURL(_ url: URL) async {
        let feedURL = await detectFeed(from: url)

        let pending = PendingSource(
            url: url,
            detectedFeedURL: feedURL,
            title: url.host(),
            addedAt: Date()
        )

        // App Group共有コンテナに保存
        if let defaults = UserDefaults(suiteName: SharedConstants.suiteName) {
            var sources: [PendingSource] = []
            if let data = defaults.data(forKey: SharedConstants.pendingSourcesKey),
               let existing = try? JSONDecoder().decode([PendingSource].self, from: data) {
                sources = existing
            }
            sources.append(pending)
            if let encoded = try? JSONEncoder().encode(sources) {
                defaults.set(encoded, forKey: SharedConstants.pendingSourcesKey)
            }
        }

        await MainActor.run {
            close()
        }
    }

    private func detectFeed(from siteURL: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: siteURL),
              let html = String(data: data, encoding: .utf8) else { return nil }

        let patterns = [
            "<link[^>]+type=\"application/rss\\+xml\"[^>]+href=\"([^\"]*)\"",
            "<link[^>]+type=\"application/atom\\+xml\"[^>]+href=\"([^\"]*)\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/rss\\+xml\"",
            "<link[^>]+href=\"([^\"]*)\"[^>]+type=\"application/atom\\+xml\"",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let href = String(html[range])
                if let feedURL = URL(string: href, relativeTo: siteURL)?.absoluteURL {
                    return feedURL
                }
            }
        }
        return nil
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
