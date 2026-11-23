import SwiftUI

struct PlistEditorView: View {
    let fileURL: URL
    @StateObject private var viewModel = PlistEditorViewModel()
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var showAddSheet = false
    @State private var savedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(NSLocalizedString("common.undo", comment: "")) { viewModel.undo() }.disabled(!viewModel.canUndo)
                Button(NSLocalizedString("common.redo", comment: "")) { viewModel.redo() }.disabled(!viewModel.canRedo)
                Spacer()
                Button(NSLocalizedString("plist.add.key", comment: "")) { showAddSheet = true }
                    .accessibilityIdentifier("plist.addKey")
                Button(NSLocalizedString("common.save", comment: "")) {
                    savedMessage = viewModel.save() ? NSLocalizedString("plist.saved", comment: "") : nil
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("plist.save")
            }
            .padding()
            if viewModel.isLoading {
                ProgressView(NSLocalizedString("common.loading", comment: ""))
            } else if viewModel.isEmpty {
                EmptyStateView(
                    NSLocalizedString("plist.empty", comment: ""),
                    systemImage: "list.bullet",
                    description: Text(NSLocalizedString("plist.empty.detail", comment: ""))
                )
            } else if viewModel.isArrayRoot {
                List(viewModel.arrayRoot.indices, id: \.self) { index in
                    Text(describingValue(viewModel.arrayRoot[index]))
                }
            } else {
                List {
                    ForEach(viewModel.root.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key).font(.headline)
                            valueEditor(for: key)
                        }
                        .swipeActions {
                            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { viewModel.deleteKey(key) }
                        }
                    }
                }
            }
            if let message = savedMessage {
                Text(message).font(.caption).foregroundStyle(.green).padding(.bottom, 4)
            }
            if let error = viewModel.lastValidationError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let data = viewModel.exportData() {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: data, preview: SharePreview(fileURL.lastPathComponent)) {
                        Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear { viewModel.open(fileURL) }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                Form {
                    TextField(NSLocalizedString("plist.key", comment: ""), text: $newKey)
                        .accessibilityIdentifier("plist.newKeyField")
                    TextField(NSLocalizedString("plist.value", comment: ""), text: $newValue)
                        .accessibilityIdentifier("plist.newValueField")
                }
                .navigationTitle(NSLocalizedString("plist.add.key", comment: ""))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("common.cancel", comment: "")) { showAddSheet = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.add", comment: "")) {
                            viewModel.addKey(newKey, value: newValue)
                            newKey = ""; newValue = ""; showAddSheet = false
                        }
                    }
                }
            }
        }
        .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    @ViewBuilder
    private func valueEditor(for key: String) -> some View {
        let value = viewModel.root[key]
        switch value {
        case let bool as Bool:
            Toggle(NSLocalizedString("plist.bool", comment: ""), isOn: Binding(
                get: { bool },
                set: { viewModel.setValue(key: key, value: $0) }
            ))
        case let number as NSNumber:
            TextField(NSLocalizedString("plist.value", comment: ""), text: Binding(
                get: { number.stringValue },
                set: { viewModel.setValue(key: key, value: Int($0) ?? 0) }
            ))
            .textFieldStyle(.roundedBorder)
        case let string as String:
            TextField(NSLocalizedString("plist.value", comment: ""), text: Binding(
                get: { string },
                set: { viewModel.setValue(key: key, value: $0) }
            ))
            .textFieldStyle(.roundedBorder)
        case let data as Data:
            Text(String(format: NSLocalizedString("plist.data.bytes", comment: ""), data.count))
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(describingValue(value as Any)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func describingValue(_ value: Any) -> String {
        if let dict = value as? [String: Any] { return "Dictionary (\(dict.count))" }
        if let array = value as? [Any] { return "Array (\(array.count))" }
        return "\(value)"
    }
}
