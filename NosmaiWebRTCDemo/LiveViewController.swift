import UIKit
import AVFoundation
import MultipeerConnectivity
import WebRTC

/// Host:     Nosmai owns the camera -> filtered CVPixelBuffers -> WebRTC video track.
/// Audience: receives the host's tracks over a WebRTC peer connection.
final class LiveViewController: UIViewController {
    enum Role { case host, audience }

    private let role: Role
    private let config: DemoConfig
    private var isHost: Bool { role == .host }

    private var signaling: LocalSignaling?
    private var factory: RTCPeerConnectionFactory?
    /// One peer connection per remote phone: the host has one per viewer, a viewer has one to the host.
    private var connections: [MCPeerID: RTCPeerConnection] = [:]
    /// ICE candidates that arrived before the remote description was set.
    private var pendingCandidates: [MCPeerID: [RTCIceCandidate]] = [:]

    // Host: the tracks fed by Nosmai and the microphone.
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?

    // Audience: where the host's video is drawn, and a counter for the FPS label.
    private let remoteVideoView = RTCMTLVideoView()
    private let frameCounter = FrameCounter()
    private var remoteVideoTrack: RTCVideoTrack?
    private let frameQueue = DispatchQueue(label: "com.nosmai.webrtc.demo.frames")
    private var cameraRunning = false
    private var stopped = false
    /// Read from Nosmai's processing thread and the frame queue.
    private let pushLock = NSLock()
    private var _pushing = false
    private var pushing: Bool {
        get { pushLock.lock(); defer { pushLock.unlock() }; return _pushing }
        set { pushLock.lock(); _pushing = newValue; pushLock.unlock() }
    }

    private var liveStatus = "Preparing…"
    private var toastToken = 0

    private let videoView = UIView()
    private let statusLabel = PaddedLabel()
    private let fpsLabel = PaddedLabel()
    /// Host: frames handed to WebRTC since the last tick. Guarded by pushLock.
    private var framesSinceTick = 0
    private var fpsTimer: Timer?
    private let controls = UIStackView()
    private let effectsPanel = EffectsPanelView()

    init(role: Role, config: DemoConfig) {
        self.role = role
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isHost ? "Live" : "Watching"
        view.backgroundColor = .black
        buildUI()
        setUpWebRTC()
        if isHost {
            requestPermissions { [weak self] in self?.startNosmaiCamera() }
        } else {
            startSignaling()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if isMovingFromParent || isBeingDismissed { stopSession() }
    }

    // MARK: - UI

    private func buildUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        statusLabel.text = "Preparing…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        fpsLabel.text = "-- FPS"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsLabel.layer.cornerRadius = 10
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        controls.axis = .vertical
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        if isHost {
            effectsPanel.onStatus = { [weak self] text in self?.showToast(text) }
            controls.addArrangedSubview(effectsPanel)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        if isHost {
            buttons.addArrangedSubview(makeButton(title: "Flip", color: .darkGray, action: #selector(flipCamera)))
            buttons.addArrangedSubview(makeButton(title: "Effects", color: .systemPink, action: #selector(toggleEffects)))
        }
        buttons.addArrangedSubview(makeButton(title: isHost ? "End Live" : "Leave", color: .systemRed, action: #selector(close)))
        buttons.heightAnchor.constraint(equalToConstant: 48).isActive = true
        controls.addArrangedSubview(buttons)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fpsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            fpsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.liveStatus = text
            self.statusLabel.text = text
        }
    }

    /// Briefly shows effect feedback in the status pill, then restores the live status.
    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.statusLabel.text = self.liveStatus
        }
    }

    // MARK: - WebRTC

    private func setUpWebRTC() {
        RTCSetMinDebugLogLevel(.none)
        // Viewers only listen, so they use a playback audio session and are never
        // asked for the microphone. The host keeps WebRTC's default (play and record).
        let audioConfig = RTCAudioSessionConfiguration.webRTC()
        if isHost {
            audioConfig.category = AVAudioSession.Category.playAndRecord.rawValue
            audioConfig.mode = AVAudioSession.Mode.videoChat.rawValue
        } else {
            audioConfig.category = AVAudioSession.Category.playback.rawValue
            audioConfig.categoryOptions = []
            audioConfig.mode = AVAudioSession.Mode.moviePlayback.rawValue
        }
        RTCAudioSessionConfiguration.setWebRTC(audioConfig)

        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: RTCDefaultVideoDecoderFactory())
        self.factory = factory

        if isHost {
            // Nosmai owns the camera: instead of a camera capturer we create a plain
            // capturer and hand it Nosmai's frames ourselves (see startPushingFrames).
            // Frames are sent exactly as Nosmai produces them (no cropping or resizing here).
            let source = factory.videoSource()
            videoSource = source
            videoCapturer = RTCVideoCapturer(delegate: source)
            videoTrack = factory.videoTrack(with: source, trackId: "video0")
            let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
                                                                            optionalConstraints: nil))
            audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        } else {
            remoteVideoView.videoContentMode = .scaleAspectFill
            remoteVideoView.translatesAutoresizingMaskIntoConstraints = false
            videoView.addSubview(remoteVideoView)
            NSLayoutConstraint.activate([
                remoteVideoView.topAnchor.constraint(equalTo: videoView.topAnchor),
                remoteVideoView.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),
                remoteVideoView.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
                remoteVideoView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            ])
            startAudienceFPSTimer()
        }
    }

