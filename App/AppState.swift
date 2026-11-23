import Combine
import Foundation

/// App-wide observable state (UI layer). Owns no signing / file /
/// parsing logic — it only surfaces state the views need.
@MainActor
public final class AppState: ObservableObject {
    @Published public var isBusy: Bool = false
    @Published public var busyMessage: String?
    @Published public var lastError: AppError?
    @Published public var activeOperationID: UUID?
    @Published public var isOffline: Bool = false
    @Published public var hasLoadedData: Bool = false

    public let configuration: AppConfiguration

    public init(configuration: AppConfiguration = .fromBundle()) {
        self.configuration = configuration
    }

    public func beginOperation(_ message: String, operationID: UUID = UUID()) -> UUID {
        isBusy = true
        busyMessage = message
        activeOperationID = operationID
        lastError = nil
        return operationID
    }

    public func endOperation() {
        isBusy = false
        busyMessage = nil
        activeOperationID = nil
    }

    public func reportError(_ error: Error) {
        if let appError = error as? AppError {
            lastError = appError
        } else {
            lastError = .unknown(underlying: error.localizedDescription)
        }
        isBusy = false
        busyMessage = nil
        activeOperationID = nil
    }

    public func clearError() {
        lastError = nil
    }
}
