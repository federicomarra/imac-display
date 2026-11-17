import Foundation
import Network

/// TCP parameters tuned for a low-latency stream on a local network.
enum NetworkParameters {
    static func tcp(requiredInterface: NWInterface.InterfaceType? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Allows Bonjour and connections over peer-to-peer Wi-Fi (AWDL) too.
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        if let requiredInterface {
            parameters.requiredInterfaceType = requiredInterface
        }
        return parameters
    }
}

/// Which physical link a connection is using.
enum LinkKind: String {
    case thunderbolt
    case ethernet
    case wifi
    case other
    case unknown

    static func of(_ connection: NWConnection) -> LinkKind {
        guard let path = connection.currentPath else { return .unknown }
        if let interface = path.availableInterfaces.first {
            // The Thunderbolt Bridge network interface is called "bridgeN".
            if interface.name.hasPrefix("bridge") { return .thunderbolt }
            switch interface.type {
            case .wiredEthernet: return .ethernet
            case .wifi: return .wifi
            default: return .other
            }
        }
        return .unknown
    }
}

/// Length-prefixed message framing on top of an NWConnection.
/// Wire format: [type: UInt8][length: UInt32 big-endian][payload].
final class FramedConnection {
    let connection: NWConnection
    let queue: DispatchQueue

    /// Called on `queue` for every complete message.
    var onMessage: ((MessageType, Data) -> Void)?
    /// Called on `queue` once the connection is ready (only for connections started with `start()`).
    var onReady: (() -> Void)?
    /// Called on `queue` exactly once when the connection ends.
    var onClose: ((Error?) -> Void)?

    private let lock = NSLock()
    private var inflight = 0
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Bytes handed to the network stack that have not been sent yet.
    var inflightBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return inflight
    }

    var linkKind: LinkKind { LinkKind.of(connection) }

    /// For a fresh connection (state .setup), e.g. one accepted by a listener.
    func start() {
        installStateHandler()
        connection.start(queue: queue)
        receiveHeader()
    }

    /// For a connection that has already been started and is ready.
    func attachReady() {
        installStateHandler()
        receiveHeader()
    }

    func send(_ type: MessageType, _ payload: Data = Data()) {
        var message = Data(capacity: 5 + payload.count)
        message.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(payload)
        let total = message.count

        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        inflight += total
        lock.unlock()

        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.inflight -= total
            self.lock.unlock()
            if let error {
                self.close(error)
            }
        })
    }

    func sendJSON<T: Encodable>(_ type: MessageType, _ value: T) {
        send(type, JSONCoding.encode(value))
    }

    func cancel() {
        close(nil)
    }

    // MARK: - Private

    private func installStateHandler() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
    }

    private func close(_ error: Error?) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        connection.cancel()
        let handler = onClose
        onClose = nil
        handler?(error)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.close(error)
                return
            }
            guard let data, data.count == 5 else {
                if isComplete { self.close(nil) }
                return
            }
            let start = data.startIndex
            let typeRaw = data[start]
            var length: UInt32 = 0
            for i in 1...4 {
                length = (length << 8) | UInt32(data[start + i])
            }
            guard length <= UInt32(IMD.maxMessageSize) else {
                self.close(nil)
                return
            }
            if length == 0 {
                self.dispatch(typeRaw, Data())
                self.receiveHeader()
            } else {
                self.receiveBody(typeRaw, length: Int(length))
            }
        }
    }

    private func receiveBody(_ typeRaw: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.close(error)
                return
            }
            guard let data, data.count == length else {
                self.close(nil)
                return
            }
            self.dispatch(typeRaw, data)
            self.receiveHeader()
        }
    }

    private func dispatch(_ typeRaw: UInt8, _ payload: Data) {
        // Unknown message types are ignored so newer peers can add messages.
        guard let type = MessageType(rawValue: typeRaw) else { return }
        onMessage?(type, payload)
    }
}
