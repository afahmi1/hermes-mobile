import SwiftUI
import UIKit

/// Shared values for the native SwiftUI surfaces. The accent comes from the app asset catalog.
enum HMDesign {
    static let micro: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
    static let touch: CGFloat = 44

    static let panelRadius: CGFloat = 12
    static let messageRadius: CGFloat = 20

    static let rowTitle: Font = .body.weight(.semibold)
    static let metadata: Font = .footnote
    static let panel = Color(uiColor: .secondarySystemBackground)
    static let selectedFill = Color.accentColor.opacity(0.14)
}

extension View {
    /// Apply to a custom control's label so the full frame is interactive.
    func hmTouchTarget() -> some View {
        frame(minWidth: HMDesign.touch, minHeight: HMDesign.touch)
            .contentShape(Rectangle())
    }
}

/// Title on the left, state or time on the right. Falls back to a stack when the two do not fit,
/// so identifying text keeps its width at large text sizes.
struct AdaptiveTitleRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: HMDesign.small) {
                leading
                Spacer(minLength: HMDesign.small)
                trailing
            }
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                leading
                trailing
            }
        }
    }
}
