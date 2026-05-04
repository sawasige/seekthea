import SwiftUI

struct ArticleCardView: View {
    let article: Article
    /// 親で article.displayImageURL を読むことで Observation を確実に親に走らせる
    /// （reused view 内部での observation が伝わらないケースの保険）
    let displayImageURL: URL?
    var showScore: Bool = false

    #if os(macOS)
    private let titleFont: Font = .title3.weight(.semibold)
    private let descFont: Font = .body
    private let metaFont: Font = .subheadline
    private let badgeFont: Font = .subheadline
    private let imageHeight: CGFloat = 180
    private let faviconSize: CGFloat = 18
    #else
    private let titleFont: Font = .body.weight(.semibold)
    private let descFont: Font = .subheadline
    private let metaFont: Font = .caption
    private let badgeFont: Font = .caption
    private let imageHeight: CGFloat = 160
    private let faviconSize: CGFloat = 16
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル画像（URLがある場合のみ）
            if let imageURL = displayImageURL {
                ArticleImageView(url: imageURL, height: imageHeight)
            }

            VStack(alignment: .leading, spacing: 8) {
                // タイトル
                Text(article.title)
                    .font(titleFont)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // 要約 or 説明文
                if let description = article.cardDescription {
                    Text(description)
                        .font(descFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                // メタ情報
                HStack(spacing: 6) {
                    let name = article.sourceName.isEmpty ? article.articleURL.host() ?? "" : article.sourceName
                    // article.source.siteURL を読むと Source オブジェクトの全更新（lastFetchedAt等）が
                    // SwiftUI の observation 経由で全カードの再評価を引き起こす。
                    // favicon は host 単位なので article URL の host から組み立てれば十分
                    let site = URL(string: "https://\(article.articleURL.host() ?? "")") ?? article.articleURL
                    SourceThumbnailView(siteURL: site, size: faviconSize)
                    if !name.isEmpty {
                        Text(name)
                            .font(metaFont)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if showScore && article.relevanceScore > 0 {
                        Text("\(max(1, Int(round(article.relevanceScore * 100))))%")
                            .font(metaFont)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }

                    if let date = article.publishedAt {
                        Text(Self.relativeString(from: date))
                            .font(metaFont)
                            .foregroundStyle(.tertiary)
                    }
                }

                // カテゴリタグ
                if !article.categories.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(article.categories, id: \.self) { cat in
                            Text(cat)
                                .font(badgeFont)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                } else if article.classificationFailed {
                    Text(article.classificationRefused ? "対象外" : "分類失敗")
                        .font(badgeFont)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .clipped()
        .opacity(article.isRead ? 0.6 : 1.0)
        .overlay(alignment: .topTrailing) {
            if article.isRead {
                Text("既読")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
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

    static func relativeString(from date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "たった今" }
        if interval < 3600 { return "\(Int(interval / 60))分前" }
        if interval < 86400 { return "\(Int(interval / 3600))時間前" }
        if interval < 604800 { return "\(Int(interval / 86400))日前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

// MARK: - Article Image (failure時に非表示)

private struct ArticleImageView: View {
    let url: URL
    let height: CGFloat
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        if failed {
            EmptyView()
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
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

