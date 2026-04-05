import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

/// カテゴリ・キーワード（Guided Generation用）
@Generable
struct ArticleMeta {
    @Guide(description: "カテゴリ名")
    var category: String
    @Guide(description: "キーワード")
    var keywords: [String]
}

/// バッチ分類用（入力順と同じ順序でカテゴリを返す）
@Generable
struct BatchCategories {
    @Guide(description: "入力と同じ順序のカテゴリ名リスト")
    var categories: [String]
}
#endif

/// Apple Intelligence によるオンデバイスAI処理
@MainActor
class AIProcessor {
    private let modelContainer: ModelContainer

    /// ユーザー定義カテゴリリスト
    private var userCategories: [String] {
        guard let data = UserDefaults.standard.string(forKey: "userCategories")?.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: data),
              !categories.isEmpty else {
            return CategorySettingsView.defaultCategories
        }
        return categories
    }

    private var categoryList: String {
        userCategories.joined(separator: "、")
    }

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

            // 1. 要約を自由文で生成（Guided Generationなし）
            let summaryPrompt = """
            あなたはニュース記者です。以下の記事を書き直してください。元の記事の内容を忠実に、しかし簡潔に伝える記事を書いてください。

            \(article.textForAI)

            書き方:
            - あなた自身が記者としてこのニュースを伝えてください。「この記事では」「紹介しています」「述べています」のような第三者的な表現は使わないでください
            - 重要な情報は省略せず、読者がこれだけで内容を理解できるように書いてください
            - 読みやすいよう適切に改行してください
            - 複数の論点やポイントがある場合は「・」で列挙してください
            - 核心となる事実や結論は **太字** で囲んでください
            - 前置きは不要です。本文だけを出力してください
            """

            let summaryResponse = try await session.respond(to: summaryPrompt)
            let summary = summaryResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // 2. カテゴリ・キーワードをGuided Generationで生成
            let metaPrompt = """
            以下の記事のカテゴリとキーワードを抽出してください。

            \(article.textForAI)

            - category: 以下から最も適切なものを1つ選択: \(categoryList)。どれにも合わない場合は最も近いものを選んでください
            - keywords: 重要キーワード（最大5つ）
            """

            let metaResponse = try await session.respond(to: metaPrompt, generating: ArticleMeta.self)
            let meta = metaResponse.content

            article.summary = summary
            article.aiCategory = meta.category
            article.keywords = meta.keywords
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
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        var processed = 0
        for id in articleIDs {
            await analyze(articleID: id)
            processed += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 未分類記事をまとめてカテゴリ分類（10件ずつバッチ処理）
    private var isClassifying = false

    func classifyBatch() async {
        guard !isClassifying else { return }
        isClassifying = true
        defer { isClassifying = false }

        #if canImport(FoundationModels)
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.aiCategory == nil },
            sortBy: [SortDescriptor(\Article.fetchedAt, order: .reverse)]
        )
        guard let articles = try? context.fetch(descriptor), !articles.isEmpty else { return }

        // 10件ずつバッチ処理
        let batchSize = 10
        for batchStart in stride(from: 0, to: articles.count, by: batchSize) {
            let batch = Array(articles[batchStart..<min(batchStart + batchSize, articles.count)])
            let titles = batch.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")

            do {
                let session = LanguageModelSession()
                let catList = categoryList
                let prompt = """
                以下の記事タイトルそれぞれにカテゴリを1つ割り当ててください。
                カテゴリは以下から選択: \(catList)。どれにも合わない場合は最も近いものを選んでください。

                \(titles)

                入力と同じ順序でカテゴリ名だけをリストで返してください。
                """
                let response = try await session.respond(to: prompt, generating: BatchCategories.self)
                let categories = response.content.categories

                for (index, article) in batch.enumerated() {
                    if index < categories.count {
                        article.aiCategory = categories[index]
                    }
                }
                try? context.save()
            } catch {
                // バッチ失敗時はスキップ（次回リトライ）
            }
        }
        #endif
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
