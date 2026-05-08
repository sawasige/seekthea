import Foundation

/// 記事詳細画面で「前の記事」「次の記事」を提示するために、
/// フィードからの遷移時点での記事リストのスナップショットを保持するシングルトン。
///
/// FeedView は記事カードタップなどで詳細に遷移する直前に
/// `ArticleNavigationContext.shared.snapshot(_:)` でフィードのリストを記録する。
/// `ArticleDetailContainer` はこれを参照して、現在表示中の記事の前後を解決する。
///
/// スナップショットは「開いた瞬間のフィルタ・ソート結果」を固定したいので
/// `[Article]` 参照の配列を保持する。スコア再計算でフィードの順序が変わっても
/// 詳細画面のナビゲーション順は変わらない。
@MainActor
@Observable
final class ArticleNavigationContext {
    static let shared = ArticleNavigationContext()

    private(set) var articles: [Article] = []

    /// このセッション中に開いた記事の id 集合。
    /// FeedView の `effectivelyRead` がこれを参照して、開いた記事が
    /// 既読扱いで最下部に移動するのを抑制する（並びを安定化）。
    /// FeedView 単体ではなく singleton 側に持たせているのは、
    /// `ArticleDetailContainer` から前後カードで遷移した記事も
    /// 同じセッション保護を受けたいため。
    private(set) var sessionReadIDs: Set<UUID> = []

    private init() {}

    func snapshot(_ articles: [Article]) {
        self.articles = articles
    }

    /// 開いた記事をセッション既読の保護リストに登録。
    /// カード経由の遷移時にも呼ぶこと。
    func markVisited(_ articleID: UUID) {
        sessionReadIDs.insert(articleID)
    }

    /// セッション保護を解除（バックグラウンド復帰時 / 明示的リフレッシュ時）。
    func clearSession() {
        sessionReadIDs = []
    }

    func clear() {
        articles = []
        sessionReadIDs = []
    }

    /// `article` の前後（リスト上の隣接）を返す。
    func neighbors(of article: Article) -> (previous: Article?, next: Article?) {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else {
            return (nil, nil)
        }
        let previous = index > 0 ? articles[index - 1] : nil
        let next = index < articles.count - 1 ? articles[index + 1] : nil
        return (previous, next)
    }
}
