import SwiftUI

struct ArticleCardView: View {
    let article: Article
    var showScore: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // サムネイル
            if let imageURL = article.displayImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholderImage
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                // タイトル
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)

                // 要約 or 説明文
                if let description = article.displayDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !article.isAIProcessed && !article.isEnriched {
                    // shimmer placeholder
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 32)
                }

                HStack(spacing: 6) {
                    // ソースfavicon
                    if let faviconData = article.siteFaviconData,
                       let uiImage = platformImage(from: faviconData) {
                        Image(platformImage: uiImage)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }

                    // ソース名
                    if let source = article.source {
                        Text(source.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // カテゴリバッジ
                    if let category = article.aiCategory {
                        Text(category)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // 興味スコア
                    if showScore && article.relevanceScore > 0.1 {
                        Text("\(Int(article.relevanceScore * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }

                    // 公開日時
                    if let date = article.publishedAt {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(article.isRead ? 0.6 : 1.0)
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
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
