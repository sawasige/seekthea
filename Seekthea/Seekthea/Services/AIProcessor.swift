import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels

/// 単一記事のカテゴリ・キーワード分類結果
struct CategoryResult {
    /// ユーザーカテゴリ名（スキーマで選択肢を強制しているので必ずいずれかになる）
    var category: String
    var keywords: [String]
    var keywordsEn: [String]
}
#endif

/// Apple Intelligence によるAI処理。要約はオンデバイス、カテゴリ分類は
/// 設定がオンなら Private Cloud Compute、それ以外はオンデバイスで行う
@MainActor
class AIProcessor {
    private let modelContainer: ModelContainer

    /// ユーザー定義カテゴリエンティティ（SwiftData から order 順で取得）
    private var userCategoryEntities: [UserCategory] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UserCategory>(sortBy: [SortDescriptor(\.order)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// カテゴリ名一覧（order 順、重複なし）。スキーマの選択肢にも使う
    private var userCategories: [String] {
        let entities = userCategoryEntities
        if entities.isEmpty {
            return UserCategory.defaults
        }
        var seen = Set<String>()
        return entities.map(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// カテゴリ説明ブロック（プロンプトで「参考」セクションとして渡す）
    /// カテゴリ一覧とは別にすることで、AIが説明文を keywords に
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

    #if canImport(FoundationModels)
    /// 記事1件をカテゴリ分類し、キーワードを抽出する（一括分類・再分類で共通）。
    /// カテゴリは DynamicGenerationSchema の anyOf でユーザーカテゴリ名に限定する。
    /// A/B/C… の記号で選ばせる旧方式は、迷った記事をリスト後方のテック系カテゴリへ
    /// 寄せる偏りがあった（160記事の比較で 開発 37件 / テクノロジー 2件）。
    /// 配信元のジャンルはヒントに渡さない。渡すと記事の内容より配信元に引っ張られ、
    /// カテゴリがソースのジャンルとほぼ同じになる（実ソース122記事の比較で確認）。
    func classify(_ article: Article, usePCC: Bool = false) async throws -> CategoryResult {
        let categories = userCategories
        let desc = article.leadText ?? article.ogDescription ?? ""
        let articleSection: String
        let keywordInstruction: String
        if Self.isThinBody(desc) {
            // 本文が空 or "記事を読む" のような placeholder の時は、AIが
            // 抽出語を見つけられず【参考】の説明文を流用してしまうので、
            // タイトルだけから抽出するよう指示し、無理に5つ揃えなくてよいと明示
            articleSection = "タイトル: \(article.title)"
            keywordInstruction = "上のタイトルから抽出できる重要語句を日本語で（最大5つ。抽出できる語が少なければ無理に揃えなくてよい）"
        } else {
            articleSection = "タイトル: \(article.title)\n内容: \(String(desc.prefix(200)))"
            keywordInstruction = "上の記事タイトル・内容に実際に登場する重要語句を日本語で最大5つ抽出（カテゴリ参考の語ではなく、記事本文から）"
        }

        let prompt = """
        以下の記事を分類し、キーワードを抽出してください。

        【カテゴリ】
        \(categories.joined(separator: "\n"))

        【参考: 各カテゴリの傾向】
        \(categoryDescriptionsBlock)

        【記事】
        \(articleSection)

        【出力】
        - category: 最も適切なカテゴリ名を1つだけ
        - keywords: \(keywordInstruction)
        - keywordsEn: keywordsと同じ順序で各キーワードを英語1単語に翻訳
        """

        let stringArray = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        let root = DynamicGenerationSchema(name: "CategoryResult", properties: [
            .init(name: "category", description: "カテゴリ名",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: categories)),
            .init(name: "keywords", description: "記事の重要キーワード（日本語、最大5つ）", schema: stringArray),
            .init(name: "keywordsEn", description: "keywordsの英訳（同じ順序、各1単語の英語）", schema: stringArray),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session: LanguageModelSession
        if usePCC, #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
        } else {
            session = LanguageModelSession()
        }
        let content = try await session.respond(to: prompt, schema: schema).content
        return CategoryResult(
            category: try content.value(String.self, forProperty: "category"),
            keywords: try content.value([String].self, forProperty: "keywords"),
            keywordsEn: try content.value([String].self, forProperty: "keywordsEn")
        )
    }

    /// 複数の記事を1回のリクエストでまとめて分類する（Private Cloud Compute 用）。
    /// 結果は記事の番号で突き合わせ、返ってこなかった記事は nil になる。
    /// オンデバイスのモデルはコンテキストが小さいので、まとめる方式は PCC でだけ使う。
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    func classifyTogether(_ articles: [Article], usePCC: Bool = true) async throws -> [CategoryResult?] {
        let categories = userCategories
        let list = articles.enumerated().map { index, article -> String in
            let desc = article.leadText ?? article.ogDescription ?? ""
            let body = Self.isThinBody(desc) ? "" : "\n内容: \(String(desc.prefix(200)))"
            return "[\(index + 1)]\nタイトル: \(article.title)\(body)"
        }.joined(separator: "\n\n")

        let prompt = """
        以下の\(articles.count)件の記事をそれぞれ分類し、キーワードを抽出してください。

        【カテゴリ】
        \(categories.joined(separator: "\n"))

        【参考: 各カテゴリの傾向】
        \(categoryDescriptionsBlock)

        【記事】
        \(list)

        【出力】
        記事ごとに1件ずつ、すべての記事について出力する。
        - number: 記事の番号
        - category: 最も適切なカテゴリ名を1つだけ
        - keywords: その記事のタイトル・内容に実際に登場する重要語句を日本語で最大5つ（少なければ無理に揃えなくてよい）
        - keywordsEn: keywordsと同じ順序で各キーワードを英語1単語に翻訳
        """

        let stringArray = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        let item = DynamicGenerationSchema(name: "ArticleResult", properties: [
            .init(name: "number", description: "記事の番号", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "category", description: "カテゴリ名",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: categories)),
            .init(name: "keywords", description: "記事の重要キーワード（日本語、最大5つ）", schema: stringArray),
            .init(name: "keywordsEn", description: "keywordsの英訳（同じ順序、各1単語の英語）", schema: stringArray),
        ])
        let root = DynamicGenerationSchema(name: "BatchResult", properties: [
            .init(name: "results", description: "記事ごとの結果", schema: DynamicGenerationSchema(
                arrayOf: item, minimumElements: articles.count, maximumElements: articles.count)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = usePCC
            ? LanguageModelSession(model: PrivateCloudComputeLanguageModel())
            : LanguageModelSession()
        let content = try await session.respond(to: prompt, schema: schema).content
        var output = [CategoryResult?](repeating: nil, count: articles.count)
        for element in try content.value([GeneratedContent].self, forProperty: "results") {
            let number = try element.value(Int.self, forProperty: "number")
            guard (1...articles.count).contains(number) else { continue }
            output[number - 1] = CategoryResult(
                category: try element.value(String.self, forProperty: "category"),
                keywords: try element.value([String].self, forProperty: "keywords"),
                keywordsEn: try element.value([String].self, forProperty: "keywordsEn")
            )
        }
        return output
    }
    #endif

    // MARK: - Private Cloud Compute

    /// 設定「Apple のサーバーで高精度に分類」の UserDefaults キー（未設定ならオン）
    static let usePCCKey = "usePrivateCloudCompute"

    /// PCC で1回のリクエストにまとめる記事数。120記事の計測では、20件でも40件でも
    /// 欠落はなく、かかる時間もほぼ同じだった。安全ガードの拒否はバッチ全体を
    /// 失敗させるので、巻き込まれる件数が少ない20件にしている。
    private static let pccBatchSize = 20

    /// この端末と OS で PCC を使えるか（設定のスイッチを出すかどうかの判定に使う）
    static var isPCCSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().availability != .unavailable(.deviceNotEligible)
        }
        #endif
        return false
    }

    /// 設定がオンで、いま PCC を呼べる状態か
    private var isPCCReady: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.usePCCKey) == nil || defaults.bool(forKey: Self.usePCCKey) else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }

    /// 今回の分類で PCC を使うか。通信の失敗や利用枠の上限など、PCC 側の理由で
    /// 失敗したら false にして、残りはオンデバイスで分類する（次回の分類でまた試す）
    private var pccActive = false

    #if canImport(FoundationModels)
    private enum FailureKind {
        /// 一時的な制限。記事をマークせず、未分類のまま次回に委ねる
        case rateLimited
        /// 安全ガードによる拒否。その記事は分類できない
        case refused
        /// キャンセル。記事をマークしない
        case cancelled
        case other
    }

    /// エラーの種類を判定する。OS 27 では LanguageModelError、それより前は
    /// LanguageModelSession.GenerationError が投げられるので、両方を見る
    private static func failureKind(of error: Error) -> FailureKind {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited: return .rateLimited
            case .refusal, .guardrailViolation: return .refused
            default: return .other
            }
        }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .rateLimited: return .rateLimited
            case .refusal, .guardrailViolation: return .refused
            default: return .other
            }
        }
        return .other
    }

    /// PCC が使えるときは PCC で、だめならオンデバイスで1件を分類する
    private func classifyPreferringPCC(_ article: Article) async throws -> CategoryResult {
        if pccActive {
            do {
                return try await classify(article, usePCC: true)
            } catch where Self.failureKind(of: error) == .other {
                // 拒否や制限ではない失敗は PCC 側の障害とみなし、オンデバイスでやり直す
                #if DEBUG
                print("[AI分類] PCC が失敗したためオンデバイスに切り替え: \(type(of: error)) \(error)")
                #endif
                pccActive = false
            }
        }
        return try await classify(article)
    }

    /// 分類結果を記事に書き込む（保存は呼び出し側で行う）
    private func store(_ result: CategoryResult, in article: Article, onError: ((String) -> Void)? = nil) {
        if userCategories.contains(result.category) {
            article.aiCategory = result.category
            article.aiClassificationError = nil
        } else {
            // スキーマで選択肢を縛っているので通常は起きないが、分類中にカテゴリが
            // 編集された場合などに備える。空文字を入れて「処理済」扱いにしないと、
            // 次回も同じ記事を拾って無限ループする
            article.aiCategory = ""
            article.aiClassificationError = "other"
            onError?("未知のカテゴリ（category='\(result.category)'）: \(article.title)")
            #if DEBUG
            print("[AI分類] ⚠️未知のカテゴリ（category='\(result.category)'）: \(article.title)")
            #endif
        }
        article.keywords = result.keywords
        article.keywordsEn = result.keywordsEn
    }

    /// 分類の失敗を記事に書き込む。空文字をマークして、同じ記事を拾い続けるのを防ぐ
    private func storeFailure(_ kind: FailureKind, in article: Article) {
        article.aiCategory = ""
        article.aiClassificationError = kind == .refused ? "refused" : "other"
    }
    #endif

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

    /// 未分類記事をカテゴリ分類（PCC が使えるときは複数件をまとめて、そうでなければ1件ずつ）
    private var isClassifying = false

    func classifyBatch(
        onProgress: ((String) -> Void)? = nil,
        onArticleClassified: (() -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) async {
        guard !isClassifying else { return }
        isClassifying = true
        defer { isClassifying = false }

        #if canImport(FoundationModels)
        let context = modelContainer.mainContext

        // 旧コードはレート制限エラーでも記事を「処理済み（空文字）」にマークしていたため、
        // その被害を受けた記事を一度だけ未分類に戻して再分類の対象にする
        let recoveryKey = "requeueRateLimitedArticles_20260802"
        if !UserDefaults.standard.bool(forKey: recoveryKey) {
            requeueErroredArticles()
            UserDefaults.standard.set(true, forKey: recoveryKey)
        }

        pccActive = isPCCReady
        classifying: while !Task.isCancelled {
            // PCC が使える間は複数件をまとめて、そうでなければ1件ずつ分類する
            var descriptor = FetchDescriptor<Article>(
                predicate: #Predicate { $0.aiCategory == nil },
                sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)]
            )
            descriptor.fetchLimit = pccActive ? Self.pccBatchSize : 1
            guard let articles = try? context.fetch(descriptor), !articles.isEmpty else { break }

            let remaining = (try? context.fetchCount(FetchDescriptor<Article>(
                predicate: #Predicate { $0.aiCategory == nil }
            ))) ?? 0
            onProgress?("カテゴリ分類中... 残り\(remaining)件")

            // まとめて分類できなかった記事。このあと1件ずつ分類する
            var pending = articles
            if pccActive, articles.count > 1, #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                let startTime = Date()
                do {
                    let results = try await classifyTogether(articles)
                    pending = []
                    for (article, result) in zip(articles, results) {
                        if let result {
                            store(result, in: article, onError: onError)
                            onArticleClassified?()
                        } else {
                            pending.append(article)
                        }
                    }
                    try? context.save()
                    #if DEBUG
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("[AI分類] PCC でまとめて分類: \(articles.count)件中\(articles.count - pending.count)件（\(String(format: "%.2f", elapsed))秒）")
                    for (article, result) in zip(articles, results) {
                        print("[AI分類]   \(result?.category ?? "(結果なし)"): \(article.title)（\(article.sourceName)）")
                    }
                    #endif
                } catch {
                    #if DEBUG
                    print("[AI分類] ✗PCC のまとめ分類が失敗: \(type(of: error)) \(error)")
                    #endif
                    switch Self.failureKind(of: error) {
                    case .cancelled, .rateLimited:
                        break classifying
                    case .refused:
                        // 安全ガードの拒否はバッチ全体を失敗させる。1件ずつやり直せば、
                        // 拒否されるのは問題の記事だけで済む
                        break
                    case .other:
                        // 通信の失敗や利用枠の上限など。残りはオンデバイスで分類する
                        pccActive = false
                    }
                }
            }

            for article in pending {
                if Task.isCancelled { break classifying }
                #if DEBUG
                let desc = article.leadText ?? article.ogDescription ?? ""
                #endif
                let startTime = Date()
                do {
                    let result = try await classifyPreferringPCC(article)
                    #if DEBUG
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("[AI分類] ────────────")
                    print("[AI分類] タイトル: \(article.title)（\(article.sourceName)）")
                    print("[AI分類] 本文: \(desc.isEmpty ? "(なし)" : String(desc.prefix(200)))\(Self.isThinBody(desc) ? " [thin]" : "")")
                    print("[AI分類] 実行時間: \(String(format: "%.2f", elapsed))秒\(pccActive ? "（PCC）" : "")")
                    print("[AI分類] → カテゴリ: \(result.category)")
                    print("[AI分類] → キーワード(JP): \(result.keywords)")
                    print("[AI分類] → キーワード(EN): \(result.keywordsEn)")
                    #endif
                    store(result, in: article, onError: onError)
                    try? context.save()
                    onArticleClassified?()
                } catch {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let kind = Self.failureKind(of: error)
                    // キャンセルは失敗ではないので、記事をマークせずに抜ける
                    if kind == .cancelled { break classifying }
                    onError?("\(error) （\(String(format: "%.2f", elapsed))秒）: \(article.title)")
                    #if DEBUG
                    print("[AI分類] ✗失敗（\(String(format: "%.2f", elapsed))秒）: \(article.title) — \(type(of: error)) \(error)")
                    #endif
                    // レート制限は一時的エラー（主にバックグラウンド時）。記事をマークすると
                    // 「処理済み」扱いになり二度と分類されないので、未分類のまま中断して
                    // 次回のバッチに委ねる
                    if kind == .rateLimited { break classifying }
                    storeFailure(kind, in: article)
                    try? context.save()
                }
            }
        }
        #endif
    }

    /// エラーマークされた記事（refusal以外）を未分類に戻す。
    /// レート制限のような一時的エラーで「処理済み」扱いになった記事の回復用
    private func requeueErroredArticles() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.aiCategory == "" && $0.aiClassificationError == "other" }
        )
        guard let articles = try? context.fetch(descriptor), !articles.isEmpty else { return }
        for article in articles {
            article.aiCategory = nil
            article.aiClassificationError = nil
        }
        try? context.save()
        #if DEBUG
        print("[AI分類] エラーマークされていた\(articles.count)件を未分類に戻した")
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
        article.aiClassificationError = nil
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
        pccActive = isPCCReady
        do {
            let result = try await classifyPreferringPCC(article)
            store(result, in: article)
            try? context.save()
        } catch {
            #if DEBUG
            print("[AI再分類] ✗失敗: \(article.title) — \(type(of: error)) \(error)")
            #endif
            let kind = Self.failureKind(of: error)
            // キャンセルとレート制限は一時的なのでマークせず、未分類のまま次回に委ねる
            if kind == .cancelled || kind == .rateLimited { return }
            storeFailure(kind, in: article)
            try? context.save()
        }
        #endif
    }
}
