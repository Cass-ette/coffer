import Foundation

public struct LockPolicy: Equatable {
    /// 0 = 不自动锁定（spec §5.2 "不自动"档）
    public let autoLockSeconds: Int

    public init(autoLockSeconds: Int) {
        self.autoLockSeconds = autoLockSeconds
    }

    public func shouldLock(isUnlocked: Bool, idleSeconds: TimeInterval) -> Bool {
        guard isUnlocked, autoLockSeconds > 0 else { return false }
        return idleSeconds >= TimeInterval(autoLockSeconds)
    }
}
