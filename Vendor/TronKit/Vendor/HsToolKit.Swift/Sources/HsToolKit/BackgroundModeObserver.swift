import Combine
import Foundation

#if canImport(UIKit)
import UIKit

public class BackgroundModeObserver {
    public static let shared = BackgroundModeObserver()

    private let foregroundFromExpiredBackgroundSubject = PassthroughSubject<Void, Never>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.appCameToBackground() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.appCameToForeground() }
            .store(in: &cancellables)
    }

    @objc private func appCameToBackground() {
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = UIBackgroundTaskIdentifier.invalid
        }
    }

    @objc private func appCameToForeground() {
        if backgroundTask != UIBackgroundTaskIdentifier.invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = UIBackgroundTaskIdentifier.invalid
        } else {
            foregroundFromExpiredBackgroundSubject.send()
        }
    }

    public var foregroundFromExpiredBackgroundPublisher: AnyPublisher<Void, Never> {
        foregroundFromExpiredBackgroundSubject.eraseToAnyPublisher()
    }
}
#endif
