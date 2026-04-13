import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Int = 30
    @AppStorage("aiProcessingEnabled") private var aiProcessingEnabled = true
    @AppStorage("discoveryEnabled") private var discoveryEnabled = true
    @Environment(\.modelContext) private var modelContext
    @State private var toastMessage: String?
    @State private var showResetConfirm = false

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    var body: some View {
        Form {
            Section("ソース") {
                NavigationLink("ソース管理") {
                    SourcesListView(modelContainer: modelContainer)
                }
                NavigationLink("ソース発見") {
                    DiscoveryView(modelContainer: modelContainer)
                }
            }

            Section("パーソナライズ") {
                NavigationLink("カテゴリ管理") {
                    CategorySettingsView()
                }
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
                    showToast("AI要約をリセットしました")
                }
            }

            Section("発見") {
                Toggle("ソース自動発見", isOn: $discoveryEnabled)
                Button("スキップしたソースを復元") {
                    restoreRejectedDomains()
                    showToast("スキップしたソースを復元しました")
                }
            }

            Section("データ管理") {
                Button("古い記事を削除（30日以上前）", role: .destructive) {
                    deleteOldArticles()
                    showToast("古い記事を削除しました")
                }
                Button("全記事を削除", role: .destructive) {
                    deleteAllArticles()
                    showToast("全記事を削除しました")
                }
                Button("すべて初期化", role: .destructive) {
                    showResetConfirm = true
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
        .overlay(alignment: .bottom) {
            if let message = toastMessage {
                Text(message)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toastMessage)
        .alert("すべてのデータを削除", isPresented: $showResetConfirm) {
            Button("削除", role: .destructive) {
                resetAllData()
                showToast("すべて初期化しました")
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ソース・記事・カテゴリ・興味トピックなどをすべて削除し、初期状態に戻します。iCloudで同期している他のデバイスからも削除されます。")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            toastMessage = nil
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

    private func resetAllData() {
        do {
            try modelContext.delete(model: Article.self)
            try modelContext.delete(model: Source.self)
            try modelContext.delete(model: DiscoveredDomain.self)
            try modelContext.delete(model: UserCategory.self)
            try modelContext.delete(model: UserInterest.self)
            try modelContext.save()
        } catch {
            print("Failed to reset data: \(error)")
        }

        PresetOGImageCache.clear()
        PendingSourcesStore.clear()

        // AppStorage の削除
        for key in ["refreshInterval", "aiProcessingEnabled", "discoveryEnabled", "useCompactLayout"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func deleteAllArticles() {
        do {
            try modelContext.delete(model: Article.self)
            let sources = (try? modelContext.fetch(FetchDescriptor<Source>())) ?? []
            for source in sources { source.articleCount = 0 }
            try? modelContext.save()
        } catch {
            print("Failed to delete all articles: \(error)")
        }
    }
}
