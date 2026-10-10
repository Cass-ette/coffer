import Alamofire
import Combine
import Foundation
import HsExtensions

public class ReachabilityManager {
    private let manager: NetworkReachabilityManager?

    @DistinctPublished public private(set) var isReachable: Bool = false
    private let connectionTypeChangedSubject = PassthroughSubject<Void, Never>()

    private var lastConnectionType: NetworkReachabilityManager.NetworkReachabilityStatus.ConnectionType?

    public init() {
        manager = NetworkReachabilityManager()

        if let manager {
            isReachable = manager.isReachable

            manager.startListening { [weak self] status in
                self?.onUpdate(status: status)
            }
        }
    }

    private func onUpdate(status: NetworkReachabilityManager.NetworkReachabilityStatus) {
        switch status {
        case let .reachable(connectionType):
            isReachable = true

            if let lastConnectionType, connectionType != lastConnectionType {
                connectionTypeChangedSubject.send()
            }

            lastConnectionType = connectionType
        default:
            isReachable = false
            lastConnectionType = nil
        }
    }

    public var connectionTypeChangedPublisher: AnyPublisher<Void, Never> {
        connectionTypeChangedSubject.eraseToAnyPublisher()
    }
}

public extension ReachabilityManager {
    enum ReachabilityError: Error {
        case notReachable
    }
}
