import SwiftUI
import SwiftData

struct ScoreBreakdownView: View {
    let article: Article
    let modelContainer: ModelContainer
    @Environment(\.dismiss) private var dismiss
    @State private var breakdown: ScoreBreakdown?

    var body: some View {
        NavigationStack {
            Group {
                if let b = breakdown {
                    Form {
                        totalSection(b)
                        keywordSection(b)
                        semanticSection(b)
                        modifierSection(b)
                    }
                    #if os(macOS)
                    .formStyle(.grouped)
                    #endif
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("スコアの内訳")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                let engine = InterestEngine(modelContainer: modelContainer)
                breakdown = engine.explainScore(for: article)
            }
        }
    }

    @ViewBuilder
    private func totalSection(_ b: ScoreBreakdown) -> some View {
        Section {
            HStack {
                Text("合計スコア")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", b.totalScore * 100))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        } footer: {
            Text("現在のデータでの試算値。フィードに表示されているスコアは前回更新時の保存値で、既読化・新着ボーナス切れ・カテゴリ読了率変動などで差が出ます。")
        }
    }

    @ViewBuilder
    private func keywordSection(_ b: ScoreBreakdown) -> some View {
        Section {
            if b.matchedTopics.isEmpty {
                Text("マッチしたトピックなし").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(b.matchedTopics, id: \.topic) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.topic).font(.callout)
                            Text("\(item.matchType)一致 重み\(String(format: "%.2f", item.weight)) × \(Int(item.multiplier))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(String(format: "+%.2f", item.contribution))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                computeRow(label: "合計", value: b.keywordRawScore)
                computeRow(label: "正規化 (x ÷ (x+2))", value: b.keywordScore)
                computeRow(label: "重み × \(Int(b.keywordWeight*100))%",
                           value: b.keywordScore * b.keywordWeight, emphasized: true)
            }
        } header: {
            sectionHeader(title: "キーワード一致", contribution: b.keywordScore * b.keywordWeight)
        } footer: {
            Text("興味トピック・学習トピックの日本語文字列マッチ。タイトル一致は重み×3、キーワード一致は重み×2。")
        }
    }

    @ViewBuilder
    private func semanticSection(_ b: ScoreBreakdown) -> some View {
        Section {
            if b.semanticMatches.isEmpty {
                Text("類似マッチなし").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(b.semanticMatches, id: \.articleKeyword) { m in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.interestKeyword) ↔ \(m.articleKeyword)").font(.callout)
                            Text("重み\(String(format: "%.2f", m.weight)) × 類似度\(String(format: "%.2f", m.similarity))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(String(format: "+%.2f", m.contribution))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                computeRow(label: "合計 (Σ 重み×類似度)", value: b.semanticRawScore)
                computeRow(label: "正規化 (x ÷ (x+1.5))", value: b.semanticScore)
                computeRow(label: "重み × \(Int(b.semanticWeight*100))%",
                           value: b.semanticScore * b.semanticWeight, emphasized: true)
            }
        } header: {
            sectionHeader(title: "セマンティック類似", contribution: b.semanticScore * b.semanticWeight)
        } footer: {
            Text("英語word embeddingによる興味キーワードと記事キーワードの類似度。0.5未満は除外。")
        }
    }

    private func sectionHeader(title: String, contribution: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: "寄与: %.2f", contribution))
                .font(.caption.monospacedDigit())
                .textCase(.none)
        }
    }

    private func computeRow(label: String, value: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.2f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .fontWeight(emphasized ? .semibold : .regular)
        }
    }

    @ViewBuilder
    private func modifierSection(_ b: ScoreBreakdown) -> some View {
        Section {
            HStack {
                Text("新着ボーナス (24h以内)")
                Spacer()
                Text(b.recencyBonus > 1 ? String(format: "×%.1f", b.recencyBonus) : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(b.recencyBonus > 1 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            HStack {
                Text("表示回数ペナルティ")
                Spacer()
                if b.impressionPenalty < 1 {
                    Text("×\(String(format: "%.2f", b.impressionPenalty)) (\(b.impressionCount)回)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("補正")
        }
    }

}
