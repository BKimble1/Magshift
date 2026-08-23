import UIKit

/// Opens this app's page in Settings.
///
/// Used only where it genuinely helps -- a denied camera permission -- and never
/// offered when there is nothing for the user to change there.
enum SystemSettings {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url)
    }
}
