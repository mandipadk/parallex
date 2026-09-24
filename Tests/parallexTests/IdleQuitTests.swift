import XCTest
@testable import ParallexCore

final class IdleQuitTests: XCTestCase {
    func testDueOnlyWhenUnusedPastTheLimit() {
        let now = Date()
        XCTAssertTrue(IdleQuit.isDue(limitMinutes: 15, lastInFront: now.addingTimeInterval(-16 * 60), isFront: false, now: now))
        XCTAssertFalse(IdleQuit.isDue(limitMinutes: 15, lastInFront: now.addingTimeInterval(-14 * 60), isFront: false, now: now))
        XCTAssertFalse(IdleQuit.isDue(limitMinutes: 15, lastInFront: now.addingTimeInterval(-60 * 60), isFront: true, now: now), "in front now")
        XCTAssertFalse(IdleQuit.isDue(limitMinutes: nil, lastInFront: .distantPast, isFront: false, now: now), "off")
    }

    func testWords() {
        XCTAssertEqual(IdleQuit.describe(15), "15 minutes")
        XCTAssertEqual(IdleQuit.describe(60), "1 hour")
        XCTAssertEqual(IdleQuit.describe(240), "4 hours")
        XCTAssertEqual(IdleQuit.describe(90), "90 minutes")
        XCTAssertEqual(IdleQuit.choices(including: 30), [15, 30, 60, 240])
        XCTAssertEqual(IdleQuit.choices(including: 60), [15, 60, 240])
    }

    /// Core Audio answers (who's playing depends on the Mac; it must not fail).
    func testFindsWhatsPlayingWithoutFailing() {
        XCTAssertEqual(IdleQuit.processesPlayingSound() != nil, IdleQuit.isAvailable)
    }
}
