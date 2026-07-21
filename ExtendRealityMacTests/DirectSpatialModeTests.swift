import CoreGraphics
import Foundation
import Testing
@testable import ExtendRealityMac

struct DirectSpatialModeTests {
    @Test
    func runtimePolicyRejectsRemoteStartsInDirectMode() {
        #expect(MacRuntimeConflictPolicy.permitsRemoteStart(in: .sharing))
        #expect(!MacRuntimeConflictPolicy.permitsRemoteStart(in: .direct))
    }

    @Test
    func mainDisplayCanBeAValidExtendedDirectOutput() {
        let output = DirectOutputDisplay(
            id: 42,
            uuid: UUID(),
            name: "Air",
            pixelSize: CGSize(width: 1_920, height: 1_080),
            isMain: true,
            isExtended: true,
            isMirrored: false,
            looksLikeXREAL: true
        )

        #expect(output.isValidDirectOutput)
    }

    @Test
    func mirroredOrNonExtendedDisplayIsNotAValidOutput() {
        for (isExtended, isMirrored) in [(false, false), (true, true)] {
            let output = DirectOutputDisplay(
                id: 42,
                uuid: UUID(),
                name: "Air",
                pixelSize: CGSize(width: 1_920, height: 1_080),
                isMain: false,
                isExtended: isExtended,
                isMirrored: isMirrored,
                looksLikeXREAL: true
            )

            #expect(!output.isValidDirectOutput)
        }
    }

    @Test
    func xrealControlPacketValidatesCRCAndPayload() throws {
        let encoded = XREALAirPacketCodec.command(messageID: 0x19, data: Data([0x01]))
        let decoded = try #require(XREALAirPacketCodec.parseControl(encoded))

        #expect(decoded.messageID == 0x19)
        #expect(decoded.payload == Data([0x01]))

        var corrupted = encoded
        corrupted[4] ^= 0xff
        #expect(XREALAirPacketCodec.parseControl(corrupted) == nil)
    }

    @Test
    func xrealSensorPacketParsesSignedAxesAndScaleFactors() throws {
        var packet = Data(repeating: 0, count: 64)
        packet[0] = 1
        writeInt16(132, at: 2, to: &packet)
        writeUInt64(0x00ff_fffe, at: 4, to: &packet)
        writeInt16(2, at: 12, to: &packet)
        writeInt32(4, at: 14, to: &packet)
        writeInt24(200, at: 18, to: &packet)
        writeInt24(-100, at: 21, to: &packet)
        writeInt24(50, at: 24, to: &packet)
        writeInt16(1, at: 27, to: &packet)
        writeInt32(10, at: 29, to: &packet)
        writeInt24(10, at: 33, to: &packet)
        writeInt24(20, at: 36, to: &packet)
        writeInt24(30, at: 39, to: &packet)
        writeInt16BE(1, at: 42, to: &packet)
        writeInt32BE(1, at: 44, to: &packet)
        writeInt15(0, at: 48, to: &packet)
        writeInt15(1, at: 50, to: &packet)
        writeInt15(-1, at: 52, to: &packet)

        let sample = try #require(XREALAirPacketCodec.parseSensor(packet))
        #expect(sample.temperature == 132)
        #expect(sample.timestamp == 0x00ff_fffe)
        #expect(sample.gyro == .init(x: 100, y: -50, z: 25))
        #expect(sample.acceleration == .init(x: 1, y: 2, z: 3))
        #expect(sample.magnetometer == .init(x: 0, y: 1, z: -1))
    }

    @Test
    func xrealTimestampUnwraps24BitRollover() {
        var unwrapper = XREALTimestampUnwrapper()
        #expect(unwrapper.consume(0x00ff_fffe) == 0)
        #expect(unwrapper.consume(0x0000_0002) == 4)
        #expect(unwrapper.consume(0x0000_0005) == 7)
    }

    @Test
    func xrealCalibrationReadsFactoryVectors() throws {
        let json = Data(#"{"IMU":{"device_1":{"accel_bias":[1,2,3],"gyro_bias":[4,5,6],"mag_bias":[7,8,9],"scale_accel":[1.1,1.2,1.3],"scale_gyro":[2,2,2],"scale_mag":[3,3,3]}}}"#.utf8)
        let calibration = try #require(XREALCalibration.decode(json))

        #expect(calibration.accelBias.x == 1)
        #expect(calibration.gyroBias.z == 6)
        #expect(calibration.magScale.y == 3)
    }

    @Test
    func sourceMappingHandlesAspectFitAndNegativeDisplayOrigins() throws {
        let surface = CGRect(x: 100, y: 100, width: 400, height: 400)
        let source = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let fitted = SpatialSourceMapping.aspectFitRect(aspectRatio: 16.0 / 9.0, in: surface)
        #expect(fitted == CGRect(x: 100, y: 187.5, width: 400, height: 225))

        let center = try #require(SpatialSourceMapping.globalPoint(
            canvasPoint: CGPoint(x: 300, y: 300),
            surfaceFrame: surface,
            sourceFrame: source,
            sourceAspectRatio: 16.0 / 9.0
        ))
        #expect(center == CGPoint(x: -960, y: 540))
        #expect(SpatialSourceMapping.globalPoint(
            canvasPoint: CGPoint(x: 300, y: 120),
            surfaceFrame: surface,
            sourceFrame: source,
            sourceAspectRatio: 16.0 / 9.0
        ) == nil)
    }

    @Test
    func macCaptureReferencePersistsWithWorkspaceWindow() throws {
        let reference = MacCaptureSourceReference.application(bundleIdentifier: "com.apple.Preview")
        let window = WorkspaceWindow(title: "Preview", source: .macCapture(reference))
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: data)

        #expect(decoded == window)
        #expect(decoded.kind == .remoteDesktop)
    }

    private func writeInt16(_ value: Int16, at offset: Int, to data: inout Data) {
        let raw = UInt16(bitPattern: value)
        data[offset] = UInt8(raw & 0xff)
        data[offset + 1] = UInt8(raw >> 8)
    }

    private func writeInt16BE(_ value: Int16, at offset: Int, to data: inout Data) {
        let raw = UInt16(bitPattern: value)
        data[offset] = UInt8(raw >> 8)
        data[offset + 1] = UInt8(raw & 0xff)
    }

    private func writeInt32(_ value: Int32, at offset: Int, to data: inout Data) {
        let raw = UInt32(bitPattern: value)
        for index in 0..<4 { data[offset + index] = UInt8((raw >> UInt32(index * 8)) & 0xff) }
    }

    private func writeInt32BE(_ value: Int32, at offset: Int, to data: inout Data) {
        let raw = UInt32(bitPattern: value)
        for index in 0..<4 { data[offset + index] = UInt8((raw >> UInt32((3 - index) * 8)) & 0xff) }
    }

    private func writeUInt64(_ value: UInt64, at offset: Int, to data: inout Data) {
        for index in 0..<8 { data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
    }

    private func writeInt24(_ value: Int32, at offset: Int, to data: inout Data) {
        let raw = UInt32(bitPattern: value)
        for index in 0..<3 { data[offset + index] = UInt8((raw >> UInt32(index * 8)) & 0xff) }
    }

    private func writeInt15(_ value: Int16, at offset: Int, to data: inout Data) {
        let raw = UInt16(bitPattern: value) ^ 0x8000
        data[offset] = UInt8(raw & 0xff)
        data[offset + 1] = UInt8(raw >> 8)
    }
}
