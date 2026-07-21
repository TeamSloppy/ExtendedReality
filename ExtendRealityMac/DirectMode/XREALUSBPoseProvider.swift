@preconcurrency import CoreMotion
import Foundation
@preconcurrency import IOKit.hid
import simd

// Packet layout adapted from Monado's BSL-1.0 XREAL Air driver. The implementation
// is intentionally isolated and remains Experimental until the hardware gate passes.
enum XREALAirPacketCodec {
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
        var cursor = ByteCursor(data: data, offset: 2)
        guard let temperature = cursor.int16LE(),
              let timestamp = cursor.uint64LE(),
              let gyroMultiplier = cursor.int16LE(),
              let gyroDivisor = cursor.int32LE(),
              let gx = cursor.int24LE(), let gy = cursor.int24LE(), let gz = cursor.int24LE(),
              let accelMultiplier = cursor.int16LE(),
              let accelDivisor = cursor.int32LE(),
              let ax = cursor.int24LE(), let ay = cursor.int24LE(), let az = cursor.int24LE(),
              let magMultiplier = cursor.int16BE(),
              let magDivisor = cursor.int32BE(),
              let mx = cursor.int15LE(), let my = cursor.int15LE(), let mz = cursor.int15LE(),
              gyroDivisor != 0, accelDivisor != 0, magDivisor != 0 else { return nil }

        let gyroScale = Double(gyroMultiplier) / Double(gyroDivisor)
        let accelScale = Double(accelMultiplier) / Double(accelDivisor)
        let magScale = Double(magMultiplier) / Double(magDivisor)
        return Sample(
            temperature: temperature,
            timestamp: timestamp,
            gyro: Vector(x: Double(gx) * gyroScale, y: Double(gy) * gyroScale, z: Double(gz) * gyroScale),
            acceleration: Vector(x: Double(ax) * accelScale, y: Double(ay) * accelScale, z: Double(az) * accelScale),
            magnetometer: Vector(x: Double(mx) * magScale, y: Double(my) * magScale, z: Double(mz) * magScale)
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
        guard expected == crc32(data.subdata(in: 5..<(5 + packetLength))) else { return nil }
        let payloadEnd = min(data.count, 5 + packetLength)
        return ControlPacket(messageID: data[7], payload: data.subdata(in: 8..<payloadEnd))
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

struct XREALTimestampUnwrapper: Sendable {
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

struct XREALCalibration: Sendable {
    var accelBias = SIMD3<Double>.zero
    var gyroBias = SIMD3<Double>.zero
    var magBias = SIMD3<Double>.zero
    var accelScale = SIMD3<Double>(repeating: 1)
    var gyroScale = SIMD3<Double>(repeating: 1)
    var magScale = SIMD3<Double>(repeating: 1)
    var accelQGyro = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    var gyroQMag = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))

    static func decode(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imu = root["IMU"] as? [String: Any],
              let device = imu["device_1"] as? [String: Any] else { return nil }
        func vector(_ key: String, fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let values = device[key] as? [NSNumber], values.count == 3 else { return fallback }
            return SIMD3(values[0].doubleValue, values[1].doubleValue, values[2].doubleValue)
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
        return XREALCalibration(
            accelBias: vector("accel_bias", fallback: .zero),
            gyroBias: vector("gyro_bias", fallback: .zero),
            magBias: vector("mag_bias", fallback: .zero),
            accelScale: vector("scale_accel", fallback: .one),
            gyroScale: vector("scale_gyro", fallback: .one),
            magScale: vector("scale_mag", fallback: .one),
            accelQGyro: quaternion("accel_q_gyro"),
            gyroQMag: quaternion("gyro_q_mag")
        )
    }
}

private extension SIMD3 where Scalar == Double {
    static var one: Self { SIMD3(repeating: 1) }
}

struct XREALQuaternionFusion: Sendable {
    private(set) var orientation = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
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
        let dt = min(max(Double(timestamp &- lastTimestamp) / 1_000_000_000, 0), 0.05)
        self.lastTimestamp = timestamp
        guard dt > 0 else { return orientation }

        var omega = gyroRadiansPerSecond
        let accelerationLength = simd_length(acceleration)
        if accelerationLength > 0.35, accelerationLength < 2.5 {
            let measuredGravity = simd_normalize(acceleration)
            let expectedGravity = orientation.inverse.act(SIMD3<Double>(0, -1, 0))
            omega += simd_cross(measuredGravity, expectedGravity) * 1.8
        }
        let speed = simd_length(omega)
        if speed > 0 {
            orientation = simd_normalize(orientation * simd_quatd(angle: speed * dt, axis: omega / speed))
        }
        return orientation
    }

    mutating func reset() {
        orientation = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
        lastTimestamp = nil
    }
}

@MainActor
final class XREALUSBPoseProvider: HeadPoseProvider {
    let displayName = "XREAL Air USB"
    private(set) var availability: HeadPoseAvailability = .waiting(reason: "Connect XREAL Air over USB")

