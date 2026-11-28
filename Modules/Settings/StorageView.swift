import SwiftUI

/// Storage view (contract §C.5): live per-folder bytes, free space,
/// and "Purge temp" (runs `cleanupStaleTempDirectories`, reports
/// bytes freed or "nothing to purge").
struct StorageView: View {
    @State private var folderSizes: [(name: String, bytes: Int64)] = []
    @State private var freeSpaceBytes: Int64?
    @State private var purgeResult: String?
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                ForEach(folderSizes, id: \.name) { folder in
                    HStack(spacing: DS.Spacing.md) {
                        Text(folder.name)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(folder.name): \(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file))")
                }
                HStack(spacing: DS.Spacing.md) {
                    Text(Loc.string("settings.storage.free"))
                    Spacer()
                    Text(freeSpaceText)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Loc.string("settings.storage.free")): \(freeSpaceText)")
            } header: {
                Text(Loc.string("settings.storage.title")).dsSectionHeader()
            }
            Section {
                Button(Loc.string("settings.storage.purge")) {
                    Task { await purgeTemp() }
                }
                .dsPrimaryButton()
                .disabled(isLoading)
                .accessibilityLabel(Loc.string("settings.storage.purge"))
                if let purgeResult {
                    Text(purgeResult)
                        .font(.subheadline)
                        .accessibilityLabel(purgeResult)
                }
            }
        }
        .navigationTitle(Loc.string("settings.storage.title"))
        .dsInlineTitle()
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: DS.Accessibility.minTouchTarget, minHeight: DS.Accessibility.minTouchTarget)
                }
                .accessibilityLabel(Loc.string("common.refresh"))
            }
        }
    }

    private var freeSpaceText: String {
        guard let freeSpaceBytes else { return Loc.string("common.unknown") }
        return ByteCountFormatter.string(fromByteCount: freeSpaceBytes, countStyle: .file)
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let files = FileSystemManager.shared
        var sizes: [(name: String, bytes: Int64)] = []
        let folders: [FileSystemManager.WorkspaceFolder] = [
            .imported, .signed, .certificates, .downloads, .temp, .tweaks, .inbox
        ]
        for folder in folders {
            do {
                let url = try files.folder(folder)
                sizes.append((name: folder.rawValue, bytes: Self.directorySize(at: url)))
            } catch {
                // A folder that cannot be read reports zero instead
                // of failing the whole screen; the error is logged.
                sizes.append((name: folder.rawValue, bytes: 0))
                await AppLogger.shared.warning("Storage: could not read folder \(folder.rawValue): \(error.localizedDescription)")
            }
        }
        folderSizes = sizes
        freeSpaceBytes = files.freeSpaceBytes()
    }

    private func purgeTemp() async {
        let files = FileSystemManager.shared
        let before: Int64
        do {
            let tempURL = try files.folder(.temp)
            before = Self.directorySize(at: tempURL)
        } catch {
            before = 0
        }
        files.cleanupStaleTempDirectories(maxAge: 0)
        await refresh()
        if before <= 0 {
            purgeResult = Loc.string("settings.storage.nothing")
        } else {
            let freed = before - (folderSizes.first(where: { $0.name == FileSystemManager.WorkspaceFolder.temp.rawValue })?.bytes ?? 0)
            purgeResult = Loc.string(
                "settings.storage.purged",
                ByteCountFormatter.string(fromByteCount: max(freed, 0), countStyle: .file)
            )
        }
    }

    /// Recursive byte total for a folder. Per-file read failures are
    /// skipped (a size total is advisory, not a load-bearing read),
    /// which is why this uses `do/catch … continue` rather than
    /// failing the whole computation.
    private static func directorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values.isDirectory != true, let size = values.fileSize {
                    total += Int64(size)
                }
            } catch {
                continue
            }
        }
        return total
    }
}
