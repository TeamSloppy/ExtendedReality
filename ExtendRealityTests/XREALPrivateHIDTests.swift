#if DEBUG
import Foundation
import XCTest
@testable import ExtendReality

final class XREALPrivateHIDTests: XCTestCase {
    func testControlPacketRoundTripsAndValidatesCRC() throws {
        let encoded = XREALPrivateHIDPacketCodec.command(
            messageID: 0x19,
            data: Data([0x01])
        )
        let decoded = try XCTUnwrap(
            XREALPrivateHIDPacketCodec.parseControl(encoded)
        )

        XCTAssertEqual(decoded.messageID, 0x19)
        XCTAssertEqual(decoded.payload, Data([0x01]))

        var corrupted = encoded
        corrupted[4] ^= 0xff
        XCTAssertNil(XREALPrivateHIDPacketCodec.parseControl(corrupted))
    }

    func testSensorPacketParsesSignedAxesAndScaleFactors() throws {
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

        let sample = try XCTUnwrap(
            XREALPrivateHIDPacketCodec.parseSensor(packet)
        )
        XCTAssertEqual(sample.temperature, 132)
        XCTAssertEqual(sample.timestamp, 0x00ff_fffe)
        XCTAssertEqual(sample.gyro, .init(x: 100, y: -50, z: 25))
        XCTAssertEqual(sample.acceleration, .init(x: 1, y: 2, z: 3))
        XCTAssertEqual(sample.magnetometer, .init(x: 0, y: 1, z: -1))
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
        for index in 0..<4 {
            data[offset + index] = UInt8(
                (raw >> UInt32(index * 8)) & 0xff
            )
        }
    }

    private func writeInt32BE(_ value: Int32, at offset: Int, to data: inout Data) {
        let raw = UInt32(bitPattern: value)
        for index in 0..<4 {
            data[offset + index] = UInt8(
                (raw >> UInt32((3 - index) * 8)) & 0xff
            )
        }
    }

    private func writeUInt64(_ value: UInt64, at offset: Int, to data: inout Data) {
        for index in 0..<8 {
            data[offset + index] = UInt8(
                (value >> UInt64(index * 8)) & 0xff
            )
        }
    }

    private func writeInt24(_ value: Int32, at offset: Int, to data: inout Data) {
        let raw = UInt32(bitPattern: value)
        data[offset] = UInt8(raw & 0xff)
        data[offset + 1] = UInt8((raw >> 8) & 0xff)
        data[offset + 2] = UInt8((raw >> 16) & 0xff)
    }

    private func writeInt15(_ value: Int16, at offset: Int, to data: inout Data) {
        let raw = UInt16(bitPattern: value) ^ 0x8000
        data[offset] = UInt8(raw & 0xff)
        data[offset + 1] = UInt8(raw >> 8)
    }
}
#endif
