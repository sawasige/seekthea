import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

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

    /// ユーザー定義カテゴリエンティティ（SwiftData から order 順で取得）
    private var userCategoryEntities: [UserCategory] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.order)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// カテゴリ名一覧（letter のマッピング順）
    private var userCategories: [String] {
        let entities = userCategoryEntities
        if entities.isEmpty {
            return UserCategory.defaults
        }
        return entities.map(\.name)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private var labeledCategoryList: String {
        userCategories.enumerated().map { idx, name in
            let label = idx < Self.alphabet.count ? String(Self.alphabet[idx]) : "\(idx)"
            return "\(label). \(name)"
        }.joined(separator: "\n")
    }

    /// カテゴリ説明ブロック（プロンプトで「参考」セクションとして渡す）
    /// labeledCategoryList とは別にすることで、AIが説明文を keywords に
    /// そのまま流用してしまうのを防ぐ。aiHint が空のカテゴリはスキップ。
    private var categoryDescriptionsBlock: String {
        let entities = userCategoryEntities
        if entities.isEmpty {
            // SwiftData にデータがないとき（テスト等）のフォールバック
            return UserCategory.defaults.compactMap { name in
                guard let hint = UserCategory.defaultHints[name], !hint.isEmpty else { return nil }
                return "- \(name): \(hint)"
            }.joined(separator: "\n")
        }
        return entities.compactMap { cat in
            guard !cat.aiHint.isEmpty else { return nil }
            return "- \(cat.name): \(cat.aiHint)"
        }.joined(separator: "\n")
    }

    /// 本文が短すぎ／プレースホルダのみのケースを検出。
    /// このケースは AI がキーワード抽出に失敗しがちで、
    /// カテゴリ説明文を流用してしまうので、別プロンプトで処理する
    static func isThinBody(_ desc: String) -> Bool {
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < 30
    }

    /// AIの応答をカテゴリ名に変換する。
    /// プロンプトでは letter（"A" など）を要求しているが、
    /// AIが指示を無視してカテゴリ名そのもの（"スポーツ"）を返すことがあるので両方サポート
    private func categoryName(from labelStr: String) -> String? {
        let trimmed = labelStr.trimmingCharacters(in: .whitespaces)
        // letter パターン（"A" → userCategories[0]）
        if let char = trimmed.uppercased().first,
           char.isLetter,
           let idx = Self.alphabet.firstIndex(of: char),
           idx < userCategories.count {
            return userCategories[idx]
        }
        // カテゴリ名そのものパターン（"スポーツ" → "スポーツ"）
        if userCategories.contains(trimmed) {
            return trimmed
        }
        return nil
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

    /// 日本語の単語を英単語1語に翻訳（興味トピック用）
    /// 失敗時はnil
    static func translateToEnglish(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession()
        let prompt = """
        次の単語を英単語1語に翻訳してください。回答は単語のみ、説明や記号は不要。

        単語: \(text)
        """
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let trimmed = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,。、"))
        // 空白を含む場合は最初の単語だけ採用
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return firstWord.isEmpty ? nil : firstWord
        #else
        return nil
        #endif
    }

    /// 記事を要約してメモリキャッシュに保存（永続化しない）
    func analyze(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article else { return }
        let articleId = article.id

        // 既にキャッシュにあればスキップ
        if AISummaryCache.shared.get(articleId) != nil { return }

        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession()
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
            if Task.isCancelled { return }
            let summary = summaryResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)
            AISummaryCache.shared.set(summary, for: articleId)
        } catch {
            if Task.isCancelled { return }
            print("[AI] Failed: \(article.title) - \(error)")
            applyFallback(article: article)
        }
        #else
        applyFallback(article: article)
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
        let catList = labeledCategoryList
        let catDescBlock = categoryDescriptionsBlock

        while !Task.isCancelled {
            var descriptor = FetchDescriptor<Article>(
                predicate: #Predicate { $0.aiCategory == nil },
                sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard let article = (try? context.fetch(descriptor))?.first else { break }

            let remaining = (try? context.fetchCount(FetchDescriptor<Article>(
                predicate: #Predicate { $0.aiCategory == nil }
            ))) ?? 0
            onProgress?("カテゴリ分類中... 残り\(remaining)件")

            let desc = article.leadText ?? article.ogDescription ?? ""
            let isThin = Self.isThinBody(desc)
            let articleSection: String
            let keywordInstruction: String
            if isThin {
                // 本文が空 or "記事を読む" のような placeholder の時は、AIが
                // 抽出語を見つけられず【参考】の説明文を流用してしまうので、
                // タイトルだけから抽出するよう指示し、無理に5つ揃えなくてよいと明示
                articleSection = "タイトル: \(article.title)"
                keywordInstruction = "上のタイトルから抽出できる重要語句を日本語で（最大5つ。抽出できる語が少なければ無理に揃えなくてよい）"
            } else {
                articleSection = "タイトル: \(article.title)\n内容: \(String(desc.prefix(200)))"
                keywordInstruction = "上の記事タイトル・内容に実際に登場する重要語句を日本語で最大5つ抽出（カテゴリ参考の語ではなく、記事本文から）"
            }

            let session = LanguageModelSession()
            let prompt = """
            以下の記事を分類し、キーワードを抽出してください。

            【カテゴリ】
            \(catList)

            【参考: 各カテゴリの傾向】
            \(catDescBlock)

            【記事】
            \(articleSection)

            【出力】
            - category: 最も適切なカテゴリのアルファベットを1つだけ
            - keywords: \(keywordInstruction)
            - keywordsEn: keywordsと同じ順序で各キーワードを英語1単語に翻訳
            """
            let startTime = Date()
            do {
                let response = try await session.respond(to: prompt, generating: CategoryResult.self)
                let elapsed = Date().timeIntervalSince(startTime)
                let result = response.content
                let mappedName = categoryName(from: result.category)
                #if DEBUG
                print("[AI分類] ────────────")
                print("[AI分類] タイトル: \(article.title)")
                print("[AI分類] 本文: \(desc.isEmpty ? "(なし)" : String(desc.prefix(200)))\(isThin ? " [thin]" : "")")
                print("[AI分類] 実行時間: \(String(format: "%.2f", elapsed))秒")
                print("[AI分類] → カテゴリ: \(result.category) (\(mappedName ?? "未マップ"))")
                print("[AI分類] → キーワード(JP): \(result.keywords)")
                print("[AI分類] → キーワード(EN): \(result.keywordsEn)")
                #endif
                if let name = mappedName {
                    article.aiCategory = name
                } else {
                    // letter以外（カテゴリ名そのものなど）が返ってきた時はマップ失敗。
                    // 空文字を入れて「処理済」扱いにしないと、次回も同じ記事を拾って無限ループする
                    article.aiCategory = ""
                    #if DEBUG
                    print("[AI分類] ⚠️マップ失敗（category='\(result.category)'）: \(article.title)")
                    #endif
                }
                article.keywords = result.keywords
                article.keywordsEn = result.keywordsEn
                try? context.save()
                onArticleClassified?()
            } catch {
                let elapsed = Date().timeIntervalSince(startTime)
                #if DEBUG
                print("[AI分類] ✗失敗（\(String(format: "%.2f", elapsed))秒）: \(article.title) — \(error)")
                #endif
                // 失敗時は空文字をマークして無限ループ防止（"未分類"扱い）
                article.aiCategory = ""
                try? context.save()
            }
        }
        #endif
    }

    private func applyFallback(article: Article) {
        // 要約失敗時は抽出本文/ogDescriptionの冒頭をキャッシュに保存
        let fallback: String?
        if let body = article.extractedBody, !body.isEmpty {
            fallback = String(body.prefix(200))
        } else if let ogDesc = article.ogDescription, !ogDesc.isEmpty {
            fallback = ogDesc
        } else {
            fallback = nil
        }
        if let fallback {
            AISummaryCache.shared.set(fallback, for: article.id)
        }
    }

    /// 記事のAI処理結果をリセットして要約・分類を再生成
    func reprocess(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article else { return }
        AISummaryCache.shared.remove(article.id)
        article.aiCategory = nil
        article.keywordsRaw = ""
        article.keywordsEnRaw = ""
        try? context.save()
        await analyze(articleID: articleID)
        await classifyArticle(articleID: articleID)
    }

    /// 単一記事の分類（再処理用）
    private func classifyArticle(articleID: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let article = context.model(for: articleID) as? Article else { return }

        #if canImport(FoundationModels)
        let catList = labeledCategoryList
        let catDescBlock = categoryDescriptionsBlock
        let desc = article.leadText ?? article.ogDescription ?? ""
        let truncated = desc.isEmpty ? "" : "\n内容: \(String(desc.prefix(200)))"

        do {
            let session = LanguageModelSession()
            let prompt = """
            以下の記事を分類し、キーワードを抽出してください。

            【カテゴリ】
            \(catList)

            【参考: 各カテゴリの傾向】
            \(catDescBlock)

            【記事】
            タイトル: \(article.title)\(truncated)

            【出力】
            - category: 最も適切なカテゴリのアルファベットを1つだけ
            - keywords: 上の記事タイトル・内容に実際に登場する重要語句を日本語で最大5つ抽出（カテゴリ参考の語ではなく、記事本文から）
            - keywordsEn: keywordsと同じ順序で各キーワードを英語1単語に翻訳
            """
            let response = try await session.respond(to: prompt, generating: CategoryResult.self)
            let result = response.content
            if let name = categoryName(from: result.category) {
                article.aiCategory = name
            } else {
                article.aiCategory = ""
            }
            article.keywords = result.keywords
            article.keywordsEn = result.keywordsEn
            try? context.save()
        } catch {
            article.aiCategory = ""
            try? context.save()
        }
        #endif
    }
}
