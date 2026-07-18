import Foundation

enum AppConstants {

    // MARK: - Polling

    /// How often the status polling loop fires while a scan is running.
    static let statusPollingInterval: Duration = .seconds(2)

    /// How often the ETA estimate is recalculated and shown to the user.
    /// Kept low-frequency because the estimate is noisy early in a scan.
    static let etaRefreshInterval: TimeInterval = 10
}
