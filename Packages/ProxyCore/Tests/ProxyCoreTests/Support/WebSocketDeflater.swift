import Foundation
import CWebSocketZlib

/// Independent fixture: public system deflate API only, never production compression code.
final class WebSocketDeflater {
    struct Failure: Error { let status: Int32 }
    private let stream: UnsafeMutablePointer<z_stream>
    private var initialized = false
    let windowBits: Int
    init(windowBits: Int = 15) throws {
        self.windowBits = windowBits
        stream = .allocate(capacity: 1); stream.initialize(to: z_stream())
        let status = deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -Int32(windowBits),
                                  8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw Failure(status: status)
        }
        initialized = true
    }
    func message(_ input: Data) throws -> Data {
        var output = Data()
        try input.withUnsafeBytes { source in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress?.assumingMemoryBound(to: UInt8.self))
            stream.pointee.avail_in = UInt32(input.count)
            defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
            repeat {
                var chunk = [UInt8](repeating: 0, count: 32768)
                let result = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.next_out = buffer.baseAddress; stream.pointee.avail_out = UInt32(buffer.count)
                    return deflate(stream, Z_SYNC_FLUSH)
                }
                guard result == Z_OK else { throw Failure(status: result) }
                output.append(contentsOf: chunk.prefix(32768 - Int(stream.pointee.avail_out)))
            } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
        }
        guard output.suffix(4) == Data([0,0,255,255]) else { throw Failure(status: Z_DATA_ERROR) }
        output.removeLast(4)
        return output
    }
    deinit { if initialized { deflateEnd(stream) }; stream.deinitialize(count: 1); stream.deallocate() }
}
