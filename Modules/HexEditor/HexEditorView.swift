import SwiftUI

/// A single byte the user can tap to edit.
private struct ByteEditTarget: Identifiable {
    let offset: Int64
    let currentValue: UInt8
    var id: Int64 { offset }
}

/// Sheet that edits one byte as two hex digits. Invalid input is shown
/// as an error and never reaches the view model, so a bad value can
/// neither be saved nor coerce anything.
private struct ByteEditSheet: View {
    let target: ByteEditTarget
    let onSave: (UInt8) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @State private var showInvalid = false

    init(target: ByteEditTarget, onSave: @escaping (UInt8) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: String(format: "%02X", target.currentValue))
    }

    private var parsedValue: UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2 else { return nil }
        return UInt8(trimmed, radix: 16)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("hex.edit.value", comment: ""), text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("hex.editField")
                    if showInvalid {
                        Text(NSLocalizedString("hex.edit.invalid", comment: ""))
                            .font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text(String(format: NSLocalizedString("hex.edit.offset", comment: ""), target.offset))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(NSLocalizedString("hex.edit.title", comment: ""))
            .dsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "")) {
                        guard let value = parsedValue else { showInvalid = true; return }
                        onSave(value)
                    }
                    .disabled(parsedValue == nil)
                }
            }
        }
    }
}

struct HexEditorView: View {
    let fileURL: URL
    @StateObject private var viewModel = HexEditorViewModel()
    @State private var offsetText = ""
    @State private var byteToEdit: ByteEditTarget?

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            VStack(spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.md) {
                    TextField(NSLocalizedString("hex.search", comment: ""), text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("hex.searchField")
                    Button(NSLocalizedString("common.search", comment: "")) { viewModel.search(viewModel.searchText) }
                        .dsSecondaryButton()
                        .accessibilityIdentifier("hex.search")
                    Toggle(NSLocalizedString("hex.readonly", comment: ""), isOn: $viewModel.isReadOnly)
                        .accessibilityIdentifier("hex.readOnlyToggle")
                }
                HStack(spacing: DS.Spacing.md) {
                    TextField(NSLocalizedString("hex.goto", comment: ""), text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("hex.offsetField")
                    Button(NSLocalizedString("hex.go", comment: "")) {
                        if let offset = Int64(offsetText.trimmingCharacters(in: .whitespaces)) {
                            viewModel.goToOffset(offset)
                        }
                    }
                    .dsSecondaryButton()
                    .accessibilityIdentifier("hex.go")
                    Button(NSLocalizedString("common.undo", comment: "")) { viewModel.undo() }
                        .dsSecondaryButton()
                        .disabled(!viewModel.canUndo)
                    Button(NSLocalizedString("common.redo", comment: "")) { viewModel.redo() }
                        .dsSecondaryButton()
                        .disabled(!viewModel.canRedo)
                    Button(NSLocalizedString("common.save", comment: "")) {
                        do { try viewModel.save() } catch { viewModel.errorMessage = error.localizedDescription }
                    }
                    .dsPrimaryButton()
                    .disabled(viewModel.isReadOnly || viewModel.editedOffsets.isEmpty)
                    .accessibilityIdentifier("hex.save")
                }
            }
            .padding(.horizontal, DS.Spacing.xl)
            if viewModel.fileSize == 0 {
                EmptyStateView(
                    NSLocalizedString("hex.empty", comment: ""),
                    systemImage: "doc.text",
                    description: Text(NSLocalizedString("hex.empty.detail", comment: ""))
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        ForEach(hexRows, id: \.offset) { row in
                            HStack(alignment: .top, spacing: DS.Spacing.md) {
                                Text(String(format: "%08llX", row.offset))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                HStack(spacing: DS.Spacing.xs) {
                                    ForEach(row.bytes, id: \.offset) { cell in
                                        Button {
                                            guard !viewModel.isReadOnly else {
                                                viewModel.errorMessage = NSLocalizedString("hex.error.readonly", comment: "")
                                                return
                                            }
                                            byteToEdit = ByteEditTarget(offset: cell.offset, currentValue: cell.value)
                                        } label: {
                                            Text(String(format: "%02X", cell.value))
                                                .font(.caption.monospaced())
                                                .foregroundStyle(cell.isEdited ? .orange : .primary)
                                                .padding(DS.Spacing.xxs)
                                                .background(
                                                    cell.isEdited ? Color.orange.opacity(0.15) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 4)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("hex.byte.\(cell.offset)")
                                        .disabled(viewModel.isReadOnly)
                                    }
                                }
                                Text(row.ascii)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(DS.Spacing.xl)
                }
            }
            HStack(spacing: DS.Spacing.md) {
                Button(NSLocalizedString("common.previous", comment: "")) { viewModel.loadPage(viewModel.currentPage - 1) }
                    .dsSecondaryButton()
                    .disabled(viewModel.currentPage == 0)
                Spacer()
                Text(String(format: NSLocalizedString("hex.page", comment: ""), viewModel.currentPage + 1, max(viewModel.pageCount, 1)))
                    .font(.caption)
                Spacer()
                Button(NSLocalizedString("common.next", comment: "")) { viewModel.loadPage(viewModel.currentPage + 1) }
                    .dsSecondaryButton()
                    .disabled(viewModel.currentPage + 1 >= viewModel.pageCount)
            }
            .padding(.horizontal, DS.Spacing.xl)
            if !viewModel.searchResults.isEmpty {
                Text(String(format: NSLocalizedString("hex.results", comment: ""), viewModel.searchResults.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if viewModel.isExecutable && !viewModel.isReadOnly {
                Text(NSLocalizedString("hex.executable.warning", comment: ""))
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, DS.Spacing.xl)
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .dsInlineTitle()
        .onAppear { viewModel.open(fileURL) }
        .sheet(item: $byteToEdit) { target in
            ByteEditSheet(target: target, onSave: { value in
                viewModel.editByte(at: target.offset, to: value)
                byteToEdit = nil
            }, onCancel: { byteToEdit = nil })
        }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private struct HexByte { let offset: Int64; let value: UInt8; let isEdited: Bool }
    private struct HexRow { let offset: Int64; let bytes: [HexByte]; let ascii: String }

    /// Rows render through `byte(at:)` so edited bytes show their edited
    /// value (and highlight) instead of the on-disk byte.
    private var hexRows: [HexRow] {
        let pageData = viewModel.pageData
        var rows: [HexRow] = []
        var index = 0
        while index < pageData.count {
            let end = min(index + 16, pageData.count)
            var bytes: [HexByte] = []
            for i in index..<end {
                let absolute = Int64(viewModel.currentPage * HexEditorViewModel.chunkSize + i)
                let value = viewModel.byte(at: absolute) ?? pageData[i]
                bytes.append(HexByte(offset: absolute, value: value, isEdited: viewModel.editedOffsets[absolute] != nil))
            }
            let ascii = bytes.map { (32...126).contains($0.value) ? String(UnicodeScalar($0.value)) : "." }.joined()
            rows.append(HexRow(offset: Int64(viewModel.currentPage * HexEditorViewModel.chunkSize + index), bytes: bytes, ascii: ascii))
            index += 16
        }
        return rows
    }
}
