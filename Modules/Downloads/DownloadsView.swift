import SwiftUI

enum DownloadState: String, Equatable { case queued, downloading, paused, completed, failed, cancelled }

struct DownloadItem: Identifiable, Equatable {
    let id = UUID()
    var urlString: String
    var fileName: String
    var progress: Double = 0
    var state: DownloadState = .queued
    var speedBytesPerSecond: Int64 = 0
    var etaSeconds: Int?
    var errorMessage: String?
    var task: URLSessionDownloadTask?
    var startDate: Date?

    var etaText: String {
        guard let eta = etaSeconds, state == .downloading else { return "—" }
        return String(format: NSLocalizedString("downloads.eta", comment: ""), eta)
    }
}

@MainActor
final class DownloadsViewModel: ObservableObject {
    @Published var downloads: [DownloadItem] = []
    @Published var newURLString = ""
    @Published var errorMessage: String?
    private var progressTimer: Timer?

    func addDownload() {
        let trimmed = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" else {
            errorMessage = NSLocalizedString("downloads.error.url", comment: ""); return
        }
        var item = DownloadItem(urlString: trimmed, fileName: url.lastPathComponent.isEmpty ? "download.ipa" : url.lastPathComponent)
        item.state = .downloading
        item.startDate = Date()
        downloads.append(item)
        newURLString = ""
        startTask(for: item.id, url: url)
        startProgressTimer()
    }

    private func startTask(for id: UUID, url: URL) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            Task { @MainActor in
                guard let self, let idx = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                if let error {
                    self.downloads[idx].state = .failed
                    self.downloads[idx].errorMessage = error.localizedDescription
                    return
                }
                guard let tempURL, let destDir = Workspace.folder("Downloads") else {
                    self.downloads[idx].state = .failed
                    self.downloads[idx].errorMessage = NSLocalizedString("error.documents.unavailable", comment: "")
                    return
                }
                let dest = destDir.appendingPathComponent(self.downloads[idx].fileName)
                do {
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    self.downloads[idx].state = .completed
                    self.downloads[idx].progress = 1
                } catch {
                    self.downloads[idx].state = .failed
                    self.downloads[idx].errorMessage = error.localizedDescription
                }
            }
        }
        downloads[index].task = task
        task.resume()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollProgress() }
        }
    }

    private func pollProgress() {
        for index in downloads.indices where downloads[index].state == .downloading {
            if let task = downloads[index].task {
                let progress = task.progress
                downloads[index].progress = progress.fractionCompleted
                downloads[index].speedBytesPerSecond = Int64(progress.throughput ?? 0)
                if progress.fractionCompleted > 0, progress.totalUnitCount > 0 {
                    let total = progress.totalUnitCount
                    let remaining = Double(total) * (1 - progress.fractionCompleted)
                    let throughput = Double(max(downloads[index].speedBytesPerSecond, 1))
                    downloads[index].etaSeconds = Int(remaining / throughput)
                }
            }
        }
        if !downloads.contains(where: { $0.state == .downloading }) { progressTimer?.invalidate() }
    }

    func pause(_ item: DownloadItem) {
        guard let index = downloads.firstIndex(where: { $0.id == item.id }) else { return }
        downloads[index].task?.suspend()
        downloads[index].state = .paused
    }

    func resume(_ item: DownloadItem) {
        guard let index = downloads.firstIndex(where: { $0.id == item.id }) else { return }
        if downloads[index].state == .failed {
            guard let url = URL(string: downloads[index].urlString) else { return }
            downloads[index].state = .downloading
            downloads[index].errorMessage = nil
            startTask(for: item.id, url: url)
        } else {
            downloads[index].task?.resume()
            downloads[index].state = .downloading
            startProgressTimer()
        }
    }

    func retry(_ item: DownloadItem) { resume(item) }

    func delete(_ item: DownloadItem) {
        downloads.first(where: { $0.id == item.id })?.task?.cancel()
        downloads.removeAll { $0.id == item.id }
    }
}

struct DownloadsView: View {
    @StateObject private var viewModel = DownloadsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField(NSLocalizedString("downloads.url.placeholder", comment: ""), text: $viewModel.newURLString)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .accessibilityIdentifier("downloads.urlField")
                    Button(NSLocalizedString("downloads.add", comment: "")) { viewModel.addDownload() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("downloads.add")
                }
                .padding()
                if viewModel.downloads.isEmpty {
                    EmptyStateView(
                        NSLocalizedString("downloads.empty", comment: ""),
                        systemImage: "arrow.down.circle",
                        description: Text(NSLocalizedString("downloads.empty.detail", comment: ""))
                    )
                } else {
                    List(viewModel.downloads) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.fileName).lineLimit(1)
                                Spacer()
                                Text(item.state.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: item.progress)
                                .accessibilityIdentifier("downloads.progress.\(item.fileName)")
                            HStack {
                                Text(Workspace.fileSizeString(item.speedBytesPerSecond) + "/s").font(.caption)
                                Spacer()
                                Text(item.etaText).font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                            HStack {
                                switch item.state {
                                case .downloading:
                                    Button(NSLocalizedString("downloads.pause", comment: "")) { viewModel.pause(item) }
                                case .paused:
                                    Button(NSLocalizedString("downloads.resume", comment: "")) { viewModel.resume(item) }
                                case .failed:
                                    Button(NSLocalizedString("downloads.retry", comment: "")) { viewModel.retry(item) }
                                default: EmptyView()
                                }
                                Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) { viewModel.delete(item) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tab.downloads", comment: ""))
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }
}
