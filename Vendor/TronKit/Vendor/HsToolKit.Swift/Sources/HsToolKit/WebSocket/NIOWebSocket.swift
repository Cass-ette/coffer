import Foundation
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOSSL
import NIOWebSocket

final class NIOWebSocket: INIOWebSocket {
    enum PeerType {
        case server
        case client
    }

    var eventLoop: EventLoop {
        channel.eventLoop
    }

    var isClosed: Bool {
        !channel.isActive
    }

    private(set) var closeCode: WebSocketErrorCode?

    var onClose: EventLoopFuture<Void> {
        channel.closeFuture
    }

    var waitingForClose: Bool

    private let channel: Channel
    private var onTextCallback: (NIOWebSocket, String) -> Void
    private var onBinaryCallback: (NIOWebSocket, ByteBuffer) -> Void
    private var onPongCallback: (NIOWebSocket) -> Void
    private var onPingCallback: (NIOWebSocket) -> Void
    private var onErrorCallback: (NIOWebSocketError) -> Void
    private var frameSequence: WebSocketFrameSequence?
    private let type: PeerType
    private var waitingForPong: Bool
    private var scheduledTimeoutTask: Scheduled<Void>?

    init(channel: Channel, type: PeerType) {
        self.channel = channel
        self.type = type
        onTextCallback = { _, _ in }
        onBinaryCallback = { _, _ in }
        onPongCallback = { _ in }
        onPingCallback = { _ in }
        onErrorCallback = { _ in }
        waitingForPong = false
        waitingForClose = false
        scheduledTimeoutTask = nil
    }

    func onText(_ callback: @escaping (NIOWebSocket, String) -> Void) {
        onTextCallback = callback
    }

    func onBinary(_ callback: @escaping (NIOWebSocket, ByteBuffer) -> Void) {
        onBinaryCallback = callback
    }

    func onPong(_ callback: @escaping (NIOWebSocket) -> Void) {
        onPongCallback = callback
    }

    func onPing(_ callback: @escaping (NIOWebSocket) -> Void) {
        onPingCallback = callback
    }

    func onError(_ callback: @escaping (NIOWebSocketError) -> Void) {
        onErrorCallback = callback
    }

    /// If set, this will trigger automatic pings on the connection. If ping is not answered before
    /// the next ping is sent, then the WebSocket will be presumed inactive and will be closed
    /// automatically.
    /// These pings can also be used to keep the WebSocket alive if there is some other timeout
    /// mechanism shutting down inactive connections, such as a Load Balancer deployed in
    /// front of the server.
    var pingInterval: TimeAmount? {
        didSet {
            if pingInterval != nil {
                if scheduledTimeoutTask == nil {
                    waitingForPong = false
                    pingAndScheduleNextTimeoutTask()
                }
            } else {
                scheduledTimeoutTask?.cancel()
            }
        }
    }

    private func send(_ text: some Collection<Character>, promise: EventLoopPromise<Void>? = nil) {
        let string = String(text)
        var buffer = channel.allocator.buffer(capacity: text.count)
        buffer.writeString(string)
        send(raw: buffer.readableBytesView, opcode: .text, fin: true, promise: promise)
    }

    private func send(_ binary: [UInt8], promise: EventLoopPromise<Void>? = nil) {
        send(raw: binary, opcode: .binary, fin: true, promise: promise)
    }

    private func convertToPromise(completionHandler: ((Error?) -> Void)?) -> EventLoopPromise<Void>? {
        completionHandler.flatMap { handler in
            let promise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
            promise.futureResult.whenComplete { result in
                switch result {
                case .success: handler(nil)
                case let .failure(error): handler(error)
                }
            }

            return promise
        }
    }

    private func send(
        raw data: some DataProtocol,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    ) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(
            fin: fin,
            opcode: opcode,
            maskKey: makeMaskKey(),
            data: buffer
        )

