#if DEBUG
import Foundation

/// Debug builds only (never in TestFlight): sign the simulator in to a local sandbox bridge from launch
/// arguments, so an agent can screenshot every real screen without tapping through pairing.
///
///     xcrun simctl launch <udid> <bundle> -HMReviewServer http://127.0.0.1:9141 -HMReviewToken <token> -HMReviewTab 0
enum DesignReview {
    @MainActor static func signInIfAsked(_ app: AppModel) {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: "HMReviewServer"), let server = URL(string: raw),
              let token = d.string(forKey: "HMReviewToken"), !token.isEmpty else { return }
        try? app.connect(GatewayLogin(server: server, token: token))
    }
}
#endif
