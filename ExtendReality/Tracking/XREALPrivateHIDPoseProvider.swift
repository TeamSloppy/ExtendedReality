#if DEBUG && os(iOS)
import Darwin
import Foundation
import OSLog
import simd

enum XREALPrivateHIDExperiment {
    static let enabledDefaultsKey = "XREALPrivateHIDEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }
}

enum XREALPrivateHIDPacketCodec {
    static let vendorID = 0x3318
    static let productID = 0x0424

    struct Vector: Equatable, Sendable {
        var x: Double
        var y: Double
        var z: Double

        var simd: SIMD3<Double> { SIMD3(x, y, z) }
    }

    struct Sample: Equatable, Sendable {
        var temperature: Int16
        var timestamp: UInt64
        var gyro: Vector
        var acceleration: Vector
        var magnetometer: Vector
    }

    struct ControlPacket: Equatable, Sendable {
        var messageID: UInt8
        var payload: Data
    }

    static func parseSensor(_ data: Data) -> Sample? {
        guard data.count == 64, data[0] == 1 else { return nil }
        var cursor = XREALPrivateByteCursor(data: data, offset: 2)
        guard let temperature = cursor.int16LE(),
              let timestamp = cursor.uint64LE(),
              let gyroMultiplier = cursor.int16LE(),
              let gyroDivisor = cursor.int32LE(),
              let gx = cursor.int24LE(),
              let gy = cursor.int24LE(),
              let gz = cursor.int24LE(),
              let accelMultiplier = cursor.int16LE(),
              let accelDivisor = cursor.int32LE(),
              let ax = cursor.int24LE(),
              let ay = cursor.int24LE(),
              let az = cursor.int24LE(),
              let magMultiplier = cursor.int16BE(),
              let magDivisor = cursor.int32BE(),
              let mx = cursor.int15LE(),
              let my = cursor.int15LE(),
              let mz = cursor.int15LE(),
              gyroDivisor != 0,
              accelDivisor != 0,
              magDivisor != 0 else {
            return nil
        }

        let gyroScale = Double(gyroMultiplier) / Double(gyroDivisor)
        let accelScale = Double(accelMultiplier) / Double(accelDivisor)
        let magScale = Double(magMultiplier) / Double(magDivisor)
        return Sample(
            temperature: temperature,
            timestamp: timestamp,
            gyro: Vector(
                x: Double(gx) * gyroScale,
                y: Double(gy) * gyroScale,
                z: Double(gz) * gyroScale
            ),
            acceleration: Vector(
                x: Double(ax) * accelScale,
                y: Double(ay) * accelScale,
                z: Double(az) * accelScale
            ),
            magnetometer: Vector(
                x: Double(mx) * magScale,
                y: Double(my) * magScale,
                z: Double(mz) * magScale
            )
        )
    }

    static func command(messageID: UInt8, data: Data = Data()) -> Data {
        let packetLength = UInt16(3 + data.count)
        var packet = Data(repeating: 0, count: 8 + data.count)
        packet[0] = 0xAA
        packet[5] = UInt8(packetLength & 0xff)
        packet[6] = UInt8(packetLength >> 8)
        packet[7] = messageID
        packet.replaceSubrange(8..<packet.count, with: data)
        let checksum = crc32(packet.subdata(in: 5..<(5 + Int(packetLength))))
        packet[1] = UInt8(checksum & 0xff)
        packet[2] = UInt8((checksum >> 8) & 0xff)
        packet[3] = UInt8((checksum >> 16) & 0xff)
        packet[4] = UInt8((checksum >> 24) & 0xff)
        return packet
    }

    static func parseControl(_ data: Data) -> ControlPacket? {
        guard data.count >= 8, data[0] == 0xAA else { return nil }
        let packetLength = Int(UInt16(data[5]) | UInt16(data[6]) << 8)
        guard packetLength >= 3, 5 + packetLength <= data.count else { return nil }
        let expected = UInt32(data[1])
            | UInt32(data[2]) << 8
            | UInt32(data[3]) << 16
            | UInt32(data[4]) << 24
        guard expected == crc32(data.subdata(in: 5..<(5 + packetLength))) else {
            return nil
        }
        return ControlPacket(
            messageID: data[7],
            payload: data.subdata(in: 8..<(5 + packetLength))
        )
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }
}

