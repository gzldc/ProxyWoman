import Foundation
import Testing

@testable import MCPWire

@Suite struct LineFramerTests {
    private func lines(_ events: [LineFramer.Event]) -> [String] {
        events.compactMap {
            if case .line(let d) = $0 { return String(decoding: d, as: UTF8.self) }
            return nil
        }
    }

    @Test func splitsAcrossChunks() {
        var framer = LineFramer(maxLineBytes: 1024)
        #expect(framer.append(Data("hel".utf8)).isEmpty)
        #expect(framer.append(Data("lo\nwor".utf8)) == [.line(Data("hello".utf8))])
        let rest = framer.append(Data("ld\nthird\n".utf8))
        #expect(rest == [.line(Data("world".utf8)), .line(Data("third".utf8))])
        // A partial line stays buffered until its newline arrives.
        #expect(framer.append(Data("partial".utf8)).isEmpty)
        #expect(framer.append(Data("\n".utf8)) == [.line(Data("partial".utf8))])
    }

    @Test func splitsOneByteAtATime() {
        var framer = LineFramer(maxLineBytes: 64)
        var out: [LineFramer.Event] = []
        for byte in Array("ab\ncd\n".utf8) { out += framer.append(Data([byte])) }
        #expect(lines(out) == ["ab", "cd"])
    }

    @Test func stripsCarriageReturnAndSkipsEmptyLines() {
        var framer = LineFramer(maxLineBytes: 1024)
        let events = framer.append(Data("a\r\n\n\r\n\nb\n\r\n".utf8))
        #expect(events == [.line(Data("a".utf8)), .line(Data("b".utf8))])
        // CR split from its LF across chunks is still stripped.
        #expect(framer.append(Data("c\r".utf8)).isEmpty)
        #expect(framer.append(Data("\n".utf8)) == [.line(Data("c".utf8))])
    }

    @Test func tooLongLineYieldsOneEventThenRecovers() {
        var framer = LineFramer(maxLineBytes: 16)
        let long = String(repeating: "x", count: 40)
        // Whole oversized line plus a good line in one chunk.
        #expect(framer.append(Data("\(long)\nok\n".utf8)) == [.tooLong, .line(Data("ok".utf8))])
        // Oversized line spread across chunks: exactly one event, bytes discarded to the next newline.
        var events = framer.append(Data(long.utf8))
        events += framer.append(Data(long.utf8))
        events += framer.append(Data(long.utf8))
        #expect(events == [.tooLong])
        events = framer.append(Data("still discarded\nnext\n".utf8))
        #expect(events == [.line(Data("next".utf8))])
    }

    @Test func maxLengthLineIsAccepted() {
        var framer = LineFramer(maxLineBytes: 16)
        let exact = String(repeating: "y", count: 16)
        #expect(framer.append(Data("\(exact)\n".utf8)) == [.line(Data(exact.utf8))])
        // A CRLF terminator does not count toward the limit.
        #expect(framer.append(Data("\(exact)\r\n".utf8)) == [.line(Data(exact.utf8))])
        // One byte over is rejected.
        let over = String(repeating: "z", count: 17)
        #expect(framer.append(Data("\(over)\nafter\n".utf8)) == [.tooLong, .line(Data("after".utf8))])
    }

    @Test func memoryStaysBoundedWhileDiscarding() {
        var framer = LineFramer(maxLineBytes: 8)
        var tooLongCount = 0
        for _ in 0..<1000 {
            for case .tooLong in framer.append(Data(repeating: 0x41, count: 4096)) { tooLongCount += 1 }
        }
        #expect(tooLongCount == 1)
        #expect(framer.append(Data("\nok\n".utf8)) == [.line(Data("ok".utf8))])
    }
}