    /// Start finding the other phone. The host advertises the room; viewers look for it.
    private func startSignaling() {
        guard !stopped else { return }
        let signaling = LocalSignaling(room: config.roomName, isHost: isHost)
        signaling.onPeerConnected = { [weak self] peer in self?.peerConnected(peer) }
        signaling.onPeerDisconnected = { [weak self] peer in self?.peerDisconnected(peer) }
        signaling.onMessage = { [weak self] message, peer in self?.handle(message, from: peer) }
        signaling.start()
        self.signaling = signaling
        if isHost {
            setStatus("Live in \(config.roomName) — waiting for viewers")
            startPushingFrames()
        } else {
            setStatus("Looking for host on this Wi-Fi…")
        }
    }

    private func makeConnection(for peer: MCPeerID) -> RTCPeerConnection? {
        let rtcConfig = RTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        // A public STUN server is enough on the same network. Add your own TURN
        // server here to connect phones on different networks.
        rtcConfig.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory?.peerConnection(with: rtcConfig, constraints: constraints, delegate: self)
        else { return nil }
        connections[peer]?.close()
        connections[peer] = connection
        pendingCandidates[peer] = []
        return connection
    }

    /// The signaling channel to `peer` is up. The host starts the WebRTC handshake.
    private func peerConnected(_ peer: MCPeerID) {
        guard !stopped else { return }
        guard isHost else {
            setStatus("Found host — connecting…")
            return
        }
        guard let connection = makeConnection(for: peer), let videoTrack, let audioTrack else { return }
        connection.add(videoTrack, streamIds: ["stream0"])
        connection.add(audioTrack, streamIds: ["stream0"])
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection.offer(for: constraints) { [weak self] offer, _ in
            guard let offer else { return }
            connection.setLocalDescription(offer) { error in
                guard error == nil else { return }
                DispatchQueue.main.async {
                    self?.signaling?.send(["type": "offer", "sdp": offer.sdp], to: peer)
                }
            }
        }
    }

    private func peerDisconnected(_ peer: MCPeerID) {
        guard let connection = connections.removeValue(forKey: peer) else { return }
        pendingCandidates[peer] = nil
        connection.close()
        if isHost {
            updateHostStatus()
        } else {
            remoteVideoTrack = nil
            fpsLabel.text = "-- FPS"
            setStatus("Host left the stream")
        }
    }