private struct XREALPrivateCalibration: Sendable {
    var accelBias = SIMD3<Double>.zero
    var gyroBias = SIMD3<Double>.zero
    var accelScale = SIMD3<Double>(repeating: 1)
    var gyroScale = SIMD3<Double>(repeating: 1)
    var accelQGyro = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))

    static func decode(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imu = root["IMU"] as? [String: Any],
              let device = imu["device_1"] as? [String: Any] else {
            return nil
        }

        func vector(_ key: String, fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let values = device[key] as? [NSNumber], values.count == 3 else {
                return fallback
            }
            return SIMD3(
                values[0].doubleValue,
                values[1].doubleValue,
                values[2].doubleValue
            )
        }

        func quaternion(_ key: String) -> simd_quatd {
            guard let values = device[key] as? [NSNumber], values.count == 4 else {
                return simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            }
            return simd_normalize(simd_quatd(
                ix: values[0].doubleValue,
                iy: values[1].doubleValue,
                iz: values[2].doubleValue,
                r: values[3].doubleValue
            ))
        }

        return XREALPrivateCalibration(
            accelBias: vector("accel_bias", fallback: .zero),
            gyroBias: vector("gyro_bias", fallback: .zero),
            accelScale: vector("scale_accel", fallback: SIMD3(repeating: 1)),
            gyroScale: vector("scale_gyro", fallback: SIMD3(repeating: 1)),
            accelQGyro: quaternion("accel_q_gyro")
        )
    }
}

private struct XREALPrivateTimestampUnwrapper: Sendable {
    private(set) var lastRaw: UInt32?
    private(set) var accumulated: UInt64 = 0

    mutating func consume(_ rawTimestamp: UInt64) -> UInt64 {
        let next = UInt32(rawTimestamp & 0x00ff_ffff)
        guard let lastRaw else {
            self.lastRaw = next
            return accumulated
        }
        let delta = (next &- lastRaw) & 0x00ff_ffff
        accumulated &+= UInt64(delta)
        self.lastRaw = next
        return accumulated
    }

    mutating func reset() {
        lastRaw = nil
        accumulated = 0
    }
}

private struct XREALPrivateQuaternionFusion: Sendable {
    private(set) var orientation = simd_quatd(
        angle: 0,
        axis: SIMD3<Double>(0, 1, 0)
    )
    private var lastTimestamp: UInt64?

    mutating func update(
        timestamp: UInt64,
        gyroRadiansPerSecond: SIMD3<Double>,
        acceleration: SIMD3<Double>
    ) -> simd_quatd {
        guard let lastTimestamp else {
            self.lastTimestamp = timestamp
            return orientation
        }
        let delta = timestamp &- lastTimestamp
        let deltaTime = min(max(Double(delta) / 1_000_000_000, 0), 0.05)
        self.lastTimestamp = timestamp
        guard deltaTime > 0 else { return orientation }

        var omega = gyroRadiansPerSecond
        let accelerationLength = simd_length(acceleration)
        if accelerationLength > 0.35, accelerationLength < 2.5 {
            let measuredGravity = simd_normalize(acceleration)
            let expectedGravity = orientation.inverse.act(SIMD3<Double>(0, -1, 0))
            omega += simd_cross(measuredGravity, expectedGravity) * 1.8
        }

        let speed = simd_length(omega)
        if speed > 0 {
            orientation = simd_normalize(
                orientation * simd_quatd(
                    angle: speed * deltaTime,
                    axis: omega / speed
                )
            )
        }
        return orientation
    }

    mutating func reset() {
        orientation = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
        lastTimestamp = nil
    }
}

private struct PrivateIOHIDAPI {
    typealias DeviceCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void

