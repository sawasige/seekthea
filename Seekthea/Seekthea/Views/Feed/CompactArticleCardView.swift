import SwiftUI

struct CompactArticleCardView: View {
    let article: Article
    var showScore: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル
            if let imageURL = article.displayImageURL {
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
                    let site = article.source?.siteURL ?? URL(string: "https://\(article.articleURL.host() ?? "")") ?? article.articleURL
                    SourceThumbnailView(siteURL: site, size: 14)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if showScore && article.relevanceScore > 0.1 {
                        Text("\(Int(article.relevanceScore * 100))%")
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(radius: 2)
                    .padding(4)
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
}

// MARK: - Compact Image

private struct CompactImageView: View {
    let url: URL
    @State private var failed = false

    var body: some View {
        if failed {
            EmptyView()
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
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
