import Foundation

// MARK: - SideStoreGuide
//
// SideStore export + the ordered, data-only guide for importing a signed
// IPA into SideStore. This file holds models and the export operation;
// it contains no UI. The UI renders `SideStoreGuide.standard()` as steps.
//
// Free-Apple-account limits documented below (7 days, 3 apps) are Apple's
// limits and may change; they are stated here as documented facts, not as
// values this code enforces.

// MARK: - Models

/// One ordered step of the SideStore import guide.
public struct SideStoreStep: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let order: Int
    public let title: String
    public let detail: String
    public let isOptional: Bool

    public init(id: UUID = UUID(), order: Int, title: String, detail: String, isOptional: Bool = false) {
        self.id = id
        self.order = order
        self.title = title
        self.detail = detail
        self.isOptional = isOptional
    }
}

/// One documented limit that applies to the SideStore / free-account flow.
public struct SideStoreLimit: Codable, Sendable, Equatable {
    public let name: String
    public let value: String
    public let note: String

    public init(name: String, value: String, note: String) {
        self.name = name
        self.value = value
        self.note = note
    }
}

/// The complete SideStore guide: ordered steps plus the limits the user
/// should know about before starting.
public struct SideStoreGuide: Sendable, Equatable {
    public let title: String
    public let introduction: String
    public let steps: [SideStoreStep]
    public let limits: [SideStoreLimit]
    public let footerNote: String

    public init(
        title: String,
        introduction: String,
        steps: [SideStoreStep],
        limits: [SideStoreLimit],
        footerNote: String
    ) {
        self.title = title
        self.introduction = introduction
        self.steps = steps
        self.limits = limits
        self.footerNote = footerNote
    }

    /// The standard guide. Steps are data, not UI: the UI renders them in
    /// `order` and shows `limits` alongside.
    public static func standard() -> SideStoreGuide {
        SideStoreGuide(
            title: "Install with SideStore",
            introduction: "Export the signed IPA from Ksign Next, then import it into SideStore. SideStore signs the app with your Apple ID and installs it on your device.",
            steps: [
                SideStoreStep(
                    order: 1,
                    title: "Export the IPA",
                    detail: "In Ksign Next, choose the signed app and tap Export for SideStore. The IPA is saved to the SideStoreExports folder in Files."
                ),
                SideStoreStep(
                    order: 2,
                    title: "Install SideStore",
                    detail: "If SideStore is not on your device yet, install it by following the official SideStore guide (it needs its companion app on a computer for the first install)."
                ),
                SideStoreStep(
                    order: 3,
                    title: "Open SideStore",
                    detail: "Open SideStore and go to the My Apps tab."
                ),
                SideStoreStep(
                    order: 4,
                    title: "Import the IPA",
                    detail: "Tap the + button, browse to the SideStoreExports folder in Files, and choose the exported IPA."
                ),
                SideStoreStep(
                    order: 5,
                    title: "Sign in with your Apple ID",
                    detail: "SideStore asks for your Apple ID and password to sign the app. A free Apple ID works; SideStore sends the credentials only to Apple."
                ),
                SideStoreStep(
                    order: 6,
                    title: "Wait for signing and installation",
                    detail: "SideStore signs the IPA and installs it. Keep SideStore open until the app icon appears on your Home Screen."
                ),
                SideStoreStep(
                    order: 7,
                    title: "Trust the developer certificate",
                    detail: "On first launch, iOS may block the app. Go to Settings > General > VPN & Device Management, tap your Apple ID under Developer App, and tap Trust."
                ),
                SideStoreStep(
                    order: 8,
                    title: "Refresh before expiry",
                    detail: "Apps signed with a free Apple ID expire after 7 days. Open SideStore before then and refresh the app (SideStore can refresh automatically when your device is on the same Wi-Fi as the companion).",
                    isOptional: true
                )
            ],
            limits: [
                SideStoreLimit(
                    name: "Free Apple ID app lifetime",
                    value: "7 days",
                    note: "Apps signed with a free Apple ID stop launching after 7 days unless refreshed. This is Apple's limit and may change."
                ),
                SideStoreLimit(
                    name: "Free Apple ID app limit",
                    value: "3 apps",
                    note: "A free Apple ID can have at most 3 sideloaded apps installed at a time (SideStore itself counts as one). This is Apple's limit and may change."
                ),
                SideStoreLimit(
                    name: "Refresh",
                    value: "Before expiry",
                    note: "SideStore can refresh apps automatically when the device is on the same Wi-Fi network as the SideStore companion; otherwise refresh manually in SideStore."
                )
            ],
            footerNote: "Ksign Next only exports the IPA file. Signing with your Apple ID and installation are done by SideStore, on your device."
        )
    }
}

