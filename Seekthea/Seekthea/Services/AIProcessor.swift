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

    /// カテゴリ名 → AI判定のヒントになる説明文。
    /// 該当キーがない場合（ユーザー追加の独自カテゴリなど）は説明なしでフォールバック。
    private static let categoryDescriptions: [String: String] = [
        "政治": "選挙、国会、政策、外交、与野党",
        "経済": "株、為替、企業業績、市場、金融",
        "社会": "事件、事故、犯罪、災害、社会問題",
        "国際": "海外ニュース、国際関係、外国情勢",
        "テクノロジー": "IT、ガジェット、AI、Apple、ソフトウェア",
        "科学": "宇宙、物理、生物、研究、学術",
        "スポーツ": "野球、サッカー、選手、試合、オリンピック",
        "エンタメ": "芸能、YouTuber、VTuber、映画、音楽、テレビ、ネット話題",
        "ライフ": "暮らし、料理、ファッション、健康、住まい、グルメ",
        "開発": "プログラミング、エンジニアリング、コード、フレームワーク"
    ]

    private var labeledCategoryList: String {
        userCategories.enumerated().map { idx, name in
            let label = idx < Self.alphabet.count ? String(Self.alphabet[idx]) : "\(idx)"
            if let desc = Self.categoryDescriptions[name] {
                return "\(label). \(name)（\(desc)）"
            }
            return "\(label). \(name)"
        }.joined(separator: "\n")
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
            let truncated = desc.isEmpty ? "" : "\n内容: \(String(desc.prefix(200)))"

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
            let startTime = Date()
            do {
                let response = try await session.respond(to: prompt, generating: CategoryResult.self)
                let elapsed = Date().timeIntervalSince(startTime)
                let result = response.content
                let mappedName = categoryName(from: result.category)
                #if DEBUG
                print("[AI分類] ────────────")
                print("[AI分類] タイトル: \(article.title)")
                print("[AI分類] 本文: \(desc.isEmpty ? "(なし)" : String(desc.prefix(200)))")
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
