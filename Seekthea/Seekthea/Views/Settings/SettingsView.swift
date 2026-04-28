import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allArticles: [Article]
    @State private var toastMessage: String?
    @State private var showResetConfirm = false
    @State private var isExportingBackup = false
    @State private var backupDocument = SeektheaBackupDocument()
    @State private var isImportingBackup = false
    @State private var backupError: String?

    private var modelContainer: ModelContainer {
        modelContext.container
    }

    /// Info.plist の CFBundleShortVersionString（= MARKETING_VERSION）から取得
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }()

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
                Button("バックアップを作成") {
                    prepareExport()
                }
                Button("バックアップから復元") {
                    isImportingBackup = true
                }
            } header: {
                Text("バックアップ")
            } footer: {
                Text("ソース・カテゴリ・興味トピック・お気に入り／既読状態を JSONファイルにまとめて、iCloud Drive や Files に保存できます。復元時は既存データに統合されます（重複は追加されません）。記事本文はバックアップ対象外です。")
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
                LabeledContent("バージョン", value: Self.appVersion)
                NavigationLink("ライセンス") {
                    LicensesView()
                }
                Link("利用規約", destination: URL(string: "https://sawasige.github.io/seekthea/terms.html")!)
                Link("プライバシーポリシー", destination: URL(string: "https://sawasige.github.io/seekthea/privacy.html")!)
                Link("サポート", destination: URL(string: "https://sawasige.github.io/seekthea/support.html")!)
            }

            #if DEBUG
            ReviewPromptDebugSection(showToast: showToast)
            #endif
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
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: Self.defaultBackupFilename()
        ) { result in
            switch result {
            case .success: showToast("バックアップを保存しました")
            case .failure(let err): backupError = err.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url): importBackup(from: url)
            case .failure(let err): backupError = err.localizedDescription
            }
        }
        .alert("バックアップエラー", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("OK") { backupError = nil }
        } message: {
            Text(backupError ?? "")
        }
    }

    private static func defaultBackupFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "seekthea-backup-\(df.string(from: Date()))"
    }

    private func prepareExport() {
        do {
            let data = try SettingsBackup.export(context: modelContext)
            backupDocument = SeektheaBackupDocument(data: data)
            isExportingBackup = true
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func importBackup(from url: URL) {
        // fileImporter の URL は security-scoped
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let summary = try SettingsBackup.restore(from: data, context: modelContext)
            showToast(summary.summaryText)
        } catch {
            backupError = error.localizedDescription
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

    static let debugDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

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
        ReaderCache.shared.clear()
        AISummaryCache.shared.clear()

        // 標準UserDefaultsのアプリ設定を一括削除
        // (将来@AppStorageキーが追加されても自動的にカバーされる)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}

#if DEBUG
private struct ReviewPromptDebugSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot = ReviewPromptManager.debugSnapshot()
    @State private var readCount: Int = 0
    let showToast: (String) -> Void

    var body: some View {
        Section {
            LabeledContent("初回起動", value: format(snapshot.firstLaunchDate))
            LabeledContent("既読件数", value: "\(readCount)")
            LabeledContent("前回表示", value: format(snapshot.lastShownDate))
            LabeledContent("前回表示バージョン", value: snapshot.lastShownVersion ?? "—")
            LabeledContent("前回拒否", value: format(snapshot.lastDeclinedDate))
            Button("今すぐ表示") {
                NotificationCenter.default.post(name: ReviewPromptManager.debugTriggerNotification, object: nil)
            }
            Button("条件をリセット", role: .destructive) {
                ReviewPromptManager.debugReset()
                refresh()
                showToast("レビュー依頼の条件をリセットしました")
            }
        } header: {
            Text("レビュー依頼 (Debug)")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        snapshot = ReviewPromptManager.debugSnapshot()
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.isRead })
        readCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return SettingsView.debugDateFormatter.string(from: date)
    }
}
#endif
