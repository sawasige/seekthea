import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

/// AI処理結果（Guided Generation用）
@Generable
struct ArticleAnalysis {
    @Guide(description: "カテゴリ名: テクノロジー, ビジネス, 政治, 社会, スポーツ, エンタメ, サイエンス, ライフ, 開発, プロダクト, トレンド")
    var category: String
    @Guide(description: "200〜400文字の日本語要約。重要なキーワードやフレーズは**太字**で囲む")
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

            タイトルと概要から、以下を生成してください:
            - category: 最も適切なカテゴリ1つ
            - summary: 記事の要点を200〜400文字で日本語要約。重要なキーワードやフレーズは**太字マーカー**で囲んでください（例: **AI技術**が急速に発展している）
            - keywords: 重要キーワード（最大5つ）
            """

            let response = try await session.respond(to: prompt, generating: ArticleAnalysis.self)
            let analysis = response.content

            article.summary = analysis.summary
            article.aiCategory = analysis.category
            article.keywords = analysis.keywords
            article.isAIProcessed = true
            try? context.save()
        } catch {
            print("[AI] Failed: \(article.title) - \(error)")
            applyFallback(article: article)
            try? context.save()
        }
        #else
        applyFallback(article: article)
        try? context.save()
        #endif
    }

    /// 未処理記事をバッチ処理
    private var isProcessing = false

    func processBatch(articleIDs: [PersistentIdentifier]) async {
        guard !isProcessing else {
            print("[AI] Already processing, skipping")
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        print("[AI] Processing \(articleIDs.count) articles")
        var processed = 0
        for id in articleIDs {
            await analyze(articleID: id)
            processed += 1
            if processed % 10 == 0 {
                print("[AI] Progress: \(processed)/\(articleIDs.count)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("[AI] Batch complete: \(processed) articles")
    }

    private func applyFallback(article: Article) {
        // 抽出本文の冒頭を要約代わりに使用
        if let body = article.extractedBody, !body.isEmpty {
            article.summary = String(body.prefix(200))
        } else if let ogDesc = article.ogDescription, !ogDesc.isEmpty {
            article.summary = ogDesc
        }
        if let source = article.source {
            article.aiCategory = source.category
        }
        article.isAIProcessed = true
    }
}
