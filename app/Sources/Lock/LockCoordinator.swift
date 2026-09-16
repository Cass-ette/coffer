import AppKit
import CofferCore

/// spec §5.2：闲置自动锁定 + 系统事件立即锁定（不依赖闲置计时）。
/// 仅在解锁态运行——由 AppState 在 phase 变化时启停。
@MainActor
final class LockCoordinator {
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private let onLock: () -> Void
    private let systemIdleSeconds: () -> TimeInterval
    private var policy = LockPolicy(autoLockSeconds: 0)

    init(onLock: @escaping () -> Void,
         systemIdleSeconds: @escaping () -> TimeInterval = LockCoordinator.readSystemIdle) {
        self.onLock = onLock
        self.systemIdleSeconds = systemIdleSeconds
    }

    /// CGEventSource 公开 API：距上次键鼠事件的秒数，无需辅助功能权限
    static func readSystemIdle() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    /// 间隔变化时调用；0 = 停止闲置轮询
    func updatePolicy(autoLockSeconds: Int) {
        policy = LockPolicy(autoLockSeconds: autoLockSeconds)
        if pollTimer != nil, autoLockSeconds <= 0 {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil, autoLockSeconds > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.policy.shouldLock(isUnlocked: true,
                                              idleSeconds: self.systemIdleSeconds()) {
                        self.onLock()
                    }
                }
            }
        }
    }

    /// 系统事件（睡眠/锁屏/切用户/屏保）→ 立即锁定
    func startEventObservers() {
        guard workspaceObservers.isEmpty else { return }
        let immediate: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.onLock() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: nil, using: immediate),
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                               object: nil, queue: nil, using: immediate),
        ]
        // 锁屏与屏保都是分布式通知（本 SDK 的 NSWorkspace 没有 screensDidLock* API，
        // 且类名已从 NSDistributedNotificationCenter 改为 DistributedNotificationCenter）
        distributedObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil, queue: nil, using: immediate),
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.start"),
                object: nil, queue: nil, using: immediate),
        ]
    }

    func stopEventObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers = []
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers = []
    }
}
