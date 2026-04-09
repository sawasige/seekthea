import SwiftUI
import SwiftData

struct InterestSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserInterest.addedAt) private var interests: [UserInterest]
    @State private var newTopic = ""
    @State private var learnedTopics: [(topic: String, weight: Double)] = []

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
                    HStack {
                        Text(interest.topic)
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
                        // プリセットにあれば英訳を使う、なければトピックをそのまま英語として使用
                        let en = suggestions.first(where: { $0.ja == trimmed })?.en ?? trimmed
                        addTopic(trimmed, en: en)
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
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
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
        let interest = UserInterest(topic: topic, topicEn: en.isEmpty ? topic : en)
        modelContext.insert(interest)
        try? modelContext.save()
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