    typealias InputReportCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32,
        UnsafeMutablePointer<UInt8>?,
        CFIndex
    ) -> Void

    typealias ManagerCreate = @convention(c) (
        UnsafeRawPointer?,
        UInt32
    ) -> UnsafeMutableRawPointer?
    typealias ManagerSetDeviceMatching = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?
    ) -> Void
    typealias ManagerRegisterDeviceCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        DeviceCallback?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias ManagerSchedule = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?
    ) -> Void
    typealias ManagerOpen = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32
    ) -> Int32
    typealias ManagerCopyDevices = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    typealias DeviceOpen = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32
    ) -> Int32
    typealias DeviceClose = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32
    ) -> Int32
    typealias DeviceGetProperty = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?
    ) -> UnsafeRawPointer?
    typealias DeviceRegisterInputReportCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt8>?,
        CFIndex,
        InputReportCallback?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias DeviceSetReport = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32,
        CFIndex,
        UnsafePointer<UInt8>?,
        CFIndex
    ) -> Int32

    let handle: UnsafeMutableRawPointer
    let managerCreate: ManagerCreate
    let managerSetDeviceMatching: ManagerSetDeviceMatching
    let managerRegisterDeviceMatchingCallback: ManagerRegisterDeviceCallback
    let managerRegisterDeviceRemovalCallback: ManagerRegisterDeviceCallback
    let managerSchedule: ManagerSchedule
    let managerOpen: ManagerOpen
    let managerCopyDevices: ManagerCopyDevices?
    let deviceOpen: DeviceOpen
    let deviceClose: DeviceClose
    let deviceGetProperty: DeviceGetProperty
    let deviceRegisterInputReportCallback: DeviceRegisterInputReportCallback
    let deviceSetReport: DeviceSetReport

    init?() {
        let paths = [
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
        ]
        guard let handle = paths.lazy.compactMap({
            dlopen($0, RTLD_NOW | RTLD_LOCAL)
        }).first else {
            return nil
        }

        guard let managerCreate = Self.symbol(
            "IOHIDManagerCreate",
            from: handle,
            as: ManagerCreate.self
        ), let managerSetDeviceMatching = Self.symbol(
            "IOHIDManagerSetDeviceMatching",
            from: handle,
            as: ManagerSetDeviceMatching.self
        ), let managerRegisterDeviceMatchingCallback = Self.symbol(
            "IOHIDManagerRegisterDeviceMatchingCallback",
            from: handle,
            as: ManagerRegisterDeviceCallback.self
        ), let managerRegisterDeviceRemovalCallback = Self.symbol(
            "IOHIDManagerRegisterDeviceRemovalCallback",
            from: handle,
            as: ManagerRegisterDeviceCallback.self
        ), let managerSchedule = Self.symbol(
            "IOHIDManagerScheduleWithRunLoop",
            from: handle,
            as: ManagerSchedule.self
        ), let managerOpen = Self.symbol(
            "IOHIDManagerOpen",
            from: handle,
            as: ManagerOpen.self
        ), let deviceOpen = Self.symbol(
            "IOHIDDeviceOpen",
            from: handle,
            as: DeviceOpen.self
        ), let deviceClose = Self.symbol(
            "IOHIDDeviceClose",
            from: handle,
            as: DeviceClose.self
        ), let deviceGetProperty = Self.symbol(
            "IOHIDDeviceGetProperty",
            from: handle,
            as: DeviceGetProperty.self
        ), let deviceRegisterInputReportCallback = Self.symbol(
            "IOHIDDeviceRegisterInputReportCallback",
            from: handle,
            as: DeviceRegisterInputReportCallback.self
        ), let deviceSetReport = Self.symbol(
            "IOHIDDeviceSetReport",
            from: handle,
            as: DeviceSetReport.self
        ) else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.managerCreate = managerCreate
        self.managerSetDeviceMatching = managerSetDeviceMatching
        self.managerRegisterDeviceMatchingCallback = managerRegisterDeviceMatchingCallback
        self.managerRegisterDeviceRemovalCallback = managerRegisterDeviceRemovalCallback
        self.managerSchedule = managerSchedule
        self.managerOpen = managerOpen
        self.managerCopyDevices = Self.symbol(
            "IOHIDManagerCopyDevices",
            from: handle,
            as: ManagerCopyDevices.self
        )
        self.deviceOpen = deviceOpen
        self.deviceClose = deviceClose
        self.deviceGetProperty = deviceGetProperty
        self.deviceRegisterInputReportCallback = deviceRegisterInputReportCallback
        self.deviceSetReport = deviceSetReport
    }

    private static func symbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}

@MainActor
final class XREALPrivateHIDPoseProvider: HeadPoseProvider, HeadPoseDiagnosticsProviding {
    private static let logger = Logger(
        subsystem: "xr.sloppy.team.ExtendReality",
        category: "XREALPrivateHID"
    )

    let displayName = "XREAL Air private USB"
    private(set) var availability: HeadPoseAvailability

    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var api: PrivateIOHIDAPI?
    private var manager: UnsafeMutableRawPointer?
    private var allHIDProbeManager: UnsafeMutableRawPointer?
    private var devices: [UInt: UnsafeMutableRawPointer] = [:]
    private var reportBuffers: [UInt: UnsafeMutablePointer<UInt8>] = [:]
    private var probedDeviceIDs: Set<UInt> = []
    private var probeDescriptions: [String] = []
    private var allHIDProbeFailure: String?
    private var foundXREALVendor = false
    private var probeTask: Task<Void, Never>?
    private var calibrationBuffer = Data()
    private var expectedCalibrationLength = 0
    private var calibration: XREALPrivateCalibration?
    private var unwrapper = XREALPrivateTimestampUnwrapper()
    private var fusion = XREALPrivateQuaternionFusion()
    private var referenceQuaternion: simd_quatd?
    private var smoother = HeadPoseSmoother(responseTime: 0.018)
    private var lastPublishTime: TimeInterval = 0

