import SwiftUI

enum DownloadState: String, Equatable { case queued, downloading, paused, completed, failed, cancelled }

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    var urlString: String
    var fileName: String
    var progress: Double = 0
    var state: DownloadState = .queued
    var speedBytesPerSecond: Int64 = 0
    var etaSeconds: Int?
    var errorMessage: String?
    var startDate: Date?

    init(id: UUID = UUID(), urlString: String, fileName: String, progress: Double = 0,
         state: DownloadState = .queued, speedBytesPerSecond: Int64 = 0, etaSeconds: Int? = nil,
         errorMessage: String? = nil, startDate: Date? = nil) {
        self.id = id
        self.urlString = urlString
        self.fileName = fileName
        self.progress = progress
        self.state = state
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.errorMessage = errorMessage
        self.startDate = startDate
    }

    /// Builds a row from an engine snapshot. The engine task's id is
    /// the row id, so later snapshots merge into the same row.
    init(task: DownloadTask) {
        self.id = task.id
        self.urlString = task.url.absoluteString
        self.fileName = task.fileName
        self.progress = task.progress
        self.state = DownloadState(task.status)
        self.speedBytesPerSecond = Int64(task.speed)
        self.etaSeconds = task.eta.map { Int($0) }
        self.errorMessage = task.errorDescription
        self.startDate = task.createdAt
    }

    /// Applies a newer engine snapshot to this row.
    mutating func apply(_ task: DownloadTask) {
        progress = task.progress
        state = DownloadState(task.status)
        speedBytesPerSecond = Int64(task.speed)
        etaSeconds = task.eta.map { Int($0) }
        errorMessage = task.errorDescription
    }

    var etaText: String {
        guard let eta = etaSeconds, state == .downloading else { return "—" }
        return String(format: NSLocalizedString("downloads.eta", comment: ""), eta)
    }
}

extension DownloadState {
    init(_ status: DownloadStatus) {
        switch status {
        case .pending, .queued: self = .queued
        case .downloading: self = .downloading
        case .paused: self = .paused
        case .completed: self = .completed
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

/// Downloads screen, driven by the real `DownloadEngine` (queue,
/// concurrency limit, pause/resume/retry, SHA-256 check, background
/// session) instead of raw `URLSession` tasks in the view. The engine
/// owns the work; this model only mirrors its snapshots into rows.
@MainActor
final class DownloadsViewModel: ObservableObject {
    @Published var downloads: [DownloadItem] = []
    @Published var newURLString = ""
    @Published var errorMessage: String?

    private let engine: DownloadEngine
    /// Engine task ids backing local rows. Rows without one (e.g. set
    /// directly by tests) are managed locally only and never sent to
    /// the engine.
    private var engineTaskIDs: Set<UUID> = []
    private var updatesTask: Task<Void, Never>?

    /// - Parameter container: the app's container; nil builds a fresh
    ///   `DownloadEngine` (tests / previews).
    init(container: DependencyContainer? = nil) {
        let engine = container?.downloadEngine ?? DownloadEngine()
        self.engine = engine
        // Re-sync the Settings concurrency limit: the container sets
        // it at launch, but the user may have moved the stepper since.
        let saved = UserDefaults.standard.integer(forKey: "ksign.downloads.maxConcurrent")
        let limit = saved == 0 ? 2 : saved
        Task { [engine] in await engine.setMaxConcurrentDownloads(limit) }
    }

    deinit { updatesTask?.cancel() }

    /// Starts listening to the engine's task stream. Called once from
    /// the view; safe to call again (the previous subscription is
    /// replaced). Runs detached so the observation task never retains
    /// this model.
    func startObserving() {
        updatesTask?.cancel()
        updatesTask = Task.detached { [weak self, engine] in
            let initial = await engine.allTasks()
            await MainActor.run { self?.merge(initial) }
            for await tasks in await engine.updates() {
                if Task.isCancelled { break }
                await MainActor.run { self?.merge(tasks) }
            }
        }
    }

    /// Merges engine snapshots into the local rows, by engine task id.
    /// Rows whose engine task vanished are dropped; local-only rows
    /// are left alone.
    private func merge(_ tasks: [DownloadTask]) {
        for task in tasks {
            engineTaskIDs.insert(task.id)
            if let index = downloads.firstIndex(where: { $0.id == task.id }) {
                downloads[index].apply(task)
            } else {
                downloads.append(DownloadItem(task: task))
            }
        }
        downloads.removeAll { item in
            engineTaskIDs.contains(item.id) && !tasks.contains(where: { $0.id == item.id })
        }
    }

    func addDownload() {
        let trimmed = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" else {
            errorMessage = NSLocalizedString("downloads.error.url", comment: ""); return
        }
        newURLString = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let task = try await engine.enqueue(url: url)
                self.merge([task])
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func pause(_ item: DownloadItem) {
        guard let index = downloads.firstIndex(where: { $0.id == item.id }) else { return }
        downloads[index].state = .paused
        if engineTaskIDs.contains(item.id) {
            Task { [engine] in await engine.pause(id: item.id) }
        }
    }

    func resume(_ item: DownloadItem) {
        guard let index = downloads.firstIndex(where: { $0.id == item.id }) else { return }
        if engineTaskIDs.contains(item.id) {
            downloads[index].state = .downloading
            downloads[index].errorMessage = nil
            Task { [engine] in await engine.resume(id: item.id) }
        } else if downloads[index].state == .failed {
            guard let url = URL(string: downloads[index].urlString) else { return }
            downloads[index].state = .downloading
            downloads[index].errorMessage = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    let task = try await engine.enqueue(url: url)
                    self.merge([task])
                } catch { self.errorMessage = error.localizedDescription }
            }
        } else {
            downloads[index].state = .downloading
        }
    }

    func retry(_ item: DownloadItem) {
        if engineTaskIDs.contains(item.id) {
            Task { [engine] in await engine.retry(id: item.id) }
        } else {
            resume(item)
        }
    }

    func delete(_ item: DownloadItem) {
        if engineTaskIDs.contains(item.id) {
            engineTaskIDs.remove(item.id)
            Task { [engine] in
                await engine.cancel(id: item.id)
                try? await engine.removeTask(id: item.id)
            }
        }
        downloads.removeAll { $0.id == item.id }
    }
}

struct DownloadsView: View {
    @StateObject private var viewModel: DownloadsViewModel

    /// - Parameter container: the app's container; nil builds a fresh
    ///   download engine (tests / previews).
    init(container: DependencyContainer? = nil) {
        _viewModel = StateObject(wrappedValue: DownloadsViewModel(container: container))
    }

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
            .task { viewModel.startObserving() }
            .alert(NSLocalizedString("alert.error.title", comment: ""), isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
            } message: { Text(viewModel.errorMessage ?? "") }
        }
    }
}
