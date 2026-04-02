import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

/// AI処理結果（Guided Generation用）
@Generable
struct ArticleAnalysis {
    @Guide(description: "カテゴリ名")
    var category: String
    @Guide(description: "日本語要約")
    var summary: String
    @Guide(description: "キーワード")
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
            - summary: 記事の長さに比例した日本語要約（短い記事は100文字程度、中程度なら300文字程度、長い記事は600〜800文字）。単語ではなく、記事の核心となる主張・結論・最も重要な事実を文章単位で**太字マーカー**で囲んでください（例: **トランプ政権の関税政策が日本の輸出産業に深刻な打撃を与える見通し**であることが明らかになった）
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