    var diagnosticsText: String? {
        let state: String
        switch availability {
        case .available:
            state = "XREAL 3DoF active"
        case .waiting(let reason), .unavailable(let reason):
            state = reason
        }
        var lines = [state]
        if !probeDescriptions.isEmpty {
            lines.append(
                "Visible HID (\(probeDescriptions.count)): "
                    + probeDescriptions.prefix(8).joined(separator: "; ")
            )
        }
        if let allHIDProbeFailure {
            lines.append(allHIDProbeFailure)
        }
        return lines.joined(separator: "\n")
    }

    init() {
        let channel = AsyncStream<HeadPoseEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        events = channel.stream
        continuation = channel.continuation

        guard XREALPrivateHIDExperiment.isEnabled else {
            availability = .unavailable(
                reason: "Private XREAL HID experiment is disabled"
            )
            continuation.yield(.availability(availability))
            continuation.yield(.pose(.identity))
            return
        }

        availability = .waiting(reason: "Loading private iOS IOHID…")
        continuation.yield(.availability(availability))
        start()
    }

    deinit {
        MainActor.assumeIsolated {
            probeTask?.cancel()
            for (key, device) in devices {
                _ = api?.deviceClose(device, 0)
                reportBuffers[key]?.deallocate()
            }
            devices.removeAll()
            reportBuffers.removeAll()
        }
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        events
    }

    func recenter() {
        referenceQuaternion = fusion.orientation
        smoother.reset()
        continuation.yield(.pose(.identity))
    }

    private func start() {
        guard let api = PrivateIOHIDAPI() else {
            let message = "Private IOHID symbols are unavailable on this iOS build"
            Self.logger.error("\(message, privacy: .public)")
            updateAvailability(.unavailable(reason: message))
            return
        }
        guard let manager = api.managerCreate(nil, 0) else {
            let message = "IOHIDManagerCreate returned nil"
            Self.logger.error("\(message, privacy: .public)")
            updateAvailability(.unavailable(reason: message))
            return
        }
        self.api = api
        self.manager = manager

        // The functional manager matches the XREAL vendor only, deliberately
        // omitting ProductID so firmware variants are not excluded.
        let matching: NSDictionary = [
            "VendorID": XREALPrivateHIDPacketCodec.vendorID,
        ]
        api.managerSetDeviceMatching(
            manager,
            Unmanaged.passUnretained(matching).toOpaque()
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        api.managerRegisterDeviceMatchingCallback(
            manager,
            Self.deviceMatched,
            context
        )
        api.managerRegisterDeviceRemovalCallback(
            manager,
            Self.deviceRemoved,
            context
        )

        guard let runLoop = CFRunLoopGetMain() else {
            updateAvailability(
                .unavailable(reason: "Main run loop is unavailable")
            )
            return
        }
        let commonModes = CFRunLoopMode.commonModes.rawValue
        api.managerSchedule(
            manager,
            Unmanaged.passUnretained(runLoop).toOpaque(),
            Unmanaged.passUnretained(commonModes).toOpaque()
        )

        let result = api.managerOpen(manager, 0)
        guard result == 0 else {
            let message = "IOHIDManagerOpen failed (\(Self.hex(result)))"
            Self.logger.error("\(message, privacy: .public)")
            updateAvailability(.unavailable(reason: message))
            return
        }

        Self.logger.notice(
            "Private XREAL-vendor IOHID manager opened"
        )
        updateAvailability(
            .waiting(reason: "Private IOHID open — probing visible HID services…")
        )
        enumerateVisibleDevices(from: manager, opensXREAL: true)
        startAllHIDProbe()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finishProbe()
        }
    }

