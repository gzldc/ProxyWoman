import Foundation

/// Splits a byte stream into newline-delimited lines with a hard per-line size bound.
///
/// Splits on `\n`, strips one trailing `\r`, skips empty lines. A line longer than
/// `maxLineBytes` (measured after stripping the `\r`) yields exactly one `.tooLong` and the
/// remaining bytes up to the next `\n` are discarded, so memory stays bounded.
public struct LineFramer: Sendable {
    public enum Event: Sendable, Equatable {
        case line(Data)
        case tooLong
    }

    private let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    public init(maxLineBytes: Int) {
        self.maxLineBytes = max(0, maxLineBytes)
    }

    public mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        var start = data.startIndex
        // One extra byte of slack so a CRLF-terminated line of exactly `maxLineBytes` is accepted.
        let bufferLimit = maxLineBytes + 1
        while start < data.endIndex {
            if let newline = data[start...].firstIndex(of: 0x0A) {
                let chunk = data[start..<newline]
                start = data.index(after: newline)
                if discarding {
                    discarding = false
                    continue
                }
                if buffer.count + chunk.count > bufferLimit {
                    events.append(.tooLong)
                    buffer.removeAll()
                    continue
                }
                buffer.append(chunk)
                var line = buffer
                buffer.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }
                if line.count > maxLineBytes {
                    events.append(.tooLong)
                } else if !line.isEmpty {
                    events.append(.line(Data(line)))
                }
            } else {
                let chunk = data[start...]
                start = data.endIndex
                if discarding { continue }
                if buffer.count + chunk.count > bufferLimit {
                    events.append(.tooLong)
                    buffer.removeAll()
                    discarding = true
                } else {
                    buffer.append(chunk)
                }
            }
        }
        return events
    }
}
