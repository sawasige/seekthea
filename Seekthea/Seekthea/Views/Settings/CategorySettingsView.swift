import SwiftUI
import SwiftData

struct CategorySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserCategory.order) private var categories: [UserCategory]
    @State private var newCategory: String = ""

    static let defaultCategories = UserCategory.defaults

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    TextField("カテゴリ名", text: Binding(
                        get: { category.name },
                        set: { newValue in
                            category.name = newValue
                            try? modelContext.save()
                        }
                    ))
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            } header: {
                Text("AIはこのリストからカテゴリを選びます")
            }

            Section {
                HStack {
                    TextField("新しいカテゴリ", text: $newCategory)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("追加") {
                        addCategory()
                    }
                    .disabled(newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
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
        #if !os(macOS)
        .toolbar { EditButton() }
        #endif
    }

    private func addCategory() {
        let trimmed = newCategory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !categories.contains(where: { $0.name == trimmed }) else { return }
        let maxOrder = categories.map(\.order).max() ?? -1
        modelContext.insert(UserCategory(name: trimmed, order: maxOrder + 1))
        try? modelContext.save()
        newCategory = ""
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(categories[index])
        }
        try? modelContext.save()
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
            modelContext.insert(UserCategory(name: name, order: idx))
        }
        try? modelContext.save()
    }
}
