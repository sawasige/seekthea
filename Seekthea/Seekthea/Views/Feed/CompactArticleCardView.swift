import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

struct CompactArticleCardView: View {
    let article: Article
    /// 親で article.displayImageURL を読むことで Observation を確実に親に走らせる
    let displayImageURL: URL?
    var showScore: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル
            if let imageURL = displayImageURL {
                CompactImageView(url: imageURL)
            }

            VStack(alignment: .leading, spacing: 4) {
                // タイトル
                Text(article.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // ソース名 + 日時
                HStack(spacing: 4) {
                    let name = article.sourceName.isEmpty ? article.articleURL.host() ?? "" : article.sourceName
                    // article.source.siteURL を読むと Source オブジェクトの全更新（lastFetchedAt等）が
                    // SwiftUI の observation 経由で全カードの再評価を引き起こす。
                    // favicon は host 単位なので article URL の host から組み立てれば十分
                    let site = URL(string: "https://\(article.articleURL.host() ?? "")") ?? article.articleURL
                    SourceThumbnailView(siteURL: site, size: 14)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if showScore && article.relevanceScore > 0 {
                        Text("\(max(1, Int(round(article.relevanceScore * 100))))%")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }

                    if let date = article.publishedAt {
                        Text(ArticleCardView.relativeString(from: date))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // カテゴリタグ
                if !article.categories.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(article.categories.prefix(2), id: \.self) { cat in
                            Text(cat)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        if article.categories.count > 2 {
                            Text("+\(article.categories.count - 2)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if article.classificationFailed {
                    Text("未分類")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .clipped()
        .opacity(article.isRead ? 0.6 : 1.0)
        .overlay(alignment: .topTrailing) {
            if article.isRead {
                Text("既読")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
        }
        .task {
            if displayImageURL == nil {
                if let ogImage = await FeedFetcher.fetchOGImage(from: article.articleURL) {
                    article.ogImageURL = ogImage
                }
            }
        }
    }
}

// MARK: - Compact Image

private struct CompactImageView: View {
    let url: URL
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        if failed {
            EmptyView()
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .overlay {
                    if let image {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
                .clipped()
                .task(id: url) {
                    image = await RemoteImageLoader.load(from: url, onFail: { failed = true })
                }
        }
    }
}

/// AsyncImage は SwiftUI の再描画で cancel されて固まりがちなので
/// 自前で URLSession で読み込む（.task(id:) は view 再描画では
/// cancel されないので、view identity が安定していれば最後まで完走する）
enum RemoteImageLoader {
    static func load(from url: URL, onFail: @MainActor () -> Void) async -> PlatformImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let img = PlatformImage(data: data) else {
                await MainActor.run { onFail() }
                return nil
            }
            return img
        } catch {
            // cancel は失敗扱いしない
            if (error as NSError).code != NSURLErrorCancelled {
                await MainActor.run { onFail() }
            }
            return nil
        }
    }
}
