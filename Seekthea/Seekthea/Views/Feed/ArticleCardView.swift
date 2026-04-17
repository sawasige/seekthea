import SwiftUI

struct ArticleCardView: View {
    let article: Article
    var showScore: Bool = false
    var onTapSource: (() -> Void)? = nil

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
            if let imageURL = article.displayImageURL {
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
                    let site = article.source?.siteURL ?? URL(string: "https://\(article.articleURL.host() ?? "")") ?? article.articleURL
                    Button {
                        onTapSource?()
                    } label: {
                        HStack(spacing: 5) {
                            SourceThumbnailView(siteURL: site, size: faviconSize)
                            if !name.isEmpty {
                                Text(name)
                                    .font(metaFont)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(onTapSource == nil)

                    Spacer()

                    if showScore && article.relevanceScore > 0.1 {
                        Text("\(Int(article.relevanceScore * 100))%")
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 2)
                    .padding(8)
            }
        }
        .task {
            if article.displayImageURL == nil {
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
    @State private var failed = false

    var body: some View {
        if failed {
            EmptyView()
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Color.clear.onAppear { failed = true }
                        default:
                            Color.gray.opacity(0.1)
                        }
                    }
                }
                .clipped()
        }
    }
}

