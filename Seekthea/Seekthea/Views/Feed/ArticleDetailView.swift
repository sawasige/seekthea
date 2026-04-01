import SwiftUI
import SwiftData

struct ArticleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let article: Article

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ヘッダー画像
                if let imageURL = article.displayImageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fit)
                        default:
                            Color.gray.opacity(0.2)
                                .frame(height: 200)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // タイトル
                Text(article.title)
                    .font(.title2)
                    .fontWeight(.bold)

                // ソース + 日時
                HStack {
                    if let source = article.source {
                        Label(source.name, systemImage: "newspaper")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let date = article.publishedAt {
                        Text(date, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // AI要約
                if let summary = article.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AI要約", systemImage: "sparkles")
                            .font(.headline)
                        Text(summary)
                            .font(.body)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // キーワード
                if !article.keywords.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(article.keywords, id: \.self) { keyword in
                            Text(keyword)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }

                // 説明文
                if let desc = article.ogDescription ?? article.leadText {
                    Text(desc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                // 元記事リンク
                Link(destination: article.articleURL) {
                    Label("元記事を読む", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                ShareLink(item: article.articleURL) {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle("詳細")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    article.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: article.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(article.isFavorite ? .yellow : .secondary)
                }
            }
        }
        .onAppear {
            if !article.isRead {
                article.isRead = true
                try? modelContext.save()
            }
        }
    }
}

// MARK: - Simple FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
