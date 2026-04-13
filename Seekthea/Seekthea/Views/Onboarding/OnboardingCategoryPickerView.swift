import SwiftUI

struct OnboardingCategoryPickerView: View {
    let onConfirm: ([String]) -> Void
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selected: Set<String> = []
    @State private var visibleCount = 0

    private var categories: [(String, [PresetSource])] {
        PresetCatalog.popularByCategory
    }

    private var columns: [GridItem] {
        #if os(macOS)
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        #else
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
        #endif
    }

    private var totalPopularCount: Int {
        categories.filter { selected.contains($0.0) }.reduce(0) { $0 + $1.1.count }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.accentColor.opacity(0.03),
                    Color.clear
                ],
                center: .top,
                startRadius: 40,
                endRadius: 600
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { index, entry in
                            let (category, popular) = entry
                            CategoryTile(
                                category: category,
                                popular: popular,
                                isSelected: selected.contains(category)
                            )
                            .opacity(index < visibleCount ? 1 : 0)
                            .offset(y: index < visibleCount ? 0 : 12)
                            .onTapGesture {
                                toggleSelection(category)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 140)
                }
            }
        }
        .overlay(alignment: .bottom) { confirmButton }
        .onAppear { runCascadeAnimation() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                Spacer()
            }
            Text("興味のあるトピックは？")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.horizontal, 20)
            Text("あとから自由に追加・変更できます")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private var confirmButton: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.clear, Color(white: 0, opacity: 0).opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 20)

            Button {
                let categoriesToAdd = categories.map(\.0).filter { selected.contains($0) }
                onConfirm(categoriesToAdd)
            } label: {
                Text(selected.isEmpty
                     ? "カテゴリを選んでください"
                     : "\(selected.count)カテゴリ追加（\(totalPopularCount)ソース）")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor)
                    }
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .padding(.top, 12)
            .background(.ultraThinMaterial)
        }
    }

    private func toggleSelection(_ category: String) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if selected.contains(category) {
                selected.remove(category)
            } else {
                selected.insert(category)
            }
        }
    }

    private func runCascadeAnimation() {
        if reduceMotion {
            visibleCount = categories.count
            return
        }
        for i in 0..<categories.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                withAnimation(.easeOut(duration: 0.4)) {
                    visibleCount = i + 1
                }
            }
        }
    }
}

private struct CategoryTile: View {
    let category: String
    let popular: [PresetSource]
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: CategoryIcon.symbol(for: category))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                }

                Text(category)
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(popular) { source in
                        HStack(spacing: 8) {
                            SourceThumbnailView(siteURL: source.siteURL, size: 20)
                            Text(source.name)
                                .font(.caption)
                                .foregroundStyle(isSelected ? Color.white.opacity(0.95) : .primary.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial))
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.06),
                            radius: isSelected ? 14 : 8, x: 0, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
            .scaleEffect(isSelected ? 1.03 : 1.0)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor, Color.white)
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}
