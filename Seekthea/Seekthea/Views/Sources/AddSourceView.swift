import SwiftUI
import SwiftData

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isAdding = false
    @State private var viewModel: SourcesViewModel?

    let modelContainer: ModelContainer

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $urlString, prompt: Text("サイトまたはRSSのURLを入力"))
                        #if !os(macOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onChange(of: urlString) {
                            viewModel?.addingError = nil
                        }
                }

                if let error = viewModel?.addingError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task {
                            guard let url = URL(string: trimmedURL) else { return }
                            isAdding = true
                            try? await viewModel?.addSource(url: url)
                            isAdding = false
                            if viewModel?.addingError == nil {
                                dismiss()
                            }
                        }
                    } label: {
                        if isAdding {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("追加")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!isValidURL || isAdding)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 400)
            #endif
            .navigationTitle("ソースを追加")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = SourcesViewModel(modelContainer: modelContainer)
                }
            }
        }
    }
}
