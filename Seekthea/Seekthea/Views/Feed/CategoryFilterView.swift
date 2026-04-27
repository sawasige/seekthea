import SwiftUI

struct CategoryFilterView: View {
    @Binding var selectedCategory: String?
    var totalCount: Int = 0
    var categoryCounts: [String: Int] = [:]
    var categoryOrder: [String] = []
    /// スワイプ中にハイライトする候補チップの識別子。nil=プレビューなし、""=「全て」、それ以外はカテゴリ名。
    var previewID: String? = nil
    /// プレビューの濃さ (0..1)。
    var previewProgress: CGFloat = 0

    private var sortedCategories: [(name: String, count: Int)] {
        categoryOrder.compactMap { name in
            guard let count = categoryCounts[name] else { return nil }
            return (name: name, count: count)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "全て",
                        count: totalCount,
                        isSelected: selectedCategory == nil,
                        previewProgress: previewID == "" ? previewProgress : 0
                    ) {
                        selectedCategory = nil
                    }
                    .id("chip_all")

                    ForEach(sortedCategories, id: \.name) { item in
                        FilterChip(
                            title: item.name,
                            count: item.count,
                            isSelected: selectedCategory == item.name,
                            previewProgress: previewID == item.name ? previewProgress : 0
                        ) {
                            selectedCategory = (selectedCategory == item.name) ? nil : item.name
                        }
                        .id("chip_\(item.name)")
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: selectedCategory) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if let cat = selectedCategory {
                        proxy.scrollTo("chip_\(cat)", anchor: .center)
                    } else {
                        proxy.scrollTo("chip_all", anchor: .center)
                    }
                }
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    var count: Int = 0
    let isSelected: Bool
    var previewProgress: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .overlay {
                if !isSelected && previewProgress > 0 {
                    Capsule()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(Double(previewProgress))
                }
            }
        }
        .buttonStyle(.plain)
    }
}
