import SwiftUI
import SwiftData

struct SourcePreviewView: View {
    enum Mode {
        case preset(PresetSource)
        case registered(Source)
    }

    let mode: Mode
    let modelContainer: ModelContainer
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SourcesViewModel?
    @State private var articles: [PreviewArticle] = []
    @State private var isLoading = true

    private var sourceName: String {
        switch mode {
        case .preset(let p): return p.name
        case .registered(let s): return s.name
        }
    }

    private var sourceCategory: String {
        switch mode {
        case .preset(let p): return p.category
        case .registered(let s): return s.category
        }
    }

    private var feedURL: URL {
        switch mode {
        case .preset(let p): return p.feedURL
        case .registered(let s): return s.feedURL
        }
    }

    private var siteURL: URL {
        switch mode {
        case .preset(let p): return p.siteURL
        case .registered(let s): return s.siteURL
        }
    }

    private var isRegistered: Bool {
        if case .registered = mode { return true }
        if case .preset(let p) = mode, let vm = viewModel {
            return vm.isAdded(p)
        }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // ヘッダー
                    HStack(spacing: 12) {
                        SourceThumbnailView(siteURL: siteURL, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceName)
                                .font(.title3.weight(.semibold))
                            Text(sourceCategory)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.tint.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            Link(siteURL.host() ?? "", destination: siteURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)

                    Divider()

                    // 記事一覧
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    } else if articles.isEmpty {
                        Text("記事が取得できませんでした")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(articles) { article in
                                previewRow(article)
                                Divider()
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("プレビュー")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    actionButton
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = SourcesViewModel(modelContainer: modelContainer)
                }
                articles = await viewModel?.previewFeed(url: feedURL) ?? []
                isLoading = false
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch mode {
        case .preset(let preset):
            if isRegistered {
                Text("追加済み").foregroundStyle(.secondary)
            } else {
                Button("追加") {
                    viewModel?.addPresetSource(preset)
                    dismiss()
                }
            }
        case .registered(let source):
            Button("削除", role: .destructive) {
                viewModel?.deleteSource(source)
                dismiss()
            }
        }
    }

    private func previewRow(_ article: PreviewArticle) -> some View {
        PreviewArticleRow(article: article)
    }
}

private struct PreviewArticleRow: View {
    let article: PreviewArticle
    @State private var resolvedImageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let imageURL = resolvedImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let description = article.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let date = article.publishedAt {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            if let imageURL = article.imageURL {
                resolvedImageURL = imageURL
            } else {
                resolvedImageURL = await FeedFetcher.fetchOGImage(from: article.link)
            }
        }
    }
}
