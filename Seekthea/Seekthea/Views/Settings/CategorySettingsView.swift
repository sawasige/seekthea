import SwiftUI
import SwiftData

struct CategorySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserCategory.order) private var categories: [UserCategory]
    @State private var showAddSheet = false

    static let defaultCategories = UserCategory.defaults

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryDetailView(category: category)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                                .font(.body)
                            if !category.aiHint.isEmpty {
                                Text(category.aiHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                Text("AI説明なし")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            } header: {
                Text("AIはこのリストからカテゴリを選びます")
            } footer: {
                Text("各カテゴリの説明文がAI判定の精度に影響します。タップして編集できます。")
            }

            Section {
                Button("デフォルトに戻す") {
                    resetToDefaults()
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("カテゴリ管理")
        .toolbar {
            #if !os(macOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CategoryCreateSheet(existingNames: Set(categories.map(\.name))) { name, hint in
                addCategory(name: name, hint: hint)
            }
        }
    }

    private func addCategory(name: String, hint: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !categories.contains(where: { $0.name == trimmed }) else { return }
        let maxOrder = categories.map(\.order).max() ?? -1
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalHint = trimmedHint.isEmpty ? (UserCategory.defaultHints[trimmed] ?? "") : trimmedHint
        modelContext.insert(UserCategory(name: trimmed, order: maxOrder + 1, aiHint: finalHint))
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet) {
        let deletedNames = Set(offsets.map { categories[$0].name })
        for index in offsets {
            modelContext.delete(categories[index])
        }
        try? modelContext.save()
        // 削除したカテゴリを持つ記事を清掃 → AI 再分類トリガー
        Task { await reclassifyAffected(removing: deletedNames) }
    }

    /// 削除したカテゴリ名を持つ記事の aiCategory を更新し、AI に再分類させる。
    /// 複数カテゴリ持ちはそのカテゴリだけ取り除く。単一だった場合は nil にして再分類対象に。
    private func reclassifyAffected(removing deleted: Set<String>) async {
        guard !deleted.isEmpty else { return }
        let lowercaseDeleted = Set(deleted.map { $0.lowercased() })
        let articles = (try? modelContext.fetch(FetchDescriptor<Article>())) ?? []
        var affected = false
        for article in articles {
            let cats = article.categories
            guard !cats.isEmpty else { continue }
            let remaining = cats.filter { !lowercaseDeleted.contains($0.lowercased()) }
            if remaining.count == cats.count { continue }  // 影響なし
            affected = true
            if remaining.isEmpty {
                article.aiCategory = nil  // 次の classifyBatch で再分類
            } else {
                article.aiCategory = remaining.joined(separator: ",")
            }
        }
        guard affected else { return }
        try? modelContext.save()
        // AI 再分類をバックグラウンド起動
        let processor = AIProcessor(modelContainer: modelContext.container)
        await processor.classifyBatch()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        for (idx, category) in reordered.enumerated() {
            category.order = idx
        }
        try? modelContext.save()
    }

    private func resetToDefaults() {
        for category in categories {
            modelContext.delete(category)
        }
        for (idx, name) in UserCategory.defaults.enumerated() {
            let hint = UserCategory.defaultHints[name] ?? ""
            modelContext.insert(UserCategory(name: name, order: idx, aiHint: hint))
        }
        try? modelContext.save()
    }
}

// MARK: - 新規追加シート

private struct CategoryCreateSheet: View {
    let existingNames: Set<String>
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var aiHint: String = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty && !existingNames.contains(trimmedName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("カテゴリ名") {
                    TextField("例: ガジェット", text: $name)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Section {
                    #if os(macOS)
                    TextEditor(text: $aiHint)
                        .frame(minHeight: 80)
                    #else
                    TextField("例: スマホ、タブレット、PC、周辺機器", text: $aiHint, axis: .vertical)
                        .lineLimit(2...6)
                    #endif
                } header: {
                    Text("AIへの説明（省略可）")
                } footer: {
                    Text("どんな記事がこのカテゴリに該当するかをAIに伝える説明文。空欄でも分類はできるが、説明があると精度が上がります。デフォルトカテゴリ名（政治、経済など）を入力した場合は標準の説明が自動入力されます。")
                }
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 400)
            #endif
            .navigationTitle("カテゴリを追加")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        onAdd(name, aiHint)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}

// MARK: - 詳細編集

private struct CategoryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let category: UserCategory

    @State private var name: String = ""
    @State private var aiHint: String = ""

    var body: some View {
        Form {
            Section("カテゴリ名") {
                TextField("例: スポーツ", text: $name)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            Section {
                #if os(macOS)
                TextEditor(text: $aiHint)
                    .frame(minHeight: 80)
                #else
                TextField("例: 野球、サッカー、選手、試合、オリンピック", text: $aiHint, axis: .vertical)
                    .lineLimit(2...6)
                #endif
            } header: {
                Text("AIへの説明")
            } footer: {
                Text("どんな記事がこのカテゴリに該当するかをAIに伝えるための説明文。空欄でも分類はできるが、説明があると精度が上がります。\n例: 「野球、サッカー、選手、試合（個別企業の業績は「経済」へ）」のように、含めるトピックや他カテゴリとの境界を書くと効果的。")
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("カテゴリの編集")
        .onAppear {
            name = category.name
            aiHint = category.aiHint
        }
        .onDisappear {
            save()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHint = aiHint.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        if !trimmedName.isEmpty, category.name != trimmedName {
            category.name = trimmedName
            changed = true
        }
        if category.aiHint != trimmedHint {
            category.aiHint = trimmedHint
            changed = true
        }
        if changed {
            try? modelContext.save()
        }
    }
}
