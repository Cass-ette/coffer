import XCTest
@testable import CofferCore

final class LockPolicyTests: XCTestCase {
    func testNeverLocksWhenAlreadyLocked() {
        XCTAssertFalse(LockPolicy(autoLockSeconds: 60)
            .shouldLock(isUnlocked: false, idleSeconds: 9999))
    }

    func testZeroIntervalMeansNever() {
        XCTAssertFalse(LockPolicy(autoLockSeconds: 0)
            .shouldLock(isUnlocked: true, idleSeconds: 9999))
    }

    func testBelowThresholdDoesNotLock() {
        XCTAssertFalse(LockPolicy(autoLockSeconds: 60)
            .shouldLock(isUnlocked: true, idleSeconds: 59.9))
    }

    func testLocksAtExactThreshold() {
        XCTAssertTrue(LockPolicy(autoLockSeconds: 60)
            .shouldLock(isUnlocked: true, idleSeconds: 60))
    }

    func testLocksBeyondThreshold() {
        XCTAssertTrue(LockPolicy(autoLockSeconds: 60)
            .shouldLock(isUnlocked: true, idleSeconds: 300))
    }
}
