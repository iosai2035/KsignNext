import SwiftUI

/// Minimal Mach-O report produced locally (magic + CPU type from the header).
struct MachOReport: Equatable {
    var fileName = ""
    var architecture = ""
    var cpuType: Int32 = 0
    var isFat = false
    var uuid = ""
    var dylibs: [String] = []
    var rpaths: [String] = []
    var hasCodeSignature = false
    /// True only when a load-command walk actually ran, so "no signature"
    /// is never confused with "signature not checked".
    var signatureChecked = false
    var segments: [String] = []
    var errorMessage = ""
}

@MainActor
final class MachOInspectorViewModel: ObservableObject {
    @Published var report = MachOReport()

    /// Parses synchronously (a header + load-command read is a fast local
    /// file read, so there is no loading state to show). The full parser
    /// in `MachOEngine` walks the load commands, so UUID, dylibs, RPATHs,
    /// segments and the code signature all come from real load commands;
    /// its fat-binary handling reads the big-endian fat header
    /// (magic CA FE BA BE, big-endian arch table). If the full parse
    /// fails (e.g. a header-only file in tests), fall back to a
    /// magic-only read so the architecture is still reported instead
    /// of an error.
    func inspect(_ url: URL) {
        var result = MachOReport(fileName: url.lastPathComponent)
        if let file = try? MachOEngine().parseMachO(at: url) {
            result.isFat = file.isFat
            result.architecture = file.isFat
                ? file.architectures.map(\.cpuTypeName).joined(separator: ", ")
                : file.cpuTypeName
            result.cpuType = Int32(bitPattern: file.cpuType)
            result.uuid = file.uuid ?? ""
            result.dylibs = file.dylibs.map(\.name)
            result.rpaths = file.rpaths
            result.hasCodeSignature = file.hasCodeSignature
            result.signatureChecked = true
            result.segments = file.segments.map(\.name)
            report = result
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 64), header.count >= 8 else {
            result.errorMessage = NSLocalizedString("macho.error.read", comment: "")
            report = result
            return
        }
        try? handle.close()
        let bytes = [UInt8](header)
        // Thin magics are little-endian on disk; the fat magic is stored
        // big-endian (bytes CA FE BA BE), so compare raw bytes for fat
        // instead of reading it little-endian (which would be 0xBEBAFECA).
        if bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBE {
            result.isFat = true
            result.architecture = "fat (universal)"
            if header.count >= 12 {
                let nfatArch = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
                if nfatArch > 0, header.count >= 16 {
                    let cpuType = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
                    result.architecture = "fat (universal) — \(MachOParser.cpuTypeName(cpuType, subtype: 0))"
                }
            }
            report = result
            return
        }
        let magic = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        switch magic {
        case 0xFEEDFACF:
            result.architecture = "arm64"
            result.cpuType = 0x0100000C
        case 0xFEEDFACE:
            result.architecture = "armv7"
            result.cpuType = 12
        default:
            result.errorMessage = NSLocalizedString("macho.error.notmacho", comment: "")
            report = result
            return
        }
        report = result
    }
}

struct MachOInspectorView: View {
    let fileURL: URL
    @StateObject private var viewModel = MachOInspectorViewModel()

    var body: some View {
        Group {
            if !viewModel.report.errorMessage.isEmpty {
                EmptyStateView(
                    NSLocalizedString("macho.error.title", comment: ""),
                    systemImage: "exclamationmark.triangle",
                    description: Text(viewModel.report.errorMessage)
                )
            } else {
                List {
                    Section(NSLocalizedString("macho.section.file", comment: "")) {
                        row(NSLocalizedString("macho.file", comment: ""), viewModel.report.fileName)
                        row(NSLocalizedString("macho.arch", comment: ""), viewModel.report.architecture)
                        row(NSLocalizedString("macho.fat", comment: ""), viewModel.report.isFat ? NSLocalizedString("common.yes", comment: "") : NSLocalizedString("common.no", comment: ""))
                        row(NSLocalizedString("macho.uuid", comment: ""), viewModel.report.uuid.isEmpty ? "—" : viewModel.report.uuid)
                    }
                    Section(NSLocalizedString("macho.section.dylibs", comment: "")) {
                        if viewModel.report.dylibs.isEmpty {
                            EmptyStateView(
                                NSLocalizedString("macho.dylibs.none", comment: ""),
                                systemImage: "link"
                            )
                        } else {
                            ForEach(viewModel.report.dylibs, id: \.self) { Text($0).font(.caption.monospaced()) }
                        }
                    }
                    Section(NSLocalizedString("macho.section.rpath", comment: "")) {
                        if viewModel.report.rpaths.isEmpty {
                            EmptyStateView(
                                NSLocalizedString("macho.rpath.none", comment: ""),
                                systemImage: "arrow.up.right"
                            )
                        } else {
                            ForEach(viewModel.report.rpaths, id: \.self) { Text($0).font(.caption.monospaced()) }
                        }
                    }
                    Section(NSLocalizedString("macho.section.signature", comment: "")) {
                        row(NSLocalizedString("macho.signature", comment: ""), signatureText)
                    }
                    Section(NSLocalizedString("macho.section.segments", comment: "")) {
                        if viewModel.report.segments.isEmpty {
                            EmptyStateView(
                                NSLocalizedString("macho.segments.none", comment: ""),
                                systemImage: "square.stack.3d"
                            )
                        } else {
                            ForEach(viewModel.report.segments, id: \.self) { Text($0).font(.caption.monospaced()) }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("macho.title", comment: ""))
        .dsInlineTitle()
        .onAppear { viewModel.inspect(fileURL) }
    }

    private var signatureText: String {
        if viewModel.report.hasCodeSignature { return NSLocalizedString("common.yes", comment: "") }
        if viewModel.report.signatureChecked { return NSLocalizedString("common.no", comment: "") }
        return NSLocalizedString("macho.signature.unknown", comment: "")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
    }
}
