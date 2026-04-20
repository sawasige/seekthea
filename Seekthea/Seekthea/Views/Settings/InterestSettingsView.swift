import SwiftUI
import SwiftData

struct InterestSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserInterest.addedAt) private var interests: [UserInterest]
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
            Section("設定中の興味") {
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
                            Text(String(format: "%.1f", interest.weight))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30)
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
                Section("行動から学習した興味") {
                    ForEach(learnedTopics, id: \.topic) { item in
                        HStack {
                            Text(item.topic)
                            Spacer()
                            ProgressView(value: item.weight)
                                .frame(width: 80)
                            Text(String(format: "%.0f%%", item.weight * 100))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
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
    }

    private func loadLearnedTopics() {
        let engine = InterestEngine(modelContainer: modelContext.container)
        let raw = engine.learnFromHistory(context: modelContext)
        learnedTopics = raw
            .sorted { $0.value > $1.value }
            .prefix(20)
            .map { (topic: $0.key, weight: $0.value) }
    }

    private func addTopic(_ topic: String, en: String = "") {
        guard !topic.isEmpty else { return }
        let existing = Set(interests.map(\.topic))
        guard !existing.contains(topic) else { return }
        let providedEn = en.trimmingCharacters(in: .whitespaces)
        let needsTranslation = providedEn.isEmpty && containsNonASCII(topic)
        let interest = UserInterest(topic: topic, topicEn: providedEn.isEmpty ? topic : providedEn)
        modelContext.insert(interest)
        try? modelContext.save()

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
