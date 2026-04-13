import SwiftUI

struct LicenseEntry: Decodable, Identifiable {
    let name: String
    let url: String
    let license: String
    let text: String

    var id: String { name }
}

struct LicensesView: View {
    private let entries: [LicenseEntry] = {
        guard let url = Bundle.main.url(forResource: "licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data) else {
            return []
        }
        return decoded
    }()

    var body: some View {
        List(entries) { entry in
            NavigationLink {
                LicenseDetailView(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                    Text(entry.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("ライセンス")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct LicenseDetailView: View {
    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let url = URL(string: entry.url) {
                    Link(entry.url, destination: url)
                        .font(.caption)
                }
                Text(entry.text)
                    .font(.caption)
                    .monospaced()
            }
            .padding()
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
