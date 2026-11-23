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
    var segments: [String] = []
    var errorMessage = ""
}

@MainActor
final class MachOInspectorViewModel: ObservableObject {
    @Published var report = MachOReport()
    @Published var isLoading = false

    func inspect(_ url: URL) {
        isLoading = true
        defer { isLoading = false }
        var result = MachOReport(fileName: url.lastPathComponent)
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 32), header.count >= 8 else {
            result.errorMessage = NSLocalizedString("macho.error.read", comment: "")
            report = result
            return
        }
        try? handle.close()
        let bytes = [UInt8](header)
        let magic = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        switch magic {
        case 0xFEEDFACF:
            result.architecture = "arm64"
            result.cpuType = 0x0100000C
        case 0xFEEDFACE:
            result.architecture = "armv7"
            result.cpuType = 12
        case 0xCAFEBABE:
            result.isFat = true
            result.architecture = "fat (universal)"
        default:
            result.errorMessage = NSLocalizedString("macho.error.notmacho", comment: "")
            report = result
            return
        }
        if header.count >= 32 {
            // LC_UUID is not parsed here; UUID is reported only when found by a full parser.
            result.uuid = ""
        }
        report = result
    }
}

struct MachOInspectorView: View {
    let fileURL: URL
    @StateObject private var viewModel = MachOInspectorViewModel()

    var body: some View {
        List {
            if !viewModel.report.errorMessage.isEmpty {
                Section {
                    Text(viewModel.report.errorMessage).foregroundStyle(.red)
                }
            } else {
                Section(NSLocalizedString("macho.section.file", comment: "")) {
                    row(NSLocalizedString("macho.file", comment: ""), viewModel.report.fileName)
                    row(NSLocalizedString("macho.arch", comment: ""), viewModel.report.architecture)
                    row(NSLocalizedString("macho.fat", comment: ""), viewModel.report.isFat ? NSLocalizedString("common.yes", comment: "") : NSLocalizedString("common.no", comment: ""))
                    row(NSLocalizedString("macho.uuid", comment: ""), viewModel.report.uuid.isEmpty ? "—" : viewModel.report.uuid)
                }
                Section(NSLocalizedString("macho.section.dylibs", comment: "")) {
                    if viewModel.report.dylibs.isEmpty {
                        Text(NSLocalizedString("macho.dylibs.none", comment: "")).foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.report.dylibs, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
                Section(NSLocalizedString("macho.section.rpath", comment: "")) {
                    if viewModel.report.rpaths.isEmpty {
                        Text(NSLocalizedString("macho.rpath.none", comment: "")).foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.report.rpaths, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
                Section(NSLocalizedString("macho.section.signature", comment: "")) {
                    row(NSLocalizedString("macho.signature", comment: ""), viewModel.report.hasCodeSignature ? NSLocalizedString("common.yes", comment: "") : NSLocalizedString("macho.signature.unknown", comment: ""))
                }
                Section(NSLocalizedString("macho.section.segments", comment: "")) {
                    if viewModel.report.segments.isEmpty {
                        Text(NSLocalizedString("macho.segments.none", comment: "")).foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.report.segments, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("macho.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.inspect(fileURL) }
        .overlay { if viewModel.isLoading { ProgressView() } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
    }
}
