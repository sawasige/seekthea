import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allArticles: [Article]
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

            Section {
                LabeledContent("保存中の記事", value: "\(allArticles.count)件")
                Text("\(ArticleCleanupService.retentionDays)日以上前または\(ArticleCleanupService.maxArticleCount)件を超えた古い記事は自動削除されます。お気に入りは無期限保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("すべて初期化", role: .destructive) {
                    showResetConfirm = true
                }
            } header: {
                Text("データ管理")
            }

            Section {
                LabeledContent("iCloud同期", value: CloudSyncStatus.shared.status.label)
                Text(CloudSyncStatus.shared.status.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("同期")
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
        ReaderCache.shared.clear()

        // 標準UserDefaultsのアプリ設定を一括削除
        // (将来@AppStorageキーが追加されても自動的にカバーされる)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}
