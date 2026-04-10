import SwiftUI

/// ソースのサムネイル表示（favicon → OG画像の順にフォールバック）
struct SourceThumbnailView: View {
    let siteURL: URL
    var ogImageURL: URL? = nil
    var size: CGFloat = 56

    @State private var fetchedOGImageURL: URL?

    private var displayOGImage: URL? {
        ogImageURL ?? fetchedOGImageURL ?? PresetOGImageCache.get(for: siteURL)
    }

    private var faviconURL: URL? {
        guard let host = siteURL.host() else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))

            if let ogImage = displayOGImage {
                AsyncImage(url: ogImage) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        faviconFallback
                    }
                }
            } else {
                faviconFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: siteURL) {
            // OG画像が未取得なら非同期で取得
            if ogImageURL == nil && fetchedOGImageURL == nil && PresetOGImageCache.get(for: siteURL) == nil {
                if let fetched = await FeedFetcher.fetchOGImage(from: siteURL) {
                    fetchedOGImageURL = fetched
                    PresetOGImageCache.set(fetched, for: siteURL)
                }
            }
        }
    }

    @ViewBuilder
    private var faviconFallback: some View {
        if let favicon = faviconURL {
            AsyncImage(url: favicon) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit).padding(size * 0.25)
                default:
                    Image(systemName: "globe")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }
}