    private let manager: IOHIDManager
    private let events: AsyncStream<HeadPoseEvent>
    private let continuation: AsyncStream<HeadPoseEvent>.Continuation
    private var devices: [UInt: IOHIDDevice] = [:]
    private var reportBuffers: [UInt: UnsafeMutablePointer<UInt8>] = [:]
    private var calibrationBuffer = Data()
    private var expectedCalibrationLength = 0
    private var calibration: XREALCalibration?
    private var unwrapper = XREALTimestampUnwrapper()
    private var fusion = XREALQuaternionFusion()
    private var referenceQuaternion: simd_quatd?
    private var smoother = HeadPoseSmoother(responseTime: 0.018)
    private var lastPublishTime: TimeInterval = 0
    private var started = false

    init() {
        let channel = AsyncStream<HeadPoseEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
        events = channel.stream
        continuation = channel.continuation
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: XREALAirPacketCodec.vendorID,
            kIOHIDProductIDKey as String: XREALAirPacketCodec.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        continuation.yield(.availability(availability))
    }

    func start() {
        guard !started else { return }
        started = true
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            updateAvailability(.unavailable(reason: "Unable to open the XREAL USB HID interface"))
        }
    }

    func eventStream() -> AsyncStream<HeadPoseEvent> { events }

    func recenter() {
        referenceQuaternion = fusion.orientation
        smoother.reset()
        continuation.yield(.pose(.identity))
    }

    private func attach(_ device: IOHIDDevice) {
        let key = Self.key(for: device)
        guard devices[key] == nil else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        devices[key] = device
        let maximum = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 64
        let length = max(maximum, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        reportBuffers[key] = buffer
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            length,
            Self.inputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        updateAvailability(.waiting(reason: "Reading XREAL calibration…"))
        send(messageID: 0x19, payload: Data([0xAA]))
        send(messageID: 0x14)
    }

    private func detach(_ device: IOHIDDevice) {
        let key = Self.key(for: device)
        devices.removeValue(forKey: key)
        if let buffer = reportBuffers.removeValue(forKey: key) { buffer.deallocate() }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if devices.isEmpty {
            calibration = nil
            expectedCalibrationLength = 0
            calibrationBuffer.removeAll()
            unwrapper.reset()
            fusion.reset()
            referenceQuaternion = nil
            updateAvailability(.waiting(reason: "XREAL disconnected — head-locked fallback"))
        }
    }

    private func consume(_ data: Data) {
        if let control = XREALAirPacketCodec.parseControl(data) {
            consume(control)
            return
        }
        guard let sample = XREALAirPacketCodec.parseSensor(data) else { return }
        guard let calibration else {
            send(messageID: 0x19, payload: Data([0xAA]))
            return
        }

        let tick = unwrapper.consume(sample.timestamp)
        let timestamp = tick
        let gyro = Self.calibratedGyro(sample.gyro.simd, calibration: calibration)
        let accel = Self.calibratedAcceleration(sample.acceleration.simd, calibration: calibration)
        let quaternion = fusion.update(
            timestamp: timestamp,
            gyroRadiansPerSecond: gyro,
            acceleration: accel
        )
        if referenceQuaternion == nil { referenceQuaternion = quaternion }
        guard let referenceQuaternion else { return }
        let relative = simd_normalize(referenceQuaternion.inverse * quaternion)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishTime >= 1.0 / 120.0 else { return }
        lastPublishTime = now
        let angles = Self.eulerDegrees(relative)
        let pose = smoother.filter(HeadPose(
            yaw: angles.yaw,
            pitch: angles.pitch,
            roll: angles.roll,
            timestamp: now
        ))
        continuation.yield(.pose(pose))
        updateAvailability(.available)
    }

    private func consume(_ packet: XREALAirPacketCodec.ControlPacket) {
        switch packet.messageID {
        case 0x14:
            guard packet.payload.count >= 4 else { return }
            expectedCalibrationLength = Int(UInt32(packet.payload[0])
                | UInt32(packet.payload[1]) << 8
                | UInt32(packet.payload[2]) << 16
                | UInt32(packet.payload[3]) << 24)
            calibrationBuffer.removeAll(keepingCapacity: true)
            if expectedCalibrationLength > 0 { send(messageID: 0x15) }
        case 0x15:
            guard expectedCalibrationLength > 0 else { send(messageID: 0x14); return }
            let remaining = expectedCalibrationLength - calibrationBuffer.count
            calibrationBuffer.append(packet.payload.prefix(max(remaining, 0)))
            if calibrationBuffer.count >= expectedCalibrationLength {
                calibration = XREALCalibration.decode(calibrationBuffer)
                if calibration == nil {
                    updateAvailability(.unavailable(reason: "XREAL factory calibration is invalid"))
                } else {
                    send(messageID: 0x19, payload: Data([0x01]))
                    updateAvailability(.waiting(reason: "Starting XREAL IMU…"))
                }
            } else {
                send(messageID: 0x15)
            }
        default:
            break
        }
    }

    private func send(messageID: UInt8, payload: Data = Data()) {
        let packet = XREALAirPacketCodec.command(messageID: messageID, data: payload)
        for device in devices.values {
            let result = packet.withUnsafeBytes { bytes in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    0,
                    bytes.bindMemory(to: UInt8.self).baseAddress!,
                    packet.count
                )
            }
            if result == kIOReturnSuccess { return }
        }
    }

