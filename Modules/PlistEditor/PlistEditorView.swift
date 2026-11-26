import SwiftUI

/// Edits one plist number without coercing bad input to 0: the typed text
/// is kept until it parses as the original numeric type, and an invalid
/// value only shows an error — the stored value is left untouched.
private struct NumberEditor: View {
    let initial: NSNumber
    let onValidValue: (NSNumber) -> Void
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void
    @State private var text: String
    @State private var showInvalid = false

    init(initial: NSNumber, onValidValue: @escaping (NSNumber) -> Void, onBeginEdit: @escaping () -> Void, onEndEdit: @escaping () -> Void) {
        self.initial = initial
        self.onValidValue = onValidValue
        self.onBeginEdit = onBeginEdit
        self.onEndEdit = onEndEdit
        _text = State(initialValue: initial.stringValue)
    }

    /// True for floating-point plist numbers (CFNumber float/double types).
    private var isFloatingPoint: Bool {
        let type = CFNumberGetType(initial)
        return type == .floatType || type == .doubleType || type == .float32Type || type == .float64Type
    }

    private func parsedValue() -> NSNumber? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isFloatingPoint {
            guard let value = Double(trimmed) else { return nil }
            return NSNumber(value: value)
        }
        guard let value = Int(trimmed) else { return nil }
        return NSNumber(value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            TextField(NSLocalizedString("plist.value", comment: ""), text: $text, onEditingChanged: { editing in
                if editing { onBeginEdit() } else { onEndEdit() }
            })
            .textFieldStyle(.roundedBorder)
            .keyboardType(isFloatingPoint ? .decimalPad : .numberPad)
            .onChange(of: text) { _ in
                if let value = parsedValue() {
                    showInvalid = false
                    onValidValue(value)
                } else {
                    showInvalid = true
                }
            }
            if showInvalid {
                Text(NSLocalizedString("plist.error.number", comment: ""))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct PlistEditorView: View {
    let fileURL: URL
    @StateObject private var viewModel = PlistEditorViewModel()
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var showAddSheet = false
    @State private var savedMessage: String?
    @State private var exportFileURL: URL?

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                Button(NSLocalizedString("common.undo", comment: "")) { viewModel.undo() }
                    .dsSecondaryButton()
                    .disabled(!viewModel.canUndo)
                Button(NSLocalizedString("common.redo", comment: "")) { viewModel.redo() }
                    .dsSecondaryButton()
                    .disabled(!viewModel.canRedo)
                Spacer()
                Button(NSLocalizedString("plist.add.key", comment: "")) { showAddSheet = true }
                    .dsSecondaryButton()
                    .accessibilityIdentifier("plist.addKey")
                Button(NSLocalizedString("common.save", comment: "")) {
                    savedMessage = viewModel.save() ? NSLocalizedString("plist.saved", comment: "") : nil
                    exportFileURL = viewModel.exportURL()
                }
                .dsPrimaryButton()
                .accessibilityIdentifier("plist.save")
            }
            .padding(.horizontal, DS.Spacing.xl)
            if viewModel.isEmpty {
                EmptyStateView(
                    NSLocalizedString("plist.empty", comment: ""),
                    systemImage: "list.bullet",
                    description: Text(NSLocalizedString("plist.empty.detail", comment: ""))
                ) {
                    Button(NSLocalizedString("plist.add.key", comment: "")) { showAddSheet = true }
                        .dsSecondaryButton()
                }
            } else if viewModel.isArrayRoot {
                List {
                    Section {
                        ForEach(viewModel.arrayRoot.indices, id: \.self) { index in
                            arrayValueEditor(at: index)
                        }
                    } footer: {
                        if viewModel.arrayRoot.contains(where: { !isScalar($0) }) {
                            Text(NSLocalizedString("plist.array.nested.readonly", comment: ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                List {
                    ForEach(viewModel.root.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
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
                Text(message).font(.caption).foregroundStyle(.green).padding(.bottom, DS.Spacing.xs)
            }
            if let error = viewModel.lastValidationError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, DS.Spacing.xl)
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .dsInlineTitle()
        .toolbar {
            if let url = exportFileURL {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Share the real .plist file URL: the filename and
                    // the property-list type travel with the share,
                    // unlike raw data. (A custom Transferable wrapper
                    // was tried first; its FileRepresentation overload
                    // does not compile on this SDK.)
                    ShareLink(item: url, preview: SharePreview(fileURL.lastPathComponent)) {
                        Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            viewModel.open(fileURL)
            exportFileURL = viewModel.exportURL()
        }
        .onChange(of: viewModel.revision) { _ in
            // The next edit clears the stale "saved" banner.
            savedMessage = nil
            exportFileURL = viewModel.exportURL()
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                Form {
                    TextField(NSLocalizedString("plist.key", comment: ""), text: $newKey)
                        .accessibilityIdentifier("plist.newKeyField")
                    TextField(NSLocalizedString("plist.value", comment: ""), text: $newValue)
                        .accessibilityIdentifier("plist.newValueField")
                }
                .navigationTitle(NSLocalizedString("plist.add.key", comment: ""))
                .dsInlineTitle()
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

    private func isScalar(_ value: Any) -> Bool {
        value is String || value is Bool || value is NSNumber || value is Date
    }

    /// Array-root rows: scalar items are editable, nested collections
    /// stay read-only (see the section footer for the reason).
    @ViewBuilder
    private func arrayValueEditor(at index: Int) -> some View {
        let value = viewModel.arrayRoot[index]
        switch value {
        case let bool as Bool:
            Toggle(String(format: NSLocalizedString("plist.array.item", comment: ""), index + 1), isOn: Binding(
                get: { bool },
                set: { viewModel.setArrayValue(index: index, value: $0) }
            ))
        case let number as NSNumber:
            // NSNumber bridges Bool too; the Bool case above already matched.
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(String(format: NSLocalizedString("plist.array.item", comment: ""), index + 1)).font(.headline)
                NumberEditor(initial: number, onValidValue: { viewModel.setArrayValue(index: index, value: $0) }, onBeginEdit: { viewModel.beginEdit() }, onEndEdit: { viewModel.endEdit() })
            }
        case let string as String:
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(String(format: NSLocalizedString("plist.array.item", comment: ""), index + 1)).font(.headline)
                TextField(NSLocalizedString("plist.value", comment: ""), text: Binding(
                    get: { string },
                    set: { viewModel.setArrayValue(index: index, value: $0) }
                ), onEditingChanged: { editing in
                    if editing { viewModel.beginEdit() } else { viewModel.endEdit() }
                })
                .textFieldStyle(.roundedBorder)
            }
        case let date as Date:
            Text("\(String(format: NSLocalizedString("plist.array.item", comment: ""), index + 1)): \(date.formatted())")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text(describingValue(value)).font(.caption).foregroundStyle(.secondary)
        }
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
            // NSNumber bridges Bool too; the Bool case above already matched.
            NumberEditor(initial: number, onValidValue: { viewModel.setValue(key: key, value: $0) }, onBeginEdit: { viewModel.beginEdit() }, onEndEdit: { viewModel.endEdit() })
        case let string as String:
            TextField(NSLocalizedString("plist.value", comment: ""), text: Binding(
                get: { string },
                set: { viewModel.setValue(key: key, value: $0) }
            ), onEditingChanged: { editing in
                if editing { viewModel.beginEdit() } else { viewModel.endEdit() }
            })
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
