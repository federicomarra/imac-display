import AppKit
import Combine
import Network
import ServiceManagement

/// App state for the menu bar UI: discovery, pairing, the active stream and display controls.
/// All published properties are changed on the main thread.
final class SenderController: ObservableObject {
    static let shared = SenderController()

    enum ConnectionState: Equatable {
        case idle
        case connecting(name: String)
        case pairing(name: String)
        case streaming(name: String)
        case failed(message: String)
    }

    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var stats = StreamStats()
    @Published private(set) var displayState: DisplayState?
    @Published private(set) var pairingError: String?
    @Published private(set) var accessibilityGranted = InputInjector.isTrusted(prompt: false)
    @Published private(set) var audioOutputNeedsInstall = AudioOutputDevice.needsInstall
    @Published private(set) var audioOutputError: String?

    let settings = SenderSettings.shared

    private let browser = ReceiverBrowser()
    private let brightnessKeys = BrightnessKeys()
    private let networkQueue = DispatchQueue(label: "imacdisplay.sender.net", qos: .userInteractive)
    private var connection: FramedConnection?
    private var target: DiscoveredReceiver?
    private var reply: HelloReply?
    private var userDisconnected = false
    private var retryWork: DispatchWorkItem?
    private var controlWork: DispatchWorkItem?
    private var pendingControl = DisplayControlMessage()
    private var permissionTimer: Timer?