    private func attach(_ device: UnsafeMutableRawPointer) {
        guard let api else { return }
        let key = UInt(bitPattern: device)
        let identity = recordProbeDevice(device)

        guard identity.vendorID == XREALPrivateHIDPacketCodec.vendorID else {
            return
        }
        foundXREALVendor = true
        guard devices[key] == nil else { return }
        Self.logger.notice(
            "XREAL vendor HID visible: \(identity.description, privacy: .public)"
        )

        let openResult = api.deviceOpen(device, 0)
        guard openResult == 0 else {
            let message = """
            XREAL HID \(Self.hexID(identity.productID)) found; IOHIDDeviceOpen failed \
            (\(Self.hex(openResult)))
            """
            Self.logger.error("\(message, privacy: .public)")
            updateAvailability(.unavailable(reason: message))
            return
        }

        devices[key] = device
        let maximum = integerProperty("MaxInputReportSize", of: device) ?? 64
        let length = max(maximum, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        reportBuffers[key] = buffer
        api.deviceRegisterInputReportCallback(
            device,
            buffer,
            length,
            Self.inputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )

        Self.logger.notice(
            "XREAL HID opened; \(identity.description, privacy: .public), maxReport=\(length)"
        )
        updateAvailability(
            .waiting(
                reason: "XREAL HID \(Self.hexID(identity.productID)) open — reading calibration…"
            )
        )
        send(messageID: 0x19, payload: Data([0xAA]))
        send(messageID: 0x14)
    }

    private func detach(_ device: UnsafeMutableRawPointer) {
        guard let api else { return }
        let key = UInt(bitPattern: device)
        probedDeviceIDs.remove(key)
        guard let openedDevice = devices.removeValue(forKey: key) else {
            return
        }
        if let buffer = reportBuffers.removeValue(forKey: key) {
            buffer.deallocate()
        }
        _ = api.deviceClose(openedDevice, 0)

        guard devices.isEmpty else { return }
        calibration = nil
        expectedCalibrationLength = 0
        calibrationBuffer.removeAll()
        unwrapper.reset()
        fusion.reset()
        referenceQuaternion = nil
        Self.logger.notice("XREAL HID disconnected")
        updateAvailability(.waiting(reason: "XREAL disconnected — AirPods fallback"))
    }

    private func consume(_ data: Data) {
        if let packet = XREALPrivateHIDPacketCodec.parseControl(data) {
            consume(packet)
            return
        }
        guard let sample = XREALPrivateHIDPacketCodec.parseSensor(data) else {
            return
        }
        guard let calibration else {
            send(messageID: 0x19, payload: Data([0xAA]))
            return
        }

        let tick = unwrapper.consume(sample.timestamp)
        let gyro = Self.calibratedGyro(sample.gyro.simd, calibration: calibration)
        let acceleration = Self.calibratedAcceleration(
            sample.acceleration.simd,
            calibration: calibration
        )
        let quaternion = fusion.update(
            timestamp: tick,
            gyroRadiansPerSecond: gyro,
            acceleration: acceleration
        )
        if referenceQuaternion == nil {
            referenceQuaternion = quaternion
        }
        guard let referenceQuaternion else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishTime >= 1.0 / 120.0 else { return }
        lastPublishTime = now

        let relative = simd_normalize(referenceQuaternion.inverse * quaternion)
        let angles = Self.eulerDegrees(relative)
        continuation.yield(.pose(smoother.filter(HeadPose(
            yaw: angles.yaw,
            pitch: angles.pitch,
            roll: angles.roll,
            timestamp: now
        ))))
        if availability != .available {
            Self.logger.notice("XREAL private USB 3DoF is active")
            updateAvailability(.available)
        }
    }

    private func consume(_ packet: XREALPrivateHIDPacketCodec.ControlPacket) {
        switch packet.messageID {
        case 0x14:
            guard packet.payload.count >= 4 else { return }
            expectedCalibrationLength = Int(
                UInt32(packet.payload[0])
                    | UInt32(packet.payload[1]) << 8
                    | UInt32(packet.payload[2]) << 16
                    | UInt32(packet.payload[3]) << 24
            )
            calibrationBuffer.removeAll(keepingCapacity: true)
            guard expectedCalibrationLength > 0 else {
                updateAvailability(
                    .unavailable(reason: "XREAL reported empty calibration")
                )
                return
            }
            send(messageID: 0x15)

        case 0x15:
            guard expectedCalibrationLength > 0 else {
                send(messageID: 0x14)
                return
            }
            let remaining = expectedCalibrationLength - calibrationBuffer.count
            calibrationBuffer.append(packet.payload.prefix(max(remaining, 0)))
            if calibrationBuffer.count >= expectedCalibrationLength {
                calibration = XREALPrivateCalibration.decode(calibrationBuffer)
                guard calibration != nil else {
                    updateAvailability(
                        .unavailable(reason: "XREAL factory calibration is invalid")
                    )
                    return
                }
                Self.logger.notice(
                    "XREAL calibration loaded; starting IMU reports"
                )
                send(messageID: 0x19, payload: Data([0x01]))
                updateAvailability(.waiting(reason: "XREAL calibration loaded — starting IMU…"))
            } else {
                send(messageID: 0x15)
            }

        default:
            break
        }
    }

    private func send(messageID: UInt8, payload: Data = Data()) {
        guard let api else { return }
        let packet = XREALPrivateHIDPacketCodec.command(
            messageID: messageID,
            data: payload
        )
        var lastResult: Int32?
        for device in devices.values {
            let result = packet.withUnsafeBytes { bytes in
                api.deviceSetReport(
                    device,
                    1,
                    0,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    packet.count
                )
            }
            lastResult = result
            if result == 0 {
                return
            }
        }

        if let lastResult {
            let message = "XREAL IOHIDDeviceSetReport failed (\(Self.hex(lastResult)))"
            Self.logger.error("\(message, privacy: .public)")
            updateAvailability(.unavailable(reason: message))
        }
    }

    private func integerProperty(
        _ name: String,
        of device: UnsafeMutableRawPointer
    ) -> Int? {
        guard let api else { return nil }
        let key = name as NSString
        guard let rawValue = api.deviceGetProperty(
            device,
            Unmanaged.passUnretained(key).toOpaque()
        ) else {
            return nil
        }
        let value = Unmanaged<AnyObject>
            .fromOpaque(UnsafeMutableRawPointer(mutating: rawValue))
            .takeUnretainedValue()
        return (value as? NSNumber)?.intValue
    }

    private func stringProperty(
        _ name: String,
        of device: UnsafeMutableRawPointer
    ) -> String? {
        guard let api else { return nil }
        let key = name as NSString
        guard let rawValue = api.deviceGetProperty(
            device,
            Unmanaged.passUnretained(key).toOpaque()
        ) else {
            return nil
        }
        return Unmanaged<AnyObject>
            .fromOpaque(UnsafeMutableRawPointer(mutating: rawValue))
            .takeUnretainedValue() as? String
    }

    private func startAllHIDProbe() {
        guard let api, let probeManager = api.managerCreate(nil, 0) else {
            allHIDProbeFailure = "All-HID probe: IOHIDManagerCreate returned nil"
            return
        }
        api.managerSetDeviceMatching(probeManager, nil)
        let result = api.managerOpen(probeManager, 0)
        guard result == 0 else {
            allHIDProbeFailure = "All-HID probe open failed (\(Self.hex(result)))"
            Self.logger.error(
                "\(self.allHIDProbeFailure ?? "All-HID probe failed", privacy: .public)"
            )
            return
        }
        allHIDProbeManager = probeManager
        enumerateVisibleDevices(from: probeManager, opensXREAL: true)
    }

    private func enumerateVisibleDevices(
        from manager: UnsafeMutableRawPointer,
        opensXREAL: Bool
    ) {
        guard let copyDevices = api?.managerCopyDevices,
              let rawSet = copyDevices(manager) else {
            Self.logger.notice(
                "IOHIDManagerCopyDevices unavailable; relying on match callbacks"
            )
            return
        }

        let set = Unmanaged<CFSet>.fromOpaque(rawSet).takeRetainedValue()
        let count = CFSetGetCount(set)
        guard count > 0 else { return }
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        values.withUnsafeMutableBufferPointer { buffer in
            CFSetGetValues(set, buffer.baseAddress)
        }
        for case let rawDevice? in values {
            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            if opensXREAL {
                attach(device)
            } else {
                _ = recordProbeDevice(device)
            }
        }
    }

    private func recordProbeDevice(
        _ device: UnsafeMutableRawPointer
    ) -> (vendorID: Int?, productID: Int?, description: String) {
        let vendorID = integerProperty("VendorID", of: device)
        let productID = integerProperty("ProductID", of: device)
        let description = Self.deviceDescription(
            vendorID: vendorID,
            productID: productID,
            usagePage: integerProperty("PrimaryUsagePage", of: device),
            usage: integerProperty("PrimaryUsage", of: device),
            product: stringProperty("Product", of: device),
            transport: stringProperty("Transport", of: device)
        )
        let key = UInt(bitPattern: device)
        if probedDeviceIDs.insert(key).inserted {
            probeDescriptions.append(description)
            Self.logger.notice("HID probe: \(description, privacy: .public)")
        }
        return (vendorID, productID, description)
    }

    private func finishProbe() {
        guard devices.isEmpty, !foundXREALVendor else { return }
        let message = """
        No XREAL vendor HID visible to the app \
        (\(probeDescriptions.count) HID services enumerated)
        """
        Self.logger.error("\(message, privacy: .public)")
        updateAvailability(.unavailable(reason: message))
    }

    private static func deviceDescription(
        vendorID: Int?,
        productID: Int?,
        usagePage: Int?,
        usage: Int?,
        product: String?,
        transport: String?
    ) -> String {
        var parts = [
            "\(hexID(vendorID)):\(hexID(productID))",
            "usage \(hexID(usagePage))/\(hexID(usage))",
        ]
        if let product, !product.isEmpty {
            parts.append(product)
        }
        if let transport, !transport.isEmpty {
            parts.append(transport)
        }
        return parts.joined(separator: " ")
    }

    private static func hexID(_ value: Int?) -> String {
        guard let value else { return "----" }
        return String(format: "%04X", value)
    }

    private func updateAvailability(_ value: HeadPoseAvailability) {
        guard value != availability else { return }
        availability = value
        continuation.yield(.availability(value))
    }

    private static func calibratedGyro(
        _ value: SIMD3<Double>,
        calibration: XREALPrivateCalibration
    ) -> SIMD3<Double> {
        var aligned = calibration.accelQGyro.act(value) * (.pi / 180)
        aligned = preCalibrationCoordinates(aligned)
        aligned = (aligned - calibration.gyroBias) * calibration.gyroScale
        return postCalibrationCoordinates(aligned)
    }

    private static func calibratedAcceleration(
        _ value: SIMD3<Double>,
        calibration: XREALPrivateCalibration
    ) -> SIMD3<Double> {
        var aligned = value * 9.80665
        aligned = preCalibrationCoordinates(aligned)
        aligned = (aligned - calibration.accelBias) * calibration.accelScale
        return postCalibrationCoordinates(aligned)
    }

    private static func preCalibrationCoordinates(
        _ value: SIMD3<Double>
    ) -> SIMD3<Double> {
        SIMD3(-value.x, -value.z, -value.y)
    }

    private static func postCalibrationCoordinates(
        _ value: SIMD3<Double>
    ) -> SIMD3<Double> {
        SIMD3(value.x, -value.y, -value.z)
    }

    private static func eulerDegrees(
        _ quaternion: simd_quatd
    ) -> (yaw: Double, pitch: Double, roll: Double) {
        let q = quaternion.vector
        let x = q.x
        let y = q.y
        let z = q.z
        let w = q.w
        let yaw = atan2(2 * (w * y + x * z), 1 - 2 * (y * y + x * x))
        let pitch = asin(
            (2 * (w * x - z * y)).clamped(to: -1 ... 1)
        )
        let roll = atan2(2 * (w * z + x * y), 1 - 2 * (z * z + x * x))
        let scale = 180 / Double.pi
        return (-yaw * scale, pitch * scale, -roll * scale)
    }

    private static func hex(_ result: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: result))
    }

    private static let deviceMatched: PrivateIOHIDAPI.DeviceCallback = {
        context,
        _,
        _,
        device in
        guard let context, let device else { return }
        let contextAddress = UInt(bitPattern: context)
        let deviceAddress = UInt(bitPattern: device)
        MainActor.assumeIsolated {
            guard let context = UnsafeMutableRawPointer(
                bitPattern: contextAddress
            ), let device = UnsafeMutableRawPointer(
                bitPattern: deviceAddress
            ) else {
                return
            }
            Unmanaged<XREALPrivateHIDPoseProvider>
                .fromOpaque(context)
                .takeUnretainedValue()
                .attach(device)
        }
    }

    private static let deviceRemoved: PrivateIOHIDAPI.DeviceCallback = {
        context,
        _,
        _,
        device in
        guard let context, let device else { return }
        let contextAddress = UInt(bitPattern: context)
        let deviceAddress = UInt(bitPattern: device)
        MainActor.assumeIsolated {
            guard let context = UnsafeMutableRawPointer(
                bitPattern: contextAddress
            ), let device = UnsafeMutableRawPointer(
                bitPattern: deviceAddress
            ) else {
                return
            }
            Unmanaged<XREALPrivateHIDPoseProvider>
                .fromOpaque(context)
                .takeUnretainedValue()
                .detach(device)
        }
    }

    private static let inputReport: PrivateIOHIDAPI.InputReportCallback = {
        context,
        result,
        _,
        _,
        _,
        report,
        length in
        guard result == 0,
              let context,
              let report,
              length > 0 else {
            return
        }
        let contextAddress = UInt(bitPattern: context)
        let data = Data(bytes: report, count: length)
        MainActor.assumeIsolated {
            guard let context = UnsafeMutableRawPointer(
                bitPattern: contextAddress
            ) else {
                return
            }
            Unmanaged<XREALPrivateHIDPoseProvider>
                .fromOpaque(context)
                .takeUnretainedValue()
                .consume(data)
        }
    }
}

