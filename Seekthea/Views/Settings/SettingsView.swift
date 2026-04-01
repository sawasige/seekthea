import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Int = 30
    @AppStorage("aiProcessingEnabled") private var aiProcessingEnabled = true
    @AppStorage("discoveryEnabled") private var discoveryEnabled = true
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Form {
                Section("更新") {
                    Picker("更新間隔", selection: $refreshInterval) {
                        Text("30分").tag(30)
                        Text("1時間").tag(60)
                        Text("3時間").tag(180)
                    }
                }

                Section("AI処理") {
                    Toggle("AI要約・分類", isOn: $aiProcessingEnabled)
                    Text("Apple Intelligenceを使用して記事を要約・分類します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("発見") {
                    Toggle("ソース自動発見", isOn: $discoveryEnabled)
                    Text("Google Newsから新しいソースを自動的に発見します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("データ管理") {
                    Button("古い記事を削除（30日以上前）", role: .destructive) {
                        deleteOldArticles()
                    }
                    Button("キャッシュをクリア", role: .destructive) {
                        clearCache()
                    }
                }

                Section("情報") {
                    LabeledContent("バージョン", value: "1.0")
                }
            }
            .navigationTitle("設定")
        }
    }

    private func deleteOldArticles() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let predicate = #Predicate<Article> { article in
            article.fetchedAt < cutoff && !article.isFavorite
        }
        do {
            try modelContext.delete(model: Article.self, where: predicate)
        } catch {
            print("Failed to delete old articles: \(error)")
        }
    }

    private func clearCache() {
        let predicate = #Predicate<Article> { _ in true }
        let descriptor = FetchDescriptor<Article>(predicate: predicate)
        if let articles = try? modelContext.fetch(descriptor) {
            for article in articles {
                article.siteFaviconData = nil
                article.isEnriched = false
            }
        }
    }
}
