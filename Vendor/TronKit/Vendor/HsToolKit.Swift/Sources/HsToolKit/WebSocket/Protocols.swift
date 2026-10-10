import Foundation
import NIO
import NIOWebSocket

public enum WebSocketState {
    case connecting
    case connected
    case disconnected(error: Error)

    public enum DisconnectError: Error {
        case notStarted
        case socketDisconnected(reason: DisconnectReason)
    }

    public enum DisconnectReason {
        case networkNotReachable
        case appInBackgroundMode
        case unexpectedServerError
    }
}

public enum WebSocketStateError: Error {
    case connecting
    case couldNotConnect
}

public protocol IWebSocket: AnyObject {
    var delegate: IWebSocketDelegate? { get set }
    var source: String { get }

    func start()
    func stop()

    func send(data: Data, completionHandler: ((Error?) -> Void)?) throws
    func send(ping: Data) throws
    func send(pong: Data) throws
}

protocol INIOWebSocket: AnyObject {
    var onClose: EventLoopFuture<Void> { get }
    var pingInterval: TimeAmount? { get set }
    var waitingForClose: Bool { get }
    func onText(_ callback: @escaping (NIOWebSocket, String) -> Void)
    func onBinary(_ callback: @escaping (NIOWebSocket, ByteBuffer) -> Void)
    func onPong(_ callback: @escaping (NIOWebSocket) -> Void)
    func onPing(_ callback: @escaping (NIOWebSocket) -> Void)
    func onError(_ callback: @escaping (NIOWebSocketError) -> Void)
    func sendPing(promise: EventLoopPromise<Void>?)
    func send<Data>(raw data: Data, opcode: WebSocketOpcode, fin: Bool, completionHandler: ((Error?) -> Void)?) where Data: DataProtocol
    func close(code: WebSocketErrorCode) -> EventLoopFuture<Void>
}

public protocol IWebSocketDelegate: AnyObject {
    func didUpdate(state: WebSocketState)
    func didReceive(text: String)
    func didReceive(data: Data)
}