@MainActor
final class IOSPreferredHeadPoseProvider:
    HeadPoseProvider,
    HeadPoseDiagnosticsProviding
{
    private(set) var displayName = "XREAL/AirPods"
    private(set) var availability: HeadPoseAvailability = .waiting(
        reason: "Starting head tracking…"
    )

    private let primary: any HeadPoseProvider
    private let fallback: any HeadPoseProvider
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var primaryAvailability: HeadPoseAvailability
    private var fallbackAvailability: HeadPoseAvailability
    private var primaryTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    var diagnosticsText: String? {
        (primary as? any HeadPoseDiagnosticsProviding)?.diagnosticsText
    }

    init(primary: any HeadPoseProvider, fallback: any HeadPoseProvider) {
        self.primary = primary
        self.fallback = fallback
        primaryAvailability = primary.availability
        fallbackAvailability = fallback.availability
        let channel = AsyncStream<HeadPoseEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        events = channel.stream
        continuation = channel.continuation
        primaryTask = observe(primary, isPrimary: true)
        fallbackTask = observe(fallback, isPrimary: false)
        updateSelection()
    }

    deinit {
        primaryTask?.cancel()
        fallbackTask?.cancel()
        continuation.finish()
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        events
    }

    func recenter() {
        primary.recenter()
        fallback.recenter()
        continuation.yield(.pose(.identity))
    }

    private func observe(
        _ provider: any HeadPoseProvider,
        isPrimary: Bool
    ) -> Task<Void, Never> {
        Task { [weak self, provider] in
            for await event in provider.eventStream() {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .availability(let value):
                    if isPrimary {
                        primaryAvailability = value
                    } else {
                        fallbackAvailability = value
                    }
                    updateSelection()

                case .pose(let pose):
                    let usePrimary = primaryAvailability == .available
                    if (isPrimary && usePrimary)
                        || (!isPrimary
                            && !usePrimary
                            && fallbackAvailability == .available) {
                        continuation.yield(.pose(pose))
                    }
                }
            }
        }
    }

    private func updateSelection() {
        if primaryAvailability == .available {
            displayName = primary.displayName
            availability = .available
        } else if fallbackAvailability == .available {
            displayName = fallback.displayName
            availability = .available
        } else {
            displayName = "XREAL/AirPods"
            availability = primaryAvailability
            continuation.yield(.pose(.identity))
        }
        continuation.yield(.availability(availability))
    }
}