    /// Offer / answer / ICE candidates from the other phone.
    private func handle(_ message: [String: Any], from peer: MCPeerID) {
        guard !stopped, let type = message["type"] as? String else { return }
        switch type {
        case "offer": // audience
            guard let sdp = message["sdp"] as? String, let connection = makeConnection(for: peer) else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.flushCandidates(for: peer) }
                connection.answer(for: constraints) { answer, _ in
                    guard let answer else { return }
                    connection.setLocalDescription(answer) { error in
                        guard error == nil else { return }
                        DispatchQueue.main.async {
                            self?.signaling?.send(["type": "answer", "sdp": answer.sdp], to: peer)
                        }
                    }
                }
            }
        case "answer": // host
            guard let sdp = message["sdp"] as? String, let connection = connections[peer] else { return }
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.flushCandidates(for: peer) }
            }
        case "candidate":
            guard let sdp = message["candidate"] as? String, let connection = connections[peer] else { return }
            let candidate = RTCIceCandidate(sdp: sdp,
                                            sdpMLineIndex: Int32((message["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                                            sdpMid: message["sdpMid"] as? String)
            if connection.remoteDescription == nil {
                pendingCandidates[peer, default: []].append(candidate)
            } else {
                connection.add(candidate) { _ in }
            }
        default:
            break
        }
    }

    private func flushCandidates(for peer: MCPeerID) {
        guard let connection = connections[peer] else { return }
        pendingCandidates[peer]?.forEach { connection.add($0) { _ in } }
        pendingCandidates[peer] = []
    }

    private func updateHostStatus() {
        let viewers = connections.values.filter { $0.connectionState == .connected }.count
        setStatus(viewers == 0 ? "Live in \(config.roomName) — waiting for viewers"
                               : "Live — \(viewers) viewer\(viewers == 1 ? "" : "s")")
    }

    /// Audience FPS = frames of the host's video actually rendered each second.
    private func startAudienceFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.remoteVideoTrack != nil else { return }
            self.fpsLabel.text = "\(self.frameCounter.takeCount()) FPS"
        }
    }

    // MARK: - Nosmai (host only)

    private func requestPermissions(then start: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camera in
            guard camera else { self?.setStatus("Camera permission denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] mic in
                guard mic else { self?.setStatus("Microphone permission denied"); return }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func startNosmaiCamera() {
        guard !stopped else { return }
        setStatus("Starting Nosmai…")
        NosmaiCore.shared().initialize(withAPIKey: config.nosmaiAPIKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard success else {
                    self.setStatus("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard let camera = NosmaiCore.shared().camera else {
                    self.setStatus("Nosmai camera unavailable")
                    return
                }
                let cameraConfig = NosmaiCameraConfig()
                cameraConfig.position = .front
                cameraConfig.sessionPreset = AVCaptureSession.Preset.hd1280x720.rawValue
                cameraConfig.frameRate = 30
                camera.updateConfiguration(cameraConfig)
                camera.attach(to: self.videoView)

                guard camera.startCapture() else {
                    self.setStatus("Nosmai camera failed to start")
                    return
                }
                // Required for beauty / filters to render.
                NosmaiSDK.sharedInstance()?.startProcessing()
                self.cameraRunning = true
                self.effectsPanel.nosmaiReady()
                self.startSignaling()
            }
        }
    }

    /// Forward every filtered frame from Nosmai to the WebRTC video track.
    private func startPushingFrames() {
        guard cameraRunning, !pushing, !stopped else { return }
        pushing = true
        // Host FPS = filtered frames Nosmai actually delivers to WebRTC each second.
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pushLock.lock()
            let frames = self.framesSinceTick
            self.framesSinceTick = 0
            self.pushLock.unlock()
            self.fpsLabel.text = "\(frames) FPS"
        }
        NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
            guard let self, self.pushing else { return }
            self.pushLock.lock()
            self.framesSinceTick += 1
            self.pushLock.unlock()
            // Swift retains the buffer for the lifetime of the closure below.
            self.frameQueue.async {
                guard self.pushing, let source = self.videoSource, let capturer = self.videoCapturer else { return }
                let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                          rotation: ._0,
                                          timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
                source.capturer(capturer, didCapture: frame)
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEffects() {
        UIView.animate(withDuration: 0.2) {
            self.effectsPanel.isHidden.toggle()
            self.effectsPanel.alpha = self.effectsPanel.isHidden ? 0 : 1
        }
    }

    private func stopPushingFrames() {
        pushing = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    @objc private func flipCamera() {
        guard cameraRunning else { return }
        _ = NosmaiCore.shared().camera?.switch()
    }

    @objc private func close() {
        navigationController?.popViewController(animated: true)
    }

    private func stopSession() {
        guard !stopped else { return }
        stopped = true
        stopPushingFrames()
        if isHost {
            NosmaiCore.shared().liveFrameStreamCallback = nil
            frameQueue.sync {} // drain frames already queued before closing the connections
        } else {
            remoteVideoTrack?.remove(remoteVideoView)
            remoteVideoTrack?.remove(frameCounter)
            remoteVideoTrack = nil
        }
        signaling?.stop()
        signaling = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        pendingCandidates.removeAll()
        videoTrack = nil
        audioTrack = nil
        videoCapturer = nil
        videoSource = nil
        factory = nil

        if cameraRunning {
            cameraRunning = false
            let core = NosmaiCore.shared()
            core.effects?.clearAll() // the SDK is a singleton; don't leak effects into the next session
            core.camera?.stopCapture()
            core.camera?.detachFromView()
            core.cleanup()
        }
    }
}

// MARK: - RTCPeerConnectionDelegate
// WebRTC calls these on its own thread, so each one hops to the main queue.

extension LiveViewController: RTCPeerConnectionDelegate {
    /// Send our ICE candidates to the other phone.
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async {
            guard let peer = self.connections.first(where: { $0.value === peerConnection })?.key else { return }
            var message: [String: Any] = ["type": "candidate",
                                          "candidate": candidate.sdp,
                                          "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
            if let sdpMid = candidate.sdpMid { message["sdpMid"] = sdpMid }
            self.signaling?.send(message, to: peer)
        }
    }

    /// Audience: the host's video track arrived.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async {
            guard !self.isHost, !self.stopped else { return }
            self.remoteVideoTrack?.remove(self.remoteVideoView)
            self.remoteVideoTrack?.remove(self.frameCounter)
            track.add(self.remoteVideoView)
            track.add(self.frameCounter)
            self.remoteVideoTrack = track
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            guard !self.stopped, self.connections.values.contains(where: { $0 === peerConnection }) else { return }
            if self.isHost {
                self.updateHostStatus()
                return
            }
            switch newState {
            case .connected: self.setStatus("Watching host")
            case .disconnected: self.setStatus("Reconnecting…")
            case .failed: self.setStatus("Connection failed — are both phones on the same Wi-Fi?")
            default: break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Counts rendered frames so the audience can show an FPS figure.
private final class FrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count = 0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Returns the frames rendered since the last call.
    func takeCount() -> Int {
        lock.lock()
        defer { count = 0; lock.unlock() }
        return count
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
