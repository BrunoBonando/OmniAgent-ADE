import Foundation

/// Whether the app's WKWebViews (browser pane, editor pane, review-panel
/// browser) expose Safari's Web Inspector. Always in Debug; in Release only
/// when a developer opts in with
/// `defaults write digital.bruno.omniagent OMNIAGENT_WEB_INSPECTOR -bool YES`
/// — a shipped app should not carry a debug surface by default
/// (docs/appstore-rejection-risks.html, "Release WebViews are inspectable").
enum WebInspectorPolicy {
    static let defaultsKey = "OMNIAGENT_WEB_INSPECTOR"

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func isEnabled(defaults: UserDefaults = .standard, debugBuild: Bool = isDebugBuild) -> Bool {
        debugBuild || defaults.bool(forKey: defaultsKey)
    }
}