private struct XREALPrivateByteCursor {
    let data: Data
    var offset: Int

    mutating func byte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func int16LE() -> Int16? {
        guard let a = byte(), let b = byte() else { return nil }
        return Int16(bitPattern: UInt16(a) | UInt16(b) << 8)
    }

    mutating func int16BE() -> Int16? {
        guard let a = byte(), let b = byte() else { return nil }
        return Int16(bitPattern: UInt16(a) << 8 | UInt16(b))
    }

    mutating func int32LE() -> Int32? {
        guard let a = byte(),
              let b = byte(),
              let c = byte(),
              let d = byte() else {
            return nil
        }
        return Int32(
            bitPattern: UInt32(a)
                | UInt32(b) << 8
                | UInt32(c) << 16
                | UInt32(d) << 24
        )
    }

    mutating func int32BE() -> Int32? {
        guard let a = byte(),
              let b = byte(),
              let c = byte(),
              let d = byte() else {
            return nil
        }
        return Int32(
            bitPattern: UInt32(a) << 24
                | UInt32(b) << 16
                | UInt32(c) << 8
                | UInt32(d)
        )
    }

    mutating func uint64LE() -> UInt64? {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            guard let value = byte() else { return nil }
            result |= UInt64(value) << UInt64(shift)
        }
        return result
    }

    mutating func int24LE() -> Int32? {
        guard let a = byte(), let b = byte(), let c = byte() else { return nil }
        var raw = UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16
        if c & 0x80 != 0 {
            raw |= 0xff00_0000
        }
        return Int32(bitPattern: raw)
    }

    mutating func int15LE() -> Int32? {
        guard let a = byte(), let b = byte() else { return nil }
        return Int32(
            Int16(bitPattern: (UInt16(a) | UInt16(b) << 8) ^ 0x8000)
        )
    }
}
#endif
