import Foundation

/// Wire format shared with server/capture-streamd.py. All integers are big-endian.
enum Wire {
    static let version: UInt8 = 1
    static let defaultControlPort: UInt16 = 47100
    static let videoPort: UInt16 = 47101
    static let audioPort: UInt16 = 47102

    /// "CV" ver flags frame_id:u32 index:u16 count:u16 capture_us:u64, then a JPEG slice
    static let videoHeaderSize = 20
    /// "CA" ver flags seq:u32 capture_us:u64, then 5 ms of s16le 48 kHz stereo PCM
    static let audioHeaderSize = 16

    struct VideoPacket {
        let frameID: UInt32
        let index: Int
        let count: Int
        let captureMicros: UInt64
        let payload: UnsafeRawBufferPointer
    }

    struct AudioPacket {
        let sequence: UInt32
        let captureMicros: UInt64
        let samples: UnsafeRawBufferPointer
    }

    static func parseVideo(_ p: UnsafeRawBufferPointer) -> VideoPacket? {
        guard p.count > videoHeaderSize, p[0] == 0x43, p[1] == 0x56 /* "CV" */ else { return nil }
        return VideoPacket(
            frameID: p.loadBE(UInt32.self, at: 4),
            index: Int(p.loadBE(UInt16.self, at: 8)),
            count: Int(p.loadBE(UInt16.self, at: 10)),
            captureMicros: p.loadBE(UInt64.self, at: 12),
            payload: UnsafeRawBufferPointer(rebasing: p[videoHeaderSize...])
        )
    }

    static func parseAudio(_ p: UnsafeRawBufferPointer) -> AudioPacket? {
        guard p.count > audioHeaderSize, p[0] == 0x43, p[1] == 0x41 /* "CA" */ else { return nil }
        return AudioPacket(
            sequence: p.loadBE(UInt32.self, at: 4),
            captureMicros: p.loadBE(UInt64.self, at: 8),
            samples: UnsafeRawBufferPointer(rebasing: p[audioHeaderSize...])
        )
    }
}

extension UnsafeRawBufferPointer {
    func loadBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(bigEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}

/// Wall-clock time in microseconds, comparable with the server's capture stamps once the
/// ping/pong clock offset is applied.
func nowMicros() -> Double {
    Date().timeIntervalSince1970 * 1_000_000
}
