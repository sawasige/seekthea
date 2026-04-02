import SwiftUI
import SwiftData

struct InterestSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserInterest.addedAt) private var interests: [UserInterest]
    @State private var newTopic = ""
    @State private var learnedTopics: [(topic: String, weight: Double)] = []

    // プリセットの興味トピック候補
    private let suggestions = [
        "AI", "プログラミング", "スタートアップ", "ガジェット",
        "ゲーム", "映画", "音楽", "スポーツ",
        "政治", "経済", "科学", "宇宙",
        "健康", "料理", "旅行", "教育",
        "Apple", "Google", "セキュリティ", "OSS",
        "React", "Swift", "Python", "Rust",
    ]

    private var unusedSuggestions: [String] {
        let existing = Set(interests.map(\.topic))
        return suggestions.filter { !existing.contains($0) }
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
                        addTopic(newTopic.trimmingCharacters(in: .whitespaces))
                        newTopic = ""
                    }
                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !unusedSuggestions.isEmpty {
                Section("おすすめトピック") {
                    FlowLayoutView(items: unusedSuggestions) { suggestion in
                        Button {
                            addTopic(suggestion)
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

    private func addTopic(_ topic: String) {
        guard !topic.isEmpty else { return }
        let existing = Set(interests.map(\.topic))
        guard !existing.contains(topic) else { return }
        let interest = UserInterest(topic: topic)
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
