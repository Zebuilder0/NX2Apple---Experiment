import XCTest
@testable import NXCore

/// "Update the launcher when a device connects": which app is signed again on its own, and when.
final class AutoResignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDueOnlyWithinTheWindow() {
        XCTAssertFalse(AutoResign.due(expiry: nil, now: now))
        XCTAssertFalse(AutoResign.due(expiry: now.addingTimeInterval(3 * 24 * 3600), now: now))
        XCTAssertTrue(AutoResign.due(expiry: now.addingTimeInterval(24 * 3600), now: now))
        XCTAssertTrue(AutoResign.due(expiry: now.addingTimeInterval(-60), now: now))   // already expired
    }

    func testNextNeedsACableAndADueProfile() {
        let later = AutoResign.Candidate(id: UUID(), device: "A", expiry: now.addingTimeInterval(6 * 24 * 3600))
        let soon = AutoResign.Candidate(id: UUID(), device: "B", expiry: now.addingTimeInterval(3600))
        let nowhere = AutoResign.Candidate(id: UUID(), device: "", expiry: now.addingTimeInterval(3600))
        XCTAssertNil(AutoResign.next([later, soon, nowhere], wired: ["A"], now: now))
        XCTAssertEqual(AutoResign.next([later, soon, nowhere], wired: ["A", "B"], now: now), soon)
        XCTAssertNil(AutoResign.next([soon], wired: [], now: now))
    }
}
