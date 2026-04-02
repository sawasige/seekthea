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
                Section("パーソナライズ") {
                    NavigationLink("興味トピック") {
                        InterestSettingsView()
                    }
                }

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
                    Button("全記事のAI要約を再生成") {
                        resetAIProcessing()
                    }
                }

                Section("発見") {
                    Toggle("ソース自動発見", isOn: $discoveryEnabled)
                    Button("スキップしたソースを復元") {
                        restoreRejectedDomains()
                    }
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
            #if os(macOS)
            .formStyle(.grouped)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            #endif
            .navigationTitle("設定")
        }
    }

    private func resetAIProcessing() {
        let descriptor = FetchDescriptor<Article>()
        if let articles = try? modelContext.fetch(descriptor) {
            for article in articles {
                article.summary = nil
                article.aiCategory = nil
                article.keywordsRaw = ""
                article.isAIProcessed = false
            }
            try? modelContext.save()
        }
    }

    private func restoreRejectedDomains() {
        let predicate = #Predicate<DiscoveredDomain> { $0.isRejected }
        if let domains = try? modelContext.fetch(FetchDescriptor(predicate: predicate)) {
            for domain in domains {
                domain.isRejected = false
                domain.isSuggested = true
            }
            try? modelContext.save()
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
