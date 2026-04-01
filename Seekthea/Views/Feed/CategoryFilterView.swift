import SwiftUI

struct CategoryFilterView: View {
    @Binding var selectedCategory: ContentCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全て", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }

                ForEach(ContentCategory.allCases.filter { $0 != .all }) { category in
                    FilterChip(title: category.rawValue, isSelected: selectedCategory == category) {
                        selectedCategory = (selectedCategory == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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
