import Foundation

// MARK: - ExternalInstallerGuide
//
// IPA export + the ordered guide for importing a signed IPA into the
// installer app on the user's device. This file holds models and the
// export operation; it contains no UI. The UI renders
// `ExternalInstallerGuide.standard()` as steps.
//
// No installer app is named anywhere in this file, in the UI, or in
// the localised strings: the user picks their own installer. Free
// Apple-account limits documented below (7 days, 3 apps) are Apple's
// limits and may change; they are stated here as documented facts,
// not as values this code enforces.

// MARK: - Models

/// One ordered step of the external-installer import guide.
public struct InstallerStep: Identifiable, Codable, Sendable, Equatable {
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

/// One documented limit that applies to the free-account install flow.
public struct InstallerLimit: Codable, Sendable, Equatable {
    public let name: String
    public let value: String
    public let note: String

    public init(name: String, value: String, note: String) {
        self.name = name
        self.value = value
        self.note = note
    }
}

/// The complete installer guide: ordered steps plus the limits the
/// user should know about before starting.
public struct ExternalInstallerGuide: Sendable, Equatable {
    public let title: String
    public let introduction: String
    public let steps: [InstallerStep]
    public let limits: [InstallerLimit]
    public let footerNote: String

    public init(
        title: String,
        introduction: String,
        steps: [InstallerStep],
        limits: [InstallerLimit],
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
    public static func standard() -> ExternalInstallerGuide {
        ExternalInstallerGuide(
            title: "Install with an external installer",
            introduction: "Export the signed IPA from Ksign Next, then import it into the installer app on your device. The installer signs the app with your Apple ID and installs it.",
            steps: [
                InstallerStep(
                    order: 1,
                    title: "Export the IPA",
                    detail: "In Ksign Next, choose the signed app and tap Export IPA. The IPA is saved to the IPAExports folder in Files."
                ),
                InstallerStep(
                    order: 2,
                    title: "Have an installer app",
                    detail: "You need an installer app on your device to install an IPA. Set one up first if you do not have one."
                ),
                InstallerStep(
                    order: 3,
                    title: "Open the installer app",
                    detail: "Open your installer app."
                ),
                InstallerStep(
                    order: 4,
                    title: "Import the IPA",
                    detail: "Import the exported IPA from the IPAExports folder in Files."
                ),
                InstallerStep(
                    order: 5,
                    title: "Sign in with your Apple ID",
                    detail: "The installer asks for your Apple ID and password to sign the app. A free Apple ID works; the credentials go only to Apple."
                ),
                InstallerStep(
                    order: 6,
                    title: "Wait for signing and installation",
                    detail: "The installer signs the IPA and installs it. Keep it open until the app icon appears on your Home Screen."
                ),
                InstallerStep(
                    order: 7,
                    title: "Trust the developer certificate",
                    detail: "On first launch, iOS may block the app. Go to Settings > General > VPN & Device Management, tap your Apple ID under Developer App, and tap Trust."
                ),
                InstallerStep(
                    order: 8,
                    title: "Refresh before expiry",
                    detail: "Apps signed with a free Apple ID expire after 7 days. Refresh the app in your installer app before then.",
                    isOptional: true
                )
            ],
            limits: [
                InstallerLimit(
                    name: "Free Apple ID app lifetime",
                    value: "7 days",
                    note: "Apps signed with a free Apple ID stop launching after 7 days unless refreshed. This is Apple's limit and may change."
                ),
                InstallerLimit(
                    name: "Free Apple ID app limit",
                    value: "3 apps",
                    note: "A free Apple ID can have at most 3 sideloaded apps installed at a time (the installer itself counts as one). This is Apple's limit and may change."
                ),
                InstallerLimit(
                    name: "Refresh",
                    value: "Before expiry",
                    note: "Refresh the app in your installer app before it expires; some installers can refresh automatically on the same Wi-Fi network."
                )
            ],
            footerNote: "Ksign Next only exports the IPA file. Signing with your Apple ID and installation happen in your installer app, on your device."
        )
    }
}

/// The result of a successful IPA export.
public struct IPAExport: Sendable, Equatable {
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

/// Failures while exporting an IPA.
public enum IPAExportError: Error, LocalizedError, Equatable {
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
            return "Could not locate the Documents directory for the IPA export."
        case .copyFailed(let url, let detail):
            return "Could not copy the IPA to \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Exports a signed IPA into the Files-visible `Documents/IPAExports`
/// folder so the user can pick it from their installer app's file importer.
public struct IPAExporter {

    /// The first four bytes of every ZIP archive (and therefore every IPA).
    public static let zipMagic: Data = Data([0x50, 0x4B, 0x03, 0x04])

    /// The Files-visible folder exports go to.
    public static func exportsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw IPAExportError.exportsDirectoryUnavailable
        }
        return documents.appendingPathComponent("IPAExports", isDirectory: true)
    }

    /// Validates the IPA (exists, `.ipa` extension, non-empty, ZIP magic)
    /// and copies it to the exports folder, returning the export record.
    /// An existing file of the same name is never overwritten; a numbered
    /// name is used instead.
    public static func export(ipaURL: URL, fileName: String? = nil, to directory: URL? = nil) throws -> IPAExport {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: ipaURL.path) else {
            throw IPAExportError.fileNotFound(ipaURL)
        }
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw IPAExportError.notAnIPA(ipaURL)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: ipaURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw IPAExportError.emptyFile(ipaURL)
        }
        let magic: Data
        do {
            let handle = try FileHandle(forReadingFrom: ipaURL)
            defer { try? handle.close() }
            magic = try handle.read(upToCount: 4) ?? Data()
        } catch {
            throw IPAExportError.invalidZIPMagic(ipaURL)
        }
        guard magic == zipMagic else {
            throw IPAExportError.invalidZIPMagic(ipaURL)
        }

        let targetDirectory = try directory ?? exportsDirectory()
        do {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        } catch {
            throw IPAExportError.copyFailed(targetDirectory, error.localizedDescription)
        }
        let resolvedName = resolvedFileName(requested: fileName, fallback: ipaURL.lastPathComponent)
        let destination = uniqueDestinationURL(in: targetDirectory, fileName: resolvedName)
        do {
            try fileManager.copyItem(at: ipaURL, to: destination)
        } catch {
            throw IPAExportError.copyFailed(destination, error.localizedDescription)
        }
        return IPAExport(
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
