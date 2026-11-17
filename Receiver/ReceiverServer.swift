import AppKit
import Network

/// Advertises the iMac on the network, pairs with Macs and dispatches the stream.
final class ReceiverServer {
    enum Status {
        case starting
        case waiting
        case pairing(pin: String, senderName: String)
        case connected(senderName: String)
        case failed(String)
    }

    /// Called on the main thread.
    var onStatus: ((Status) -> Void)?

    private let videoView: VideoView
    private let audio: AudioPlayer
    private let display: DisplayAdjuster
    private let queue = DispatchQueue(label: "imacdisplay.receiver.net", qos: .userInteractive)
    private var listener: NWListener?

    /// Clients that connected but are not authenticated yet, plus the active one.
    private var clients: [ObjectIdentifier: Client] = [:]
    private var active: Client?
    private var currentPIN: String?
    private var statsTimer: DispatchSourceTimer?
    private var framesReceived = 0

    private let defaults = UserDefaults.standard

    let receiverID: String
    let receiverName: String
    private let screenPixelSize: (width: Int, height: Int)

    private final class Client {
        let connection: FramedConnection
        var hello: HelloMessage?
        var authenticated = false
        var failedAttempts = 0

        init(connection: FramedConnection) {
            self.connection = connection
        }
    }

    init(videoView: VideoView, audio: AudioPlayer, display: DisplayAdjuster) {
        self.videoView = videoView
        self.audio = audio
        self.display = display
        let standard = UserDefaults.standard
        if let stored = standard.string(forKey: "receiverID") {
            receiverID = stored
        } else {
            let created = UUID().uuidString
            standard.set(created, forKey: "receiverID")
            receiverID = created
        }
        receiverName = Host.current().localizedName ?? "iMac"
        // Read once on the main thread; the iMac screen never changes.
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 2048, height: 1152)
        screenPixelSize = (Int(size.width * scale), Int(size.height * scale))
        videoView.onNeedsKeyframe = { [weak self] in
            self?.queue.async { self?.active?.connection.send(.requestKeyframe) }
        }
    }

    func start() {
        queue.async { self.startListener() }
    }

    /// Sends an input event from the iMac keyboard/mouse to the connected Mac.
    func sendInput(_ event: InputEvent) {
        let payload = event.serialized()
        queue.async {
            self.active?.connection.send(.inputEvent, payload)
        }
    }

    // MARK: - Listener

    private func startListener() {
        publish(.starting)
        do {
            let listener = try NWListener(using: NetworkParameters.tcp())
            let txt = NetService.data(fromTXTRecord: [
                "id": Data(receiverID.utf8),
                "v": Data(String(IMD.protocolVersion).utf8),
            ])
            listener.service = NWListener.Service(name: receiverName, type: IMD.serviceType, domain: nil, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.active == nil { self.publish(.waiting) }
                case .failed(let error):
                    self.publish(.failed(error.localizedDescription))
                    self.listener?.cancel()
                    self.listener = nil
                    self.queue.asyncAfter(deadline: .now() + 3) { self.startListener() }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publish(.failed(error.localizedDescription))
            queue.asyncAfter(deadline: .now() + 3) { self.startListener() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue)
        let client = Client(connection: framed)
        let key = ObjectIdentifier(client)
        clients[key] = client
        framed.onMessage = { [weak self, weak client] type, payload in
            guard let self, let client else { return }
            self.handle(type, payload, from: client)
        }
        framed.onClose = { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.clientClosed(client)
        }
        framed.start()
    }

    private func clientClosed(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
        guard client === active else {
            // A Mac gave up pairing: hide the code if nobody else is pairing.
            let stillPairing = clients.values.contains { $0.hello != nil && !$0.authenticated }
            if active == nil, !stillPairing {
                currentPIN = nil
                publish(.waiting)
            }
            return
        }
        active = nil
        stopStatsTimer()
        audio.stop()
        DispatchQueue.main.async { self.videoView.reset() }
        publish(.waiting)
    }

    // MARK: - Messages

    private func handle(_ type: MessageType, _ payload: Data, from client: Client) {
        switch type {
        case .hello:
            guard let hello = JSONCoding.decode(HelloMessage.self, from: payload) else { return }
            handleHello(hello, from: client)
        case .pairRequest:
            guard let request = JSONCoding.decode(PairRequest.self, from: payload) else { return }
            handlePairRequest(request, from: client)
        case .ping:
            client.connection.send(.pong, payload)
        default:
            guard client.authenticated, client === active else { return }
            handleStreamMessage(type, payload, from: client)
        }
    }

    private func handleHello(_ hello: HelloMessage, from client: Client) {
        client.hello = hello
        guard hello.protocolVersion == IMD.protocolVersion else {
            client.connection.sendJSON(.helloReply, makeReply(.incompatible))
            queue.asyncAfter(deadline: .now() + 1) { client.connection.cancel() }
            return
        }
        if let token = hello.token, trustedTokens[hello.senderID] == token {
            authenticate(client)
            return
        }
        let pin = currentPIN ?? Self.makePIN()
        currentPIN = pin
        publish(.pairing(pin: pin, senderName: hello.senderName))
        client.connection.sendJSON(.helloReply, makeReply(.pinRequired))
    }

    private func handlePairRequest(_ request: PairRequest, from client: Client) {
        guard let pin = currentPIN, client.hello != nil else {
            client.connection.sendJSON(.pairResult, PairResult(success: false, token: nil))
            return
        }
        if request.pin.trimmingCharacters(in: .whitespaces) == pin {
            let token = UUID().uuidString
            var tokens = trustedTokens
            tokens[request.senderID] = token
            trustedTokens = tokens
            client.connection.sendJSON(.pairResult, PairResult(success: true, token: token))
            authenticate(client)
        } else {
            client.failedAttempts += 1
            client.connection.sendJSON(.pairResult, PairResult(success: false, token: nil))
            if client.failedAttempts >= 5 {
                // Too many wrong codes: new code, drop the client.
                currentPIN = nil
                client.connection.cancel()
            }
        }
    }

    private func authenticate(_ client: Client) {
        if let previous = active, previous !== client {
            previous.connection.cancel()
        }
        client.authenticated = true
        active = client
        currentPIN = nil
        framesReceived = 0
        client.connection.sendJSON(.helloReply, makeReply(.ok))
        startStatsTimer()
        publish(.connected(senderName: client.hello?.senderName ?? "Mac"))
    }

    private func handleStreamMessage(_ type: MessageType, _ payload: Data, from client: Client) {
        switch type {
        case .videoFormat:
            guard let format = JSONCoding.decode(VideoFormatMessage.self, from: payload) else { return }
            videoView.setFormat(format)
        case .videoFrame:
            guard let frame = VideoFrame(payload: payload) else { return }
            framesReceived += 1
            videoView.enqueue(frame)
        case .audioFormat:
            guard let format = JSONCoding.decode(AudioFormatMessage.self, from: payload) else { return }
            audio.configure(format)
        case .audioData:
            audio.enqueue(payload)
        case .displayControl:
            guard let control = JSONCoding.decode(DisplayControlMessage.self, from: payload) else { return }
            DispatchQueue.main.async {
                self.display.apply(control)
                let state = self.display.state
                self.queue.async { client.connection.sendJSON(.displayState, state) }
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func makeReply(_ status: HelloStatus) -> HelloReply {
        HelloReply(status: status,
                          protocolVersion: IMD.protocolVersion,
                          receiverID: receiverID,
                          receiverName: receiverName,
                          screenPixelWidth: screenPixelSize.width,
                          screenPixelHeight: screenPixelSize.height,
                          hevcHardwareDecode: VideoView.supportsHEVCHardwareDecode,
                          displayState: display.state)
    }

    private var trustedTokens: [String: String] {
        get { defaults.dictionary(forKey: "trustedSenders") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "trustedSenders") }
    }

    func forgetPairedMacs() {
        queue.async { self.trustedTokens = [:] }
    }

    private static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func startStatsTimer() {
        stopStatsTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let active = self.active else { return }
            let stats = ReceiverStats(framesReceived: self.framesReceived,
                                      framesDisplayed: self.videoView.framesDisplayed,
                                      decodeFailures: self.videoView.decodeFailures)
            active.connection.sendJSON(.receiverStats, stats)
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }
}