    private func updateAvailability(_ value: HeadPoseAvailability) {
        guard value != availability else { return }
        availability = value
        continuation.yield(.availability(value))
    }

    private static func calibratedGyro(
        _ value: SIMD3<Double>,
        calibration: XREALCalibration
    ) -> SIMD3<Double> {
        var aligned = calibration.accelQGyro.act(value) * (.pi / 180)
        aligned = preCalibrationCoordinates(aligned)
        aligned = (aligned - calibration.gyroBias) * calibration.gyroScale
        return postCalibrationCoordinates(aligned)
    }

    private static func calibratedAcceleration(
        _ value: SIMD3<Double>,
        calibration: XREALCalibration
    ) -> SIMD3<Double> {
        var aligned = value * 9.80665
        aligned = preCalibrationCoordinates(aligned)
        aligned = (aligned - calibration.accelBias) * calibration.accelScale
        return postCalibrationCoordinates(aligned)
    }

    private static func preCalibrationCoordinates(_ value: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-value.x, -value.z, -value.y)
    }

    private static func postCalibrationCoordinates(_ value: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(value.x, -value.y, -value.z)
    }

    private static func eulerDegrees(_ quaternion: simd_quatd) -> (yaw: Double, pitch: Double, roll: Double) {
        let q = quaternion.vector
        let x = q.x, y = q.y, z = q.z, w = q.w
        let yaw = atan2(2 * (w * y + x * z), 1 - 2 * (y * y + x * x))
        let pitch = asin((2 * (w * x - z * y)).clamped(to: -1 ... 1))
        let roll = atan2(2 * (w * z + x * y), 1 - 2 * (z * z + x * x))
        let scale = 180 / Double.pi
        return (-yaw * scale, pitch * scale, -roll * scale)
    }

    private static func key(for device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<XREALUSBPoseProvider>.fromOpaque(context).takeUnretainedValue().attach(device)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<XREALUSBPoseProvider>.fromOpaque(context).takeUnretainedValue().detach(device)
    }

    private static let inputReport: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard result == kIOReturnSuccess, let context, length > 0 else { return }
        let data = Data(bytes: report, count: length)
        Unmanaged<XREALUSBPoseProvider>.fromOpaque(context).takeUnretainedValue().consume(data)
    }
}

private struct ByteCursor {
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
        guard let a = byte(), let b = byte(), let c = byte(), let d = byte() else { return nil }
        return Int32(bitPattern: UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24)
    }

    mutating func int32BE() -> Int32? {
        guard let a = byte(), let b = byte(), let c = byte(), let d = byte() else { return nil }
        return Int32(bitPattern: UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
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
        if c & 0x80 != 0 { raw |= 0xff00_0000 }
        return Int32(bitPattern: raw)
    }

    mutating func int15LE() -> Int32? {
        guard let a = byte(), let b = byte() else { return nil }
        return Int32(Int16(bitPattern: (UInt16(a) | UInt16(b) << 8) ^ 0x8000))
    }
}