    private let sessionLock = NSLock()
    private var _session: StreamSession?
    private var session: StreamSession? {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _session }
        set { sessionLock.lock(); _session = newValue; sessionLock.unlock() }
    }

    private init() {
        // An iMac output left over from a previous run that didn't end cleanly.
        AudioOutputDevice.publish(nil)
        browser.onChange = { [weak self] list in
            self?.receivers = list
            self?.autoConnectIfNeeded()
        }
        browser.start()
        brightnessKeys.iMacDisplay = { [weak self] in
            guard let self, self.isStreaming, self.displayState?.brightnessSupported == true else { return nil }
            return self.session?.displayID
        }
        brightnessKeys.onKey = { [weak self] up, fine in self?.stepBrightness(up: up, fine: fine) }
        brightnessKeys.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let granted = InputInjector.isTrusted(prompt: false)
            if self?.accessibilityGranted != granted {
                self?.accessibilityGranted = granted
            }
            // The brightness keys need Accessibility too: start once it's granted.
            if granted { self?.brightnessKeys.start() }
        }
    }

    var isActive: Bool {
        switch state {
        case .idle, .failed: return false
        default: return true
        }
    }

    var isStreaming: Bool {
        if case .streaming = state { return true }
        return false
    }

    var connectedReceiverID: String? {
        isActive ? target?.id : nil
    }

    // MARK: - Connecting

    func connect(to receiver: DiscoveredReceiver) {
        teardown()
        userDisconnected = false
        target = receiver
        settings.lastReceiverID = receiver.id
        pairingError = nil
        state = .connecting(name: receiver.name)
        Connector.connect(to: receiver.endpoint, queue: networkQueue) { [weak self] connection in
            DispatchQueue.main.async {
                self?.connected(connection, to: receiver)
            }
        }
    }

    func disconnect() {
        userDisconnected = true
        teardown()
        state = .idle
    }

    func submitPIN(_ pin: String) {
        guard case .pairing = state, let connection else { return }
        pairingError = nil
        let request = PairRequest(senderID: settings.senderID,
                                  senderName: Self.computerName,
                                  pin: pin.trimmingCharacters(in: .whitespacesAndNewlines))
        connection.sendJSON(.pairRequest, request)
    }

    /// Restarts the media pipeline with the current settings, keeping the connection.
    func restartStream() {
        guard isStreaming, let reply else { return }
        let old = session
        session = nil
        old?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startSession(reply)
        }
    }

    private func connected(_ nwConnection: NWConnection?, to receiver: DiscoveredReceiver) {
        guard target?.id == receiver.id, case .connecting = state else {
            nwConnection?.cancel()
            return
        }
        guard let nwConnection else {
            fail(NSLocalizedString("Could not reach the iMac.", comment: "Connection error"), retry: true)
            return
        }
        let framed = FramedConnection(connection: nwConnection, queue: networkQueue)
        framed.onMessage = { [weak self] type, payload in
            self?.received(type, payload)
        }
        framed.onClose = { [weak self, weak framed] _ in
            DispatchQueue.main.async {
                guard let self, let framed else { return }
                self.connectionClosed(framed)
            }
        }
        connection = framed
        framed.attachReady()
        let hello = HelloMessage(protocolVersion: IMD.protocolVersion,
                                 senderID: settings.senderID,
                                 senderName: Self.computerName,
                                 token: PairingStore.token(for: receiver.id))
        framed.sendJSON(.hello, hello)
    }

    /// Called on the network queue.
    private func received(_ type: MessageType, _ payload: Data) {
        switch type {
        case .inputEvent, .pong, .requestKeyframe, .receiverStats, .audioVolume:
            session?.handle(type, payload)
        default:
            DispatchQueue.main.async { self.handleControlMessage(type, payload) }
        }
    }

    private func handleControlMessage(_ type: MessageType, _ payload: Data) {
        switch type {
        case .helloReply:
            guard let reply = JSONCoding.decode(HelloReply.self, from: payload) else { return }
            self.reply = reply
            displayState = reply.displayState
            switch reply.status {
            case .ok:
                startSession(reply)
            case .pinRequired:
                state = .pairing(name: target?.name ?? reply.receiverName)
            case .incompatible:
                fail(NSLocalizedString("The iMac app is a different version. Install the same version on both computers.", comment: "Connection error"), retry: false)
            }
        case .pairResult:
            guard let result = JSONCoding.decode(PairResult.self, from: payload) else { return }
            if result.success, let token = result.token {
                let receiverID = reply?.receiverID ?? target?.id ?? ""
                PairingStore.set(token, for: receiverID)
                if let target, target.id != receiverID {
                    PairingStore.set(token, for: target.id)
                }
            } else {
                pairingError = NSLocalizedString("Wrong code. Check the code on the iMac and try again.", comment: "Pairing error")
            }
        case .displayState:
            if let state = JSONCoding.decode(DisplayState.self, from: payload) {
                displayState = state
            }
        default:
            break
        }
    }

    private func startSession(_ reply: HelloReply) {
        guard let connection, let target, session == nil else { return }
        let config = StreamConfig(policy: settings.qualityPolicy,
                                  maxFrameRate: settings.maxFrameRate,
                                  maxBitrate: Int(settings.maxBitrateMbps * 1_000_000),
                                  codecPreference: settings.codec,
                                  audio: settings.audioEnabled,
                                  input: settings.inputEnabled,
                                  receiverName: target.name)
        let session = StreamSession(connection: connection, reply: reply, config: config)
        session.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.stats = stats }
        }
        session.onFatalError = { [weak self] message in
            DispatchQueue.main.async { self?.fail(message, retry: true) }
        }
        self.session = session
        state = .streaming(name: target.name)
        Task {
            do {
                try await session.start()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error.localizedDescription, retry: false)
                }
            }
        }
    }

    private func connectionClosed(_ framed: FramedConnection) {
        guard framed === connection else { return }
        let wasPairing: Bool
        if case .pairing = state { wasPairing = true } else { wasPairing = false }
        teardown()
        if userDisconnected {
            state = .idle
        } else if wasPairing {
            fail(NSLocalizedString("The iMac closed the connection. Try pairing again.", comment: "Connection error"), retry: false)
        } else {
            fail(NSLocalizedString("Connection lost. Reconnecting…", comment: "Connection error"), retry: true)
        }
    }

    private func fail(_ message: String, retry: Bool) {
        teardown()
        state = .failed(message: message)
        if retry {
            scheduleRetry()
        } else {
            userDisconnected = true
        }
    }

    private func teardown() {
        retryWork?.cancel()
        retryWork = nil
        let session = self.session
        self.session = nil
        session?.stop()
        connection?.onClose = nil
        connection?.cancel()
        connection = nil
        reply = nil
        stats = StreamStats()
        // Like unplugging the cable: the iMac leaves the Mac's audio outputs.
        AudioOutputDevice.publish(nil)
    }

    private func scheduleRetry() {
        guard settings.autoConnect, let target else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isActive, !self.userDisconnected else { return }
            if let receiver = self.receivers.first(where: { $0.id == target.id }) {
                self.connect(to: receiver)
            } else {
                self.scheduleRetry()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func autoConnectIfNeeded() {
        guard settings.autoConnect, !userDisconnected, !isActive, retryWork == nil,
              let last = settings.lastReceiverID,
              let receiver = receivers.first(where: { $0.id == last }) else { return }
        connect(to: receiver)
    }

    // MARK: - Display controls

    func setBrightness(_ value: Float) {
        pendingControl.brightness = value
        displayState?.brightness = value
        sendControlSoon()
    }

    func setGamma(_ value: Float) {
        pendingControl.gamma = value
        displayState?.gamma = value
        sendControlSoon()
    }

    /// A brightness key pressed for the iMac: one macOS step (1/16, or 1/64 with ⌥⇧),
    /// with the system's brightness indicator on the iMac's screen.
    private func stepBrightness(up: Bool, fine: Bool) {
        guard let state = displayState, let display = session?.displayID else { return }
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let value = min(max(((state.brightness / step).rounded() + (up ? 1 : -1)) * step, 0), 1)
        setBrightness(value)
        BrightnessIndicator.show(value, on: display)
    }

    func setWarmth(_ value: Float) {
        pendingControl.warmth = value
        displayState?.warmth = value
        sendControlSoon()
    }

    func resetColor() {
        pendingControl = DisplayControlMessage()
        controlWork?.cancel()
        controlWork = nil
        displayState?.gamma = 1
        displayState?.warmth = 0
        connection?.sendJSON(.displayControl, DisplayControlMessage(resetColor: true))
    }

    /// Coalesces slider movements into at most ~20 messages per second.
    private func sendControlSoon() {
        guard controlWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controlWork = nil
            let message = self.pendingControl
            self.pendingControl = DisplayControlMessage()
            self.connection?.sendJSON(.displayControl, message)
        }
        controlWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Audio output

    /// Installs the audio driver that makes the iMac an audio output of the Mac.
    /// macOS asks for an administrator password.
    func installAudioOutput() {
        NSApp.activate(ignoringOtherApps: true)
        let error = AudioOutputDevice.install()
        audioOutputNeedsInstall = AudioOutputDevice.needsInstall
        audioOutputError = error?.isEmpty == false ? error : nil
        guard error == nil else { return }
        // Core Audio restarts to load the driver: restart the stream to use the new output.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restartStream() }
    }

    // MARK: - Misc

    func forgetPairings() {
        PairingStore.removeAll()
    }

    func openAccessibilitySettings() {
        _ = InputInjector.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("iMacDisplay: login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    static var computerName: String {
        Host.current().localizedName ?? "Mac"
    }
}
