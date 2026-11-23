import SwiftUI

struct HexEditorView: View {
    let fileURL: URL
    @StateObject private var viewModel = HexEditorViewModel()
    @State private var offsetText = ""
    @State private var showSaveError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(NSLocalizedString("hex.search", comment: ""), text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("hex.searchField")
                Button(NSLocalizedString("common.search", comment: "")) { viewModel.search(viewModel.searchText) }
                    .accessibilityIdentifier("hex.search")
                Toggle(NSLocalizedString("hex.readonly", comment: ""), isOn: $viewModel.isReadOnly)
                    .accessibilityIdentifier("hex.readOnlyToggle")
            }
            .padding(.horizontal)
            HStack {
                TextField(NSLocalizedString("hex.goto", comment: ""), text: $offsetText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("hex.offsetField")
                Button(NSLocalizedString("hex.go", comment: "")) {
                    if let offset = Int64(offsetText.trimmingCharacters(in: .whitespaces)) {
                        viewModel.goToOffset(offset)
                    }
                }
                .accessibilityIdentifier("hex.go")
                Button(NSLocalizedString("common.undo", comment: "")) { viewModel.undo() }.disabled(!viewModel.canUndo)
                Button(NSLocalizedString("common.redo", comment: "")) { viewModel.redo() }.disabled(!viewModel.canRedo)
                Button(NSLocalizedString("common.save", comment: "")) {
                    do { try viewModel.save() } catch { viewModel.errorMessage = error.localizedDescription }
                }
                .disabled(viewModel.isReadOnly || viewModel.editedOffsets.isEmpty)
                .accessibilityIdentifier("hex.save")
            }
            .padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(hexRows, id: \.offset) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(format: "%08llX", row.offset))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row.hex)
                                .font(.caption.monospaced())
                            Text(row.ascii)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            HStack {
                Button(NSLocalizedString("common.previous", comment: "")) { viewModel.loadPage(viewModel.currentPage - 1) }
                    .disabled(viewModel.currentPage == 0)
                Spacer()
                Text(String(format: NSLocalizedString("hex.page", comment: ""), viewModel.currentPage + 1, max(viewModel.pageCount, 1)))
                    .font(.caption)
                Spacer()
                Button(NSLocalizedString("common.next", comment: "")) { viewModel.loadPage(viewModel.currentPage + 1) }
                    .disabled(viewModel.currentPage + 1 >= viewModel.pageCount)
            }
            .padding()
            if !viewModel.searchResults.isEmpty {
                Text(String(format: NSLocalizedString("hex.results", comment: ""), viewModel.searchResults.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if viewModel.isExecutable && !viewModel.isReadOnly {
                Text(NSLocalizedString("hex.executable.warning", comment: ""))
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.open(fileURL) }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private struct HexRow { let offset: Int64; let hex: String; let ascii: String }

    private var hexRows: [HexRow] {
        let bytes = [UInt8](viewModel.pageData)
        var rows: [HexRow] = []
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 16, bytes.count)])
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            rows.append(HexRow(offset: Int64(viewModel.currentPage * HexEditorViewModel.chunkSize + index), hex: hex, ascii: ascii))
            index += 16
        }
        return rows
    }
}
