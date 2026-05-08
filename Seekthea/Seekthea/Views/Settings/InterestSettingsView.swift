import SwiftUI
import SwiftData

struct InterestSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserInterest.addedAt) private var interests: [UserInterest]
    @Query(sort: \ExcludedKeyword.addedAt) private var excludedKeywords: [ExcludedKeyword]
    @State private var newTopic = ""
    @State private var learnedTopics: [(topic: String, weight: Double)] = []
    @State private var translatingTopics: Set<String> = []

    // プリセットの興味トピック候補（日本語: 英語）
    private let suggestions: [(ja: String, en: String)] = [
        ("AI", "AI"), ("プログラミング", "programming"), ("スタートアップ", "startup"), ("ガジェット", "gadget"),
        ("ゲーム", "game"), ("映画", "movie"), ("音楽", "music"), ("スポーツ", "sports"),
        ("政治", "politics"), ("経済", "economy"), ("科学", "science"), ("宇宙", "space"),
        ("健康", "health"), ("料理", "cooking"), ("旅行", "travel"), ("教育", "education"),
        ("Apple", "Apple"), ("Google", "Google"), ("セキュリティ", "security"), ("OSS", "OSS"),
        ("React", "React"), ("Swift", "Swift"), ("Python", "Python"), ("Rust", "Rust"),
        ("バイク", "motorcycle"), ("自動車", "automobile"), ("自転車", "bicycle"),
    ]

    private var unusedSuggestions: [(ja: String, en: String)] {
        let existing = Set(interests.map(\.topic))
        return suggestions.filter { !existing.contains($0.ja) }
    }

    var body: some View {
        Form {
            Section("手動設定の興味") {
                if interests.isEmpty {
                    Text("興味トピックを追加すると、関連記事が優先表示されます")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                ForEach(interests, id: \.topic) { interest in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(interest.topic)
                            if translatingTopics.contains(interest.topic) {
                                ProgressView().controlSize(.mini)
                            }
                            Spacer()
                            // 重みスライダー
                            Slider(value: Binding(
                                get: { interest.weight },
                                set: { interest.weight = $0; try? modelContext.save() }
                            ), in: 0.1...2.0, step: 0.1)
                            .frame(width: 120)
                            Text(String(format: "×%.1f", interest.weight))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36)
                        }
                        if !translatingTopics.contains(interest.topic) && isTranslationMissing(interest) {
                            Label("英訳が取得できなかったため、セマンティック類似のスコアは効きません", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        modelContext.delete(interests[index])
                    }
                    try? modelContext.save()
                    // 手動興味を消すと、その topic が自動興味として再登場する可能性がある
                    loadLearnedTopics()
                }
            }

            Section("トピックを追加") {
                HStack {
                    TextField("例: AI, Swift, 宇宙", text: $newTopic)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("追加") {
                        let trimmed = newTopic.trimmingCharacters(in: .whitespaces)
                        if let pair = suggestions.first(where: { $0.ja == trimmed }) {
                            addTopic(pair.ja, en: pair.en)
                        } else {
                            // プリセット外: バックグラウンドでAI翻訳
                            addTopic(trimmed)
                        }
                        newTopic = ""
                    }
                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !unusedSuggestions.isEmpty {
                Section("おすすめトピック") {
                    FlowLayoutView(items: unusedSuggestions.map(\.ja)) { suggestion in
                        Button {
                            if let pair = suggestions.first(where: { $0.ja == suggestion }) {
                                addTopic(pair.ja, en: pair.en)
                            }
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !learnedTopics.isEmpty {
                Section {
                    ForEach(learnedTopics, id: \.topic) { item in
                        learnedTopicRow(item)
                    }
                } header: {
                    Text("自動学習の興味")
                } footer: {
                    Text("既読・お気に入りから自動で見つけたトピックで、現在のおすすめスコアに反映されています。「手動設定に昇格」で重みを調整できる手動側に移動。「学習を取り消す」で誤学習を解除します。")
                }
            }

            if !excludedKeywords.isEmpty {
                Section {
                    ForEach(excludedKeywords, id: \.id) { ex in
                        HStack {
                            Image(systemName: "nosign")
                                .foregroundStyle(.secondary)
                            Text(ex.keyword)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(excludedKeywords[index])
                        }
                        try? modelContext.save()
                        // 除外を解除すると、その keyword が自動興味として再登場する可能性がある
                        loadLearnedTopics()
                    }
                } header: {
                    Text("学習対象から外したキーワード")
                } footer: {
                    Text("AI が学習した興味から外したキーワード。興味スコアの計算には使われません（フィードからは消えません）。スワイプで解除できます。")
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        #endif
        .navigationTitle("興味トピック")
        .onAppear { loadLearnedTopics() }
        // CloudKit 同期等で外部から手動興味・除外リストが変わった時の安全網
        .onChange(of: interests.count) { loadLearnedTopics() }
        .onChange(of: excludedKeywords.count) { loadLearnedTopics() }
    }

    private func loadLearnedTopics() {
        let engine = InterestEngine(modelContainer: modelContext.container)
        let raw = engine.learnFromHistory(context: modelContext)
        let manualTopics = Set(interests.map { $0.topic.lowercased() })
        let excludedSet = Set(excludedKeywords.map { $0.keyword.lowercased() })
        // 既に手動側にあるトピック・除外済みキーワードは「学習中」リストから除く
        learnedTopics = raw
            .filter { !manualTopics.contains($0.key.lowercased()) && !excludedSet.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(20)
            .map { (topic: $0.key, weight: $0.value) }
    }

    @ViewBuilder
    private func learnedTopicRow(_ item: (topic: String, weight: Double)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.topic)
                Spacer()
                ProgressView(value: item.weight)
                    .frame(width: 80)
                Text(String(format: "×%.2f", item.weight))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Spacer()
                Button {
                    addTopic(item.topic)
                    loadLearnedTopics()
                } label: {
                    Label("手動設定に昇格", systemImage: "arrow.up.circle")
                        .labelStyle(TightLabelStyle())
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    excludeTopic(item.topic)
                    loadLearnedTopics()
                } label: {
                    Label("学習を取り消す", systemImage: "arrow.uturn.backward")
                        .labelStyle(TightLabelStyle())
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func excludeTopic(_ keyword: String) {
        let trimmed = keyword.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let existing = Set(excludedKeywords.map { $0.keyword.lowercased() })
        guard !existing.contains(trimmed) else { return }
        modelContext.insert(ExcludedKeyword(keyword: trimmed))
        try? modelContext.save()
        // 自動興味リストを更新（除外したトピックを消す）
        loadLearnedTopics()
    }

    private func addTopic(_ topic: String, en: String = "") {
        guard !topic.isEmpty else { return }
        let existing = Set(interests.map(\.topic))
        guard !existing.contains(topic) else { return }

        // 同名の除外キーワードがあれば解除（手動追加が優先する）
        let topicLower = topic.lowercased()
        for excluded in excludedKeywords where excluded.keyword.lowercased() == topicLower {
            modelContext.delete(excluded)
        }

        let providedEn = en.trimmingCharacters(in: .whitespaces)
        let needsTranslation = providedEn.isEmpty && containsNonASCII(topic)
        let interest = UserInterest(topic: topic, topicEn: providedEn.isEmpty ? topic : providedEn)
        modelContext.insert(interest)
        try? modelContext.save()

        // 自動興味リストを更新（手動に昇格したトピックを消す）
        loadLearnedTopics()

        // プリセット外の非ASCIIトピックはバックグラウンドでAI翻訳
        if needsTranslation {
            translatingTopics.insert(topic)
            Task { @MainActor in
                if let translated = await AIProcessor.translateToEnglish(topic),
                   !containsNonASCII(translated) {
                    interest.topicEn = translated
                    try? modelContext.save()
                }
                translatingTopics.remove(topic)
            }
        }
    }

    private func containsNonASCII(_ s: String) -> Bool {
        s.unicodeScalars.contains { !$0.isASCII }
    }

    /// 英訳が取得できなかったトピック判定
    /// - 日本語など非ASCIIトピックで topicEn が同じ（=翻訳されてない）の時
    private func isTranslationMissing(_ interest: UserInterest) -> Bool {
        containsNonASCII(interest.topic) && interest.topic == interest.topicEn
    }
}

// MARK: - TightLabelStyle

/// アイコンとテキストを 3pt 間隔で詰めて並べる Label スタイル。
/// 標準の `.automatic` だとボタン内で隙間が広く感じるので。
private struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 3
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - FlowLayout for suggestions

private struct FlowLayoutView<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
