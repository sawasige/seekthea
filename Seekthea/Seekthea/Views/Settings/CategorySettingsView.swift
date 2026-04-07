import SwiftUI

struct CategorySettingsView: View {
    @AppStorage("userCategories") private var categoriesJSON: String = CategorySettingsView.defaultCategoriesJSON

    @State private var categories: [String] = []
    @State private var newCategory: String = ""

    static let defaultCategories = ["政治", "経済", "社会", "国際", "テクノロジー", "科学", "スポーツ", "エンタメ", "ライフ", "開発"]

    static let defaultCategoriesJSON: String = {
        let data = try! JSONEncoder().encode(defaultCategories)
        return String(data: data, encoding: .utf8)!
    }()

    var body: some View {
        List {
            Section {
                ForEach(categories.indices, id: \.self) { index in
                    TextField("カテゴリ名", text: Binding(
                        get: { categories[index] },
                        set: { newValue in
                            categories[index] = newValue
                            save()
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
                    categories = Self.defaultCategories
                    save()
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
        .onAppear { load() }
    }

    private func load() {
        if let data = categoriesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            categories = decoded
        } else {
            categories = Self.defaultCategories
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(categories),
           let json = String(data: data, encoding: .utf8) {
            categoriesJSON = json
        }
    }

    private func addCategory() {
        let trimmed = newCategory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !categories.contains(trimmed) else { return }
        categories.append(trimmed)
        newCategory = ""
        save()
    }

    private func delete(at offsets: IndexSet) {
        categories.remove(atOffsets: offsets)
        save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        categories.move(fromOffsets: source, toOffset: destination)
        save()
    }
}
