import SwiftUI

/// Single place to control the app's font scale.
/// To shift everything, change `base` and `small` — all views reference these.
enum AppFont {
    static let small:  Font = .subheadline  // secondary metadata  (was .footnote)
    static let base:   Font = .callout      // primary UI text     (was .subheadline)
    static let label:  Font = .body         // prominent labels    (was .callout)
}

