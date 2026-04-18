import SwiftUI
import SwiftData

struct SettingsView: View {
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
                Button("スキップしたソースを復元") {
                    restoreRejectedDomains()
                    showToast("スキップしたソースを復元しました")
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

            Section("データ管理") {
                Button("古い記事を削除（30日以上前）", role: .destructive) {
                    deleteOldArticles()
                    showToast("古い記事を削除しました")
                }
                Button("すべて初期化", role: .destructive) {
                    showResetConfirm = true
                }
            }

            Section("情報") {
                LabeledContent("バージョン", value: "1.0")
                NavigationLink("ライセンス") {
                    LicensesView()
                }
                Link("利用規約", destination: URL(string: "https://sawasige.github.io/seekthea/terms.html")!)
                Link("プライバシーポリシー", destination: URL(string: "https://sawasige.github.io/seekthea/privacy.html")!)
                Link("サポート", destination: URL(string: "https://sawasige.github.io/seekthea/support.html")!)
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
        for key in ["useCompactLayout", "lastDiscoveryRunAt", "lastDiscoveryCheckedAt", "lastFeedRefreshedAt"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