/// The result of a successful SideStore export.
public struct SideStoreExport: Sendable, Equatable {
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let exportedAt: Date

    public init(fileURL: URL, fileName: String, fileSize: Int64, exportedAt: Date) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.exportedAt = exportedAt
    }
}

// MARK: - Export

/// Failures while exporting an IPA for SideStore.
public enum SideStoreExportError: Error, LocalizedError, Equatable {
    case fileNotFound(URL)
    case notAnIPA(URL)
    case emptyFile(URL)
    case invalidZIPMagic(URL)
    case exportsDirectoryUnavailable
    case copyFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "IPA file not found: \(url.lastPathComponent)"
        case .notAnIPA(let url):
            return "Not an IPA file: \(url.lastPathComponent)"
        case .emptyFile(let url):
            return "IPA file is empty: \(url.lastPathComponent)"
        case .invalidZIPMagic(let url):
            return "File does not look like an IPA (missing ZIP header): \(url.lastPathComponent)"
        case .exportsDirectoryUnavailable:
            return "Could not locate the Documents directory for the SideStore export."
        case .copyFailed(let url, let detail):
            return "Could not copy the IPA to \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Exports a signed IPA into the Files-visible `Documents/SideStoreExports`
/// folder so the user can pick it from SideStore's file importer.
public struct SideStoreExporter {

    /// The first four bytes of every ZIP archive (and therefore every IPA).
    public static let zipMagic: Data = Data([0x50, 0x4B, 0x03, 0x04])

    /// The Files-visible folder exports go to.
    public static func exportsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw SideStoreExportError.exportsDirectoryUnavailable
        }
        return documents.appendingPathComponent("SideStoreExports", isDirectory: true)
    }

    /// Validates the IPA (exists, `.ipa` extension, non-empty, ZIP magic)
    /// and copies it to the exports folder, returning the export record.
    /// An existing file of the same name is never overwritten; a numbered
    /// name is used instead.
    public static func export(ipaURL: URL, fileName: String? = nil, to directory: URL? = nil) throws -> SideStoreExport {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: ipaURL.path) else {
            throw SideStoreExportError.fileNotFound(ipaURL)
        }
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw SideStoreExportError.notAnIPA(ipaURL)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: ipaURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw SideStoreExportError.emptyFile(ipaURL)
        }
        let magic: Data
        do {
            let handle = try FileHandle(forReadingFrom: ipaURL)
            defer { try? handle.close() }
            magic = try handle.read(upToCount: 4) ?? Data()
        } catch {
            throw SideStoreExportError.invalidZIPMagic(ipaURL)
        }
        guard magic == zipMagic else {
            throw SideStoreExportError.invalidZIPMagic(ipaURL)
        }

        let targetDirectory = try directory ?? exportsDirectory()
        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        } catch {
            throw SideStoreExportError.copyFailed(targetDirectory, error.localizedDescription)
        }
        let resolvedName = resolvedFileName(requested: fileName, fallback: ipaURL.lastPathComponent)
        let destination = uniqueDestinationURL(in: targetDirectory, fileName: resolvedName)
        do {
            try fileManager.copyItem(at: ipaURL, to: destination)
        } catch {
            throw SideStoreExportError.copyFailed(destination, error.localizedDescription)
        }
        return SideStoreExport(
            fileURL: destination,
            fileName: destination.lastPathComponent,
            fileSize: size,
            exportedAt: Date()
        )
    }

    // MARK: Helpers

    /// Strips directory components from a requested name and guarantees a
    /// `.ipa` extension.
    private static func resolvedFileName(requested: String?, fallback: String) -> String {
        let raw = (requested ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        let component = URL(fileURLWithPath: raw.isEmpty ? fallback : raw).lastPathComponent
        if component.lowercased().hasSuffix(".ipa") {
            return component
        }
        return component + ".ipa"
    }

    private static func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        let base = directory.appendingPathComponent(fileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) (\(index)).ipa", isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
