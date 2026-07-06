import Foundation
import LabelKit

/// Parsed CLI configuration, set once by LabelKitCommand.run() before
/// LabelKitApp.main() starts the run loop. The one deliberately non-injected
/// global — everything downstream takes explicit parameters.
struct LaunchContext {
    static var current = LaunchContext(location: nil, imageGlob: nil)

    /// nil → the app shows an open panel.
    let location: DatasetLocation?
    let imageGlob: String?
}
