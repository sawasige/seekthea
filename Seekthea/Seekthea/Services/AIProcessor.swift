import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

/// AI処理結果（Guided Generation用）
@Generable
struct ArticleAnalysis {
    @Guide(description: "カテゴリ名: テクノロジー, ビジネス, 政治, 社会, スポーツ, エンタメ, サイエンス, ライフ, 開発, プロダクト, トレンド")
    var category: String
    @Guide(description: "100文字程度の日本語要約（3文以内）")
    var summary: String
    @Guide(description: "関連キーワード（最大3つ）")
    var keywords: [String]
}
#endif

/// Apple Intelligence によるオンデバイスAI処理
@MainActor
class AIProcessor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }

    /// 記事を分析（要約・カテゴリ分類・キーワード抽出）
    func analyze(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article,
              !article.isAIProcessed else { return }

        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession()
            let prompt = """
            以下のニュース記事を分析してください。

            \(article.textForAI)
            """

            let response = try await session.respond(to: prompt, generating: ArticleAnalysis.self)
            let analysis = response.content
            article.summary = analysis.summary
            article.aiCategory = analysis.category
            article.keywords = analysis.keywords
            article.isAIProcessed = true
            try? context.save()
        } catch {
            applyFallback(article: article)
            try? context.save()
        }
        #else
        applyFallback(article: article)
        try? context.save()
        #endif
    }

    /// 未処理記事をバッチ処理
    func processBatch(articleIDs: [PersistentIdentifier]) async {
        for id in articleIDs {
            await analyze(articleID: id)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func applyFallback(article: Article) {
        if let source = article.source {
            article.aiCategory = source.category
        }
        article.isAIProcessed = true
    }
}