        channel.writeAndFlush(frame, promise: promise)
    }

    func sendPing(promise: EventLoopPromise<Void>? = nil) {
        send(
            raw: Data(),
            opcode: .ping,
            fin: true,
            promise: promise
        )
    }

    func send(raw data: some DataProtocol, opcode: WebSocketOpcode, fin: Bool, completionHandler: ((Error?) -> Void)?) {
        send(raw: data, opcode: opcode, fin: fin, promise: convertToPromise(completionHandler: completionHandler))
    }

    func close(code: WebSocketErrorCode = .goingAway) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        close(code: code, promise: promise)
        return promise.futureResult
    }

    func close(
        code: WebSocketErrorCode = .goingAway,
        promise: EventLoopPromise<Void>?
    ) {
        guard !isClosed else {
            promise?.succeed(())
            return
        }
        guard !waitingForClose else {
            promise?.succeed(())
            return
        }
        waitingForClose = true
        closeCode = code

        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)

        send(raw: buffer.readableBytesView, opcode: .connectionClose, fin: true, promise: promise)
    }

    func makeMaskKey() -> WebSocketMaskingKey? {
        switch type {
        case .client:
            var bytes: [UInt8] = []
            for _ in 0 ..< 4 {
                bytes.append(.random(in: .min ..< .max))
            }
            return WebSocketMaskingKey(bytes)
        case .server:
            return nil
        }
    }

    func handle(incoming frame: WebSocketFrame) {
        switch frame.opcode {
        case .connectionClose:
            if waitingForClose {
                // peer confirmed close, time to close channel
                channel.close(mode: .output, promise: nil)
            } else {
                // peer asking for close, confirm and close output side channel
                let promise = eventLoop.makePromise(of: Void.self)
                var data = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey {
                    data.webSocketUnmask(maskingKey)
                }
                close(
                    code: data.readWebSocketErrorCode() ?? .unknown(1005),
                    promise: promise
                )
                promise.futureResult.whenComplete { _ in
                    self.channel.close(mode: .output, promise: nil)
                }
            }
        case .ping:
            if frame.fin {
                var frameData = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                send(
                    raw: frameData.readableBytesView,
                    opcode: .pong,
                    fin: true,
                    promise: nil
                )
            } else {
                close(code: .protocolError, promise: nil)
            }
        case .text, .binary, .pong:
            // create a new frame sequence or use existing
            var frameSequence: WebSocketFrameSequence
            if let existing = self.frameSequence {
                frameSequence = existing
            } else {
                frameSequence = WebSocketFrameSequence(type: frame.opcode)
            }
            // append this frame and update the sequence
            frameSequence.append(frame)
            self.frameSequence = frameSequence
        case .continuation:
            // we must have an existing sequence
            if var frameSequence {
                // append this frame and update
                frameSequence.append(frame)
                self.frameSequence = frameSequence
            } else {
                close(code: .protocolError, promise: nil)
            }
        default:
            // We ignore all other frames.
            break
        }

        // if this frame was final and we have a non-nil frame sequence,
        // output it to the websocket and clear storage
        if let frameSequence, frame.fin {
            switch frameSequence.type {
            case .binary:
                onBinaryCallback(self, frameSequence.binaryBuffer)
            case .text:
                onTextCallback(self, frameSequence.textBuffer)
            case .pong:
                waitingForPong = false
                onPongCallback(self)
            case .ping:
                onPingCallback(self)
            default: break
            }
            self.frameSequence = nil
        }
    }

    private func pingAndScheduleNextTimeoutTask() {
        guard channel.isActive, let pingInterval else {
            return
        }

        if waitingForPong {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = eventLoop.makePromise(of: Void.self)
            close(code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocket is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }
        } else {
            sendPing()
            waitingForPong = true
            scheduledTimeoutTask = eventLoop.scheduleTask(
                deadline: .now() + pingInterval,
                pingAndScheduleNextTimeoutTask
            )
        }
    }
}

extension NIOWebSocket: WebSocketErrorHandlerDelegate {
    func onError(error: NIOWebSocketError) {
        onErrorCallback(error)
    }
}

private struct WebSocketFrameSequence {
    var binaryBuffer: ByteBuffer
    var textBuffer: String
    var type: WebSocketOpcode

    init(type: WebSocketOpcode) {
        binaryBuffer = ByteBufferAllocator().buffer(capacity: 0)
        textBuffer = .init()
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        switch type {
        case .binary:
            binaryBuffer.writeBuffer(&data)
        case .text:
            if let string = data.readString(length: data.readableBytes) {
                textBuffer += string
            }
        default: break
        }
    }
}

extension NIOWebSocket {
    static func connect(
        to url: String,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @escaping (NIOWebSocket) -> Void
    ) -> EventLoopFuture<Void> {
        guard let url = URL(string: url) else {
            return eventLoopGroup.next().makeFailedFuture(WebSocketClient.Error.invalidURL)
        }
        return connect(
            to: url,
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: onUpgrade
        )
    }

    static func connect(
        to url: URL,
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @escaping (NIOWebSocket) -> Void
    ) -> EventLoopFuture<Void> {
        let scheme: String
        switch url.scheme {
        case "wss", "https": scheme = "wss"
        default: scheme = "ws"
        }
        return connect(
            scheme: scheme,
            host: url.host ?? "localhost",
            port: url.port ?? (scheme == "wss" ? 443 : 80),
            path: url.path + (url.hasDirectoryPath ? "/" : ""),
            headers: headers,
            configuration: configuration,
            on: eventLoopGroup,
            onUpgrade: onUpgrade
        )
    }

    static func connect(
        scheme: String = "ws",
        host: String,
        port: Int = 80,
        path: String = "/",
        headers: HTTPHeaders = [:],
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @escaping (NIOWebSocket) -> Void
    ) -> EventLoopFuture<Void> {
        WebSocketClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: configuration
        ).connect(
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            headers: headers,
            onUpgrade: onUpgrade
        )
    }
}
