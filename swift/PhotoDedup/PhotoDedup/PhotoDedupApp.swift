import SwiftUI

@main
struct PhotoDedupApp: App {
    var body: some Scene {
        WindowGroup {
            ClusterListView()
        }
        .defaultSize(width: 1200, height: 800)
    }
}
