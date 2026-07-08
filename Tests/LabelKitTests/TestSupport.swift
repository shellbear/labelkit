import Foundation
import XCTest

extension XCTestCase {
    /// Skip a test when running under CI.
    ///
    /// Vision requests crash (SIGSEGV) on the GitHub Actions **macOS 14** image —
    /// the headless runner there lacks whatever session the ML/Neural-Engine
    /// backed requests need — while the macOS 15 image runs the exact same tests
    /// green. Rather than couple green CI to one runner image, the tests that
    /// drive the real Vision pipeline skip under CI and are covered by local
    /// runs instead (the same trade-off `CoreMLBoxDetectorTests` already makes).
    /// GitHub Actions sets `CI=true`.
    func skipIfCI(_ reason: String = "exercises Vision, which is unstable on CI runners") throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, reason)
    }
}
