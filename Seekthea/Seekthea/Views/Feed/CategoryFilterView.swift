import SwiftUI

struct CategoryFilterView: View {
    @Binding var selectedCategory: String?
    var categoryCounts: [String: Int] = [:]

    private var sortedCategories: [(name: String, count: Int)] {
        categoryCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let totalCount = categoryCounts.values.reduce(0, +)
                FilterChip(title: "全て", count: totalCount, isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }

                ForEach(sortedCategories, id: \.name) { item in
                    FilterChip(title: item.name, count: item.count, isSelected: selectedCategory == item.name) {
                        selectedCategory = (selectedCategory == item.name) ? nil : item.name
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct FilterChip: View {
    let title: String
    var count: Int = 0
    let isSelected: Bool
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
        }
        .buttonStyle(.plain)
    }
}
