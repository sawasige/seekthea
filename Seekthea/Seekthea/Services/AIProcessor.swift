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

/// 単一記事のカテゴリ・キーワード分類用
@Generable
struct CategoryResult {
    @Guide(description: "カテゴリのアルファベット1文字")
    var category: String
    @Guide(description: "記事の重要キーワード（日本語、最大5つ）")
    var keywords: [String]
    @Guide(description: "keywordsの英訳（同じ順序、各1単語の英語）")
    var keywordsEn: [String]
}
#endif

/// Apple Intelligence によるオンデバイスAI処理
@MainActor
class AIProcessor {
    private let modelContainer: ModelContainer

    /// ユーザー定義カテゴリリスト（SwiftData から order 順で取得）
    private var userCategories: [String] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.order)])
        let fetched = (try? context.fetch(descriptor)) ?? []
        if fetched.isEmpty {
            return UserCategory.defaults
        }
        return fetched.map(\.name)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private var labeledCategoryList: String {
        userCategories.enumerated().map {
            let label = $0.offset < Self.alphabet.count ? String(Self.alphabet[$0.offset]) : "\($0.offset)"
            return "\(label). \($0.element)"
        }.joined(separator: "\n")
    }

    /// ラベル文字列（"A"）をカテゴリ名に変換（先頭1文字のみ採用）
    private func categoryName(from labelStr: String) -> String? {
        guard let char = labelStr.trimmingCharacters(in: .whitespaces).uppercased().first,
              char.isLetter,
              let idx = Self.alphabet.firstIndex(of: char),
              idx < userCategories.count else { return nil }
        return userCategories[idx]
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

            article.summary = summary
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

    /// 未分類記事を1件ずつカテゴリ分類
    private var isClassifying = false

    func classifyBatch(onProgress: ((String) -> Void)? = nil, onArticleClassified: (() -> Void)? = nil) async {
        guard !isClassifying else { return }
        isClassifying = true
        defer { isClassifying = false }

        #if canImport(FoundationModels)
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.aiCategory == nil },
            sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)]
        )
        guard let articles = try? context.fetch(descriptor), !articles.isEmpty else { return }

        let catList = labeledCategoryList
        for (index, article) in articles.enumerated() {
            if Task.isCancelled { break }
            onProgress?("カテゴリ分類中... (\(index + 1)/\(articles.count))")

            let desc = article.leadText ?? article.ogDescription ?? ""
            let truncated = desc.isEmpty ? "" : "\n内容: \(String(desc.prefix(200)))"

            do {
                let session = LanguageModelSession()
                let prompt = """
                以下の記事を分類し、キーワードを抽出してください。

                カテゴリ一覧:
                \(catList)

                記事タイトル: \(article.title)\(truncated)

                - category: 最も適切なカテゴリのアルファベットを1つだけ
                - keywords: 記事の重要キーワードを日本語で最大5つ
                - keywordsEn: keywordsと同じ順序で各キーワードを英語1単語に翻訳
                """
                let response = try await session.respond(to: prompt, generating: CategoryResult.self)
                let result = response.content
                if let name = categoryName(from: result.category) {
                    article.aiCategory = name
                }
                article.keywords = result.keywords
                article.keywordsEn = result.keywordsEn
                try? context.save()
                onArticleClassified?()
            } catch {
                // 失敗時はスキップ（次回リトライ）
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
