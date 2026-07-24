@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
final class HandTrackingController {
    private(set) var state: HandTrackingState = .idle {
        didSet { stateHandler?(state) }
    }
    private(set) var availableCameras: [HandCameraDevice] = []
    private(set) var snapshot = HandTrackingSnapshot()
    private(set) var selectedCameraID: String?
    var preferredHand: PreferredHand {
        didSet {
            let events = interpreter.stop()
            snapshot = interpreter.snapshot
            eventHandler?(events, snapshot)
            defaults.set(preferredHand.rawValue, forKey: preferenceKey)
            interpreter.preferredHand = preferredHand
        }
    }

    @ObservationIgnored let captureSession = AVCaptureSession()
    @ObservationIgnored var eventHandler: (([HandPointerEvent], HandTrackingSnapshot) -> Void)?
    @ObservationIgnored var stateHandler: ((HandTrackingState) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let discoversCameras: Bool
    @ObservationIgnored private let preferenceKey: String
    @ObservationIgnored private let selectedCameraKey: String
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "ExtendReality.HandTracking.Capture")
    @ObservationIgnored private let outputDelegate = HandVideoOutputDelegate()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private var interpreter = HandGestureInterpreter()
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        preferencePrefix: String,
        discoversCameras: Bool = true
    ) {
        self.defaults = defaults
        self.discoversCameras = discoversCameras
        preferenceKey = "\(preferencePrefix).preferredHand"
        selectedCameraKey = "\(preferencePrefix).selectedCamera"
        preferredHand = defaults.string(forKey: preferenceKey)
            .flatMap(PreferredHand.init(rawValue:)) ?? .automatic
        selectedCameraID = defaults.string(forKey: selectedCameraKey)
        interpreter.preferredHand = preferredHand

        outputDelegate.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in self?.consume(frame) }
        }
        if discoversCameras {
            disconnectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let disconnectedID = (notification.object as? AVCaptureDevice)?.uniqueID
                Task { @MainActor [weak self] in
                    guard let self,
                          disconnectedID == self.selectedCameraID else { return }
                    self.stop(nextState: .failed("Selected camera disconnected"))
                    self.refreshCameras()
                }
            }
            refreshCameras()
        } else {
            state = .unavailable
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    var isRunning: Bool { state == .running }

    func refreshCameras() {
        guard discoversCameras else {
            availableCameras = []
            selectedCameraID = nil
            state = .unavailable
            return
        }
        let devices = Self.discoverDevices()
        availableCameras = devices.map {
            HandCameraDevice(
                id: $0.uniqueID,
                name: $0.localizedName,
                isTrueDepth: Self.isTrueDepth($0),
                isContinuity: Self.isContinuity($0)
            )
        }
        if !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = availableCameras.first?.id
        }
        if availableCameras.isEmpty, state != .running {
            state = .unavailable
        } else if state == .unavailable {
            state = .idle
        }
    }

    func selectCamera(_ id: String?) {
        guard selectedCameraID != id else { return }
        let shouldRestart = isRunning
        if shouldRestart { stop() }
        selectedCameraID = id
        defaults.set(id, forKey: selectedCameraKey)
        if shouldRestart { Task { await start() } }
    }

    func setOrientation(_ orientation: HandCameraOrientation) {
        #if os(macOS)
        outputDelegate.orientation = .upMirrored
        #else
        outputDelegate.orientation = HandCameraGeometry.imageOrientation(for: orientation, mirrored: true)
        #endif
    }

    func start() async {
        guard !isRunning, state != .requestingPermission else { return }
        refreshCameras()
        guard let device = selectedDevice() else {
            state = .unavailable
            return
        }

        let id = UUID()
        runID = id
        state = .requestingPermission
        let authorized = await requestCameraAccess()
        guard runID == id else { return }
        guard authorized else {
            runID = nil
            state = .denied
            return
        }

        do {
            try configureSession(device: device)
        } catch {
            runID = nil
            state = .failed(error.localizedDescription)
            return
        }

        guard runID == id else { return }
        let session = captureSession
        sessionQueue.async { [weak self] in
            session.startRunning()
            Task { @MainActor [weak self] in
                guard let self, self.runID == id else { return }
                self.state = .running
            }
        }
    }

    func stop() {
        stop(nextState: availableCameras.isEmpty ? .unavailable : .idle)
    }

    func stop(nextState: HandTrackingState) {
        runID = nil
        let events = interpreter.stop()
        snapshot = interpreter.snapshot
        eventHandler?(events, snapshot)
        state = nextState
        let session = captureSession
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func consume(_ frame: HandPoseFrame) {
        guard runID != nil else { return }
        interpreter.preferredHand = preferredHand
        let events = interpreter.consume(frame)
        snapshot = interpreter.snapshot
        eventHandler?(events, snapshot)
    }

    private func configureSession(device: AVCaptureDevice) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }

        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw HandTrackingError.cannotAddCamera }
        captureSession.addInput(input)
        configureThirtyFPSIfSupported(device)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.setSampleBufferDelegate(outputDelegate, queue: outputDelegate.queue)
        guard captureSession.canAddOutput(videoOutput) else { throw HandTrackingError.cannotAddOutput }
        captureSession.addOutput(videoOutput)
    }

    private func configureThirtyFPSIfSupported(_ device: AVCaptureDevice) {
        let framesPerSecond = 30.0
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= framesPerSecond && $0.maxFrameRate >= framesPerSecond
        }) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            // Some virtual and Continuity cameras own their frame cadence.
        }
    }

    private func selectedDevice() -> AVCaptureDevice? {
        let devices = Self.discoverDevices()
        return devices.first(where: { $0.uniqueID == selectedCameraID }) ?? devices.first
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    private static func discoverDevices() -> [AVCaptureDevice] {
        #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
        return devices.sorted { lhs, rhs in
            let leftRank = lhs.deviceType == .builtInWideAngleCamera ? 0 : lhs.deviceType == .continuityCamera ? 1 : 2
            let rightRank = rhs.deviceType == .builtInWideAngleCamera ? 0 : rhs.deviceType == .continuityCamera ? 1 : 2
            return leftRank == rightRank ? lhs.localizedName < rhs.localizedName : leftRank < rightRank
        }
        #else
        let types: [AVCaptureDevice.DeviceType] = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .front
        ).devices
        return devices.sorted { lhs, rhs in
            if lhs.deviceType == rhs.deviceType { return lhs.localizedName < rhs.localizedName }
            return lhs.deviceType == .builtInTrueDepthCamera
        }
        #endif
    }

    private static func isTrueDepth(_ device: AVCaptureDevice) -> Bool {
        #if os(iOS)
        device.deviceType == .builtInTrueDepthCamera
        #else
        false
        #endif
    }

    private static func isContinuity(_ device: AVCaptureDevice) -> Bool {
        #if os(macOS)
        device.deviceType == .continuityCamera
        #else
        false
        #endif
    }

}

private enum HandTrackingError: LocalizedError {
    case cannotAddCamera
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddCamera: "Unable to add the selected camera"
        case .cannotAddOutput: "Unable to configure camera frames"
        }
    }
}

private final class HandVideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ExtendReality.HandTracking.Vision", qos: .userInteractive)
    var onFrame: (@Sendable (HandPoseFrame) -> Void)?

    private let detector = VisionHandPoseDetector()
    private let lock = NSLock()
    private var storedOrientation: CGImagePropertyOrientation = {
        #if os(macOS)
        .upMirrored
        #else
        .leftMirrored
        #endif
    }()

    var orientation: CGImagePropertyOrientation {
        get { lock.withLock { storedOrientation } }
        set { lock.withLock { storedOrientation = newValue } }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = presentationTime.isValid ? CMTimeGetSeconds(presentationTime) : ProcessInfo.processInfo.systemUptime
        let frame = detector.detect(in: pixelBuffer, orientation: orientation, timestamp: seconds)
        onFrame?(frame)
    }
}
