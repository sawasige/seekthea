import SwiftUI

struct ArticleCardView: View {
    let article: Article
    var showScore: Bool = false

    #if os(macOS)
    private let titleFont: Font = .title3.weight(.semibold)
    private let descFont: Font = .body
    private let metaFont: Font = .subheadline
    private let badgeFont: Font = .subheadline
    private let imageHeight: CGFloat = 180
    private let faviconSize: CGFloat = 16
    #else
    private let titleFont: Font = .body.weight(.semibold)
    private let descFont: Font = .subheadline
    private let metaFont: Font = .caption
    private let badgeFont: Font = .caption
    private let imageHeight: CGFloat = 160
    private let faviconSize: CGFloat = 12
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // サムネイル画像（URLがある場合のみ）
            if let imageURL = article.displayImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: imageHeight)
                            .clipped()
                    case .empty:
                        // 読み込み中
                        Color.gray.opacity(0.1)
                            .frame(height: imageHeight)
                    case .failure:
                        // 失敗 → 非表示
                        EmptyView()
                    @unknown default:
                        EmptyView()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                // タイトル
                Text(article.title)
                    .font(titleFont)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // 要約 or 説明文
                if let description = article.displayDescription {
                    MarkdownText(
                        text: description,
                        font: descFont,
                        boldFont: descFont.bold(),
                        boldColor: .primary
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                }

                // メタ情報
                HStack(spacing: 6) {
                    if let faviconData = article.siteFaviconData,
                       let img = platformImage(from: faviconData) {
                        Image(platformImage: img)
                            .resizable()
                            .frame(width: faviconSize, height: faviconSize)
                    }

                    let name = article.sourceName.isEmpty ? article.articleURL.host() ?? "" : article.sourceName
                    if !name.isEmpty {
                        Text(name)
                            .font(metaFont)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if showScore && article.relevanceScore > 0.1 {
                        Text("\(Int(article.relevanceScore * 100))%")
                            .font(metaFont)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }

                    if let date = article.publishedAt {
                        Text(date, style: .relative)
                            .font(metaFont)
                            .foregroundStyle(.tertiary)
                    }
                }

                // カテゴリバッジ
                if !article.categories.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(article.categories, id: \.self) { cat in
                            Text(cat)
                                .font(badgeFont)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(minHeight: 120)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .clipped()
        .opacity(article.isRead ? 0.7 : 1.0)
        .task {
            if article.displayImageURL == nil {
                if let ogImage = await FeedFetcher.fetchOGImage(from: article.articleURL) {
                    article.ogImageURL = ogImage
                }
            }
        }
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.15))
    }
}

// MARK: - Platform Image Helpers

#if os(macOS)
import AppKit
private func platformImage(from data: Data) -> NSImage? { NSImage(data: data) }
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
private func platformImage(from data: Data) -> UIImage? { UIImage(data: data) }
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
