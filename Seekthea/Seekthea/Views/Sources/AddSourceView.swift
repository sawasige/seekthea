import SwiftUI
import SwiftData

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isAdding = false
    @State private var viewModel: SourcesViewModel?

    let modelContainer: ModelContainer

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
                }

                if let error = viewModel?.addingError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            guard let url = URL(string: urlString) else { return }
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
                    .disabled(urlString.isEmpty || isAdding)
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
