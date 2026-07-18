import Foundation

enum AppConstants {

    // MARK: - Polling

    /// How often the status polling loop fires while a scan is running.
    static let statusPollingInterval: Duration = .seconds(2)

    /// How often the ETA estimate is recalculated and shown to the user.
    /// Kept low-frequency because the estimate is noisy early in a scan.
    static let etaRefreshInterval: TimeInterval = 10

    // MARK: - Server startup

    /// How often we ping the Python backend to check if it has finished launching.
    static let serverStartupPollInterval: Duration = .seconds(1)

    // MARK: - UI animation

    /// Tick rate for the "Starting…" dot animation on the launch screen.
    static let dotAnimationInterval: Duration = .milliseconds(500)
}
