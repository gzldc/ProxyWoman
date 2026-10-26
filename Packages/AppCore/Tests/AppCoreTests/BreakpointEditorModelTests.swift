import Compression
import FlowStore
import Foundation
import RulesEngine
import Testing
@testable import AppCore

@MainActor @Suite(.productionChinese, .timeLimit(.minutes(1))) struct BreakpointEditorModelTests {
    @Test func invalidContinueKeepsDraftAndFieldError() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)

        // A local validation failure never reaches the proxy and marks the field.
        editor.headers.append(HeaderFieldRow(name: "Bad Name", value: "x"))
        let bad = editor.headers[1].id
        await model.continueSelected()
        #expect(client.commands.isEmpty)
        #expect(editor.fieldErrors[.header(bad)] == .invalidHeader)
        #expect(model.selectedEditor === editor && editor.headers.count == 2)

        // A protected field keeps its original value.
        editor.headers[1] = HeaderFieldRow(id: bad, name: "Host", value: "elsewhere.test")
        await model.continueSelected()
        #expect(client.commands.isEmpty)
        #expect(editor.fieldErrors[.header(bad)] == .protectedHeader)

        editor.url = "not a url"
        editor.headers.remove(at: 1)
        await model.continueSelected()
        #expect(editor.fieldErrors[.url] == .invalidURL)
        #expect(client.commands.isEmpty)

        // The proxy rejecting a locally valid edit keeps the ticket, the draft and a message.
        editor.url = "http://origin.test:8080/next?id=2"
        editor.headers[0].value = "application/json"
        client.enqueue(.invalid)
        await model.continueSelected()
        #expect(client.commands.count == 1)
        #expect(editor.fieldErrors == [.message: .rejected])
        #expect(model.selectedEditor === editor)
        #expect(editor.url == "http://origin.test:8080/next?id=2" && editor.headers[0].value == "application/json")
        #expect(model.notice == nil)
    }

    @Test func validRequestEditBecomesOneContinueCommand() async throws {
        let a = requestTicket(headers: [HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "X-Dup", value: "1"),
                                        HeaderField(name: "X-Dup", value: "2")])
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        #expect(editor.method == "POST" && editor.url == "http://origin.test:8080/items?id=1")
        editor.method = "PUT"
        editor.url = "http://origin.test/b?x=1&x=1"
        editor.headers[2].value = "3"
        await model.continueSelected()
        let target = HTTPMessageTarget(scheme: "http", host: "origin.test", port: 80, method: "PUT", pathAndQuery: "/b?x=1&x=1")
        let head = HTTPMessageHead.request(target, headers: [
            HeaderField(name: "Accept", value: "*/*"), HeaderField(name: "X-Dup", value: "1"), HeaderField(name: "X-Dup", value: "3"),
        ])
        #expect(client.commands == [.continue(a.token, BreakpointClientEdit(head: head, body: .unchanged, encodingChoice: .unchanged))])
        #expect(model.selectedEditor == nil && model.selectedID == nil)
        #expect(model.notice == nil)
    }

    @Test func expiredContinueClosesEditorWithNotice() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        client.enqueue(.expired)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        model.selectedEditor?.headers[0].value = "edited"
        await model.continueSelected()
        #expect(model.selectedEditor == nil && model.selectedID == nil)
        #expect(model.notice == .expired)
        #expect(model.budget.reservedBytes == 0)
    }

    @Test func mapLocalRequestKeepsItsTarget() async throws {
        let a = requestTicket(local: true)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        #expect(!editor.canEditTarget)
        editor.url = "http://elsewhere.test/"
        await model.continueSelected()
        guard case .continue(_, let edit) = try #require(client.commands.first), case .request(let target, _) = edit.head else {
            Issue.record("expected a request continue"); return
        }
        #expect(target.host == "origin.test" && target.method == "POST")
    }

    @Test func responseStatusEditAndInvalidStatus() async throws {
        let a = responseTicket(phase: .pausedHeaders)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        #expect(editor.status == "200" && editor.reason == "OK")
        editor.status = "abc"
        await model.continueSelected()
        #expect(editor.fieldErrors[.status] == .invalidStatus)
        editor.status = "503"
        editor.reason = "Busy"
        await model.continueSelected()
        let head = HTTPMessageHead.response(status: 503, reason: "Busy", headers: a.effectiveHead.headers)
        #expect(client.commands == [.continue(a.token, BreakpointClientEdit(head: head, body: .unchanged, encodingChoice: .unchanged))])
    }

    @Test func textBodyEditSendsReplacement() async throws {
        let a = responseTicket(bodyLength: 5)
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(Data("hello".utf8), for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .text)
        #expect(editor.bodyText == "hello" && editor.canEditBody)
        #expect(model.budget.reservedBytes == 5)
        editor.bodyText = "hello, world"
        await model.continueSelected()
        let edit = BreakpointClientEdit(head: a.effectiveHead, body: .replace(Data("hello, world".utf8)), encodingChoice: .unchanged)
        #expect(client.commands == [.continue(a.token, edit)])
        #expect(model.budget.reservedBytes == 0)
    }

    @Test func decodedGzipEditRemovesEncodingAndRawViewIsHex() async throws {
        let plain = Data("compressed text".utf8)
        let gzip = try gzipped(plain)
        let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let a = responseTicket(headers: headers, bodyLength: Int64(gzip.count))
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(gzip, for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.boundary == .decoded && editor.isEncoded)
        #expect(editor.body == .text && editor.bodyText == "compressed text")
        #expect(model.budget.reservedBytes == gzip.count + plain.count)
        editor.boundary = .raw
        #expect(editor.displayedBody == .hex(gzip, truncated: false) && !editor.canEditBody)
        editor.boundary = .decoded
        editor.bodyText = "plain now"
        await model.continueSelected()
        let edit = BreakpointClientEdit(head: a.effectiveHead, body: .replace(Data("plain now".utf8)), encodingChoice: .removeEncoding)
        #expect(client.commands == [.continue(a.token, edit)])
    }

    // Phase fix m2: Continue sends what the visible view shows.
    @Test func rawViewNeverContinuesWithAHiddenDecodedEdit() async throws {
        let plain = Data("compressed text".utf8)
        let gzip = try gzipped(plain)
        let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let a = responseTicket(headers: headers, bodyLength: Int64(gzip.count))
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(gzip, for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        editor.bodyText = "plain now"
        #expect(!editor.hasHiddenDecodedEdit)
        editor.boundary = .raw
        #expect(editor.hasHiddenDecodedEdit)
        #expect(editor.displayedBody == .hex(gzip, truncated: false))
        await model.continueSelected()
        #expect(client.commands.isEmpty)
        #expect(editor.fieldErrors[.body] == .decodedEditNotShown)
        #expect(model.selectedEditor === editor && editor.bodyText == "plain now")

        // Reverting the hidden edit makes the raw view the truth: the raw bytes continue unchanged.
        editor.revert()
        #expect(!editor.hasHiddenDecodedEdit)
        await model.continueSelected()
        #expect(client.commands == [.continue(a.token, BreakpointClientEdit(head: a.effectiveHead, body: .unchanged, encodingChoice: .unchanged))])
    }

    // MARK: Phase fix I2c — replace a body from a file

    @Test func largeBodyIsReplacedFromAFileImportedInsideItsScope() async throws {
        let size = 9 * mebibyte
        let a = responseTicket(bodyLength: Int64(size))
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(Data(repeating: UInt8(ascii: "a"), count: size), for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .readOnlyText(truncated: true) && editor.canReplaceBodyFromFile)
        let file = URL(fileURLWithPath: "/private/tmp/replacement.json")
        client.setImportedSize(12 * Int64(mebibyte), for: file)
        await editor.replaceBody(from: file, access: client.scopedAccess)
        // The security scope encloses the whole awaited import; the UI never reads the file itself.
        #expect(client.events == ["scopeStart", "import", "scopeStop"])
        #expect(client.imports == [file])
        let imported = try #require(editor.replacementFile)
        #expect(imported.size == 12 * Int64(mebibyte) && imported.fileName == "replacement.json")
        #expect(editor.isDirty && !editor.canEditBody && editor.fieldErrors.isEmpty)
        await model.continueSelected()
        #expect(client.commands == [.continue(a.token, BreakpointClientEdit(head: a.effectiveHead, body: .file(imported), encodingChoice: .unchanged))])
    }

    @Test func fileReplacementOfAnEncodedBodyIsSentPlainAndRevertDropsIt() async throws {
        let gzip = try gzipped(Data("compressed text".utf8))
        let headers = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let a = responseTicket(headers: headers, bodyLength: Int64(gzip.count))
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(gzip, for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        let file = URL(fileURLWithPath: "/private/tmp/plain.txt")
        client.setImportedSize(4, for: file)
        await editor.replaceBody(from: file, access: client.scopedAccess)
        #expect(editor.replacementFile != nil)
        editor.revert()
        #expect(editor.replacementFile == nil && !editor.isDirty)
        await editor.replaceBody(from: file, access: client.scopedAccess)
        let imported = try #require(editor.replacementFile)
        await model.continueSelected()
        #expect(client.commands == [.continue(a.token, BreakpointClientEdit(head: a.effectiveHead, body: .file(imported), encodingChoice: .removeEncoding))])
    }

    @Test func failedFileImportKeepsTheBodyAndSaysWhy() async throws {
        let a = responseTicket(bodyLength: 5)
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(Data("hello".utf8), for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        await editor.replaceBody(from: URL(fileURLWithPath: "/private/tmp/missing"), access: client.scopedAccess)
        #expect(client.events == ["scopeStart", "import", "scopeStop"])
        #expect(editor.replacementFile == nil && editor.fieldErrors[.body] == .replacementFileUnavailable)
        #expect(!editor.isDirty)
    }

    @Test func fileReplacementNeedsACollectedBodyAndANetworkRoute() async throws {
        let headersOnly = requestTicket(phase: .pausedHeaders)
        let local = requestTicket(phase: .pausedBody, bodyLength: 2, local: true)
        let client = FakeBreakpointClient(tickets: [headersOnly, local])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        for ticket in [headersOnly, local] {
            model.select(ticket.id)
            let editor = try #require(model.selectedEditor)
            #expect(!editor.canReplaceBodyFromFile)
            await editor.replaceBody(from: URL(fileURLWithPath: "/private/tmp/x"), access: client.scopedAccess)
            #expect(editor.replacementFile == nil)
        }
        #expect(client.imports.isEmpty)
    }

    @Test func bodyOver8MiBIsReadOnlyPreview() async throws {
        let size = 9 * mebibyte
        let a = responseTicket(bodyLength: Int64(size))
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(Data(repeating: UInt8(ascii: "a"), count: size), for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .readOnlyText(truncated: true))
        #expect(editor.bodyText.utf8.count == 8 * mebibyte)
        #expect(!editor.canEditBody)
        #expect(model.budget.reservedBytes == 8 * mebibyte)
        editor.bodyText = "ignored"
        await model.continueSelected()
        guard case .continue(_, let edit) = try #require(client.commands.first) else { Issue.record("expected continue"); return }
        #expect(edit.body == .unchanged)
    }

    @Test func totalEditorBudget32MiBEnforced() async throws {
        let budget = HTTPEditorMemoryBudget(limits: RulesLimits())
        #expect(budget.totalBytes == 32 * mebibyte && budget.perEditorBytes == 8 * mebibyte)
        let tickets = (0..<5).map { responseTicket(flowID: $0, bodyLength: Int64(8 * mebibyte)) }
        let client = FakeBreakpointClient(tickets: tickets)
        for ticket in tickets { client.setBody(Data(repeating: UInt8(ascii: "b"), count: 8 * mebibyte), for: ticket.id) }
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        var editors: [BreakpointEditorModel] = []
        for ticket in tickets {
            model.select(ticket.id)
            let editor = try #require(model.selectedEditor)
            await editor.loadBodyIfNeeded()
            editors.append(editor)
        }
        #expect(editors.prefix(4).allSatisfy { $0.body == .text })
        #expect(editors[4].body == .budgetExhausted && !editors[4].canEditBody)
        #expect(model.budget.reservedBytes == 32 * mebibyte)

        // Ending one ticket gives its memory back.
        client.publish(Array(tickets.dropFirst()))
        await model.refresh()
        #expect(model.budget.reservedBytes == 24 * mebibyte)
    }

    @Test func refusedBodyLoadsAgainOnceMemoryIsFree() async throws {
        let tickets = (0..<5).map { responseTicket(flowID: $0, bodyLength: Int64(8 * mebibyte)) }
        let client = FakeBreakpointClient(tickets: tickets)
        for ticket in tickets { client.setBody(Data(repeating: UInt8(ascii: "c"), count: 8 * mebibyte), for: ticket.id) }
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        for ticket in tickets {
            model.select(ticket.id)
            await model.selectedEditor?.loadBodyIfNeeded()
        }
        let refused = try #require(model.editor(for: tickets[4].id))
        #expect(refused.body == .budgetExhausted)

        // Selecting it again while memory is still used up retries and refuses again.
        model.select(tickets[3].id)
        model.select(tickets[4].id)
        await refused.loadBodyIfNeeded()
        #expect(refused.body == .budgetExhausted)

        // Once another breakpoint is handled, selecting it again loads the body.
        client.publish(Array(tickets.dropFirst()))
        await model.refresh()
        model.select(tickets[1].id)
        model.select(tickets[4].id)
        await refused.loadBodyIfNeeded()
        #expect(refused.body == .text && refused.canEditBody)
        #expect(model.budget.reservedBytes == 32 * mebibyte)
    }

    @Test func failedBodyLoadRetriesWhenSelectedAgain() async throws {
        let a = responseTicket(bodyLength: 4), b = responseTicket(flowID: 2, bodyLength: 2)
        let client = FakeBreakpointClient(tickets: [a, b])
        client.setBody(Data("ok".utf8), for: b.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .loadFailed)
        #expect(model.budget.reservedBytes == 0)

        client.setBody(Data("abcd".utf8), for: a.id)
        model.select(b.id)
        model.select(a.id)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .text && editor.bodyText == "abcd")
    }

    @Test func declaredNonUTF8CharsetIsReadOnlyEvenWhenBytesLookLikeUTF8() async throws {
        let gbk = responseTicket(headers: [HeaderField(name: "Content-Type", value: "text/plain; charset=GBK")], bodyLength: 5)
        let latin = responseTicket(
            flowID: 2, headers: [HeaderField(name: "content-type", value: "text/html; charset=\"ISO-8859-1\"")], bodyLength: 5)
        let client = FakeBreakpointClient(tickets: [gbk, latin])
        client.setBody(Data("hello".utf8), for: gbk.id)
        client.setBody(Data("hello".utf8), for: latin.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        for ticket in [latin, gbk] {
            model.select(ticket.id)
            let editor = try #require(model.selectedEditor)
            await editor.loadBodyIfNeeded()
            #expect(editor.body == .hex(Data("hello".utf8), truncated: false))
            #expect(!editor.canEditBody)
        }
        // Even text typed into the draft is never sent as UTF-8 under another charset label.
        model.selectedEditor?.bodyText = "你好"
        await model.continueSelected()
        guard case .continue(_, let edit) = try #require(client.commands.first) else { Issue.record("expected continue"); return }
        #expect(edit.body == .unchanged)
    }

    @Test func utf8CharsetBodyAcceptsNonLatinEdits() async throws {
        let a = responseTicket(headers: [HeaderField(name: "Content-Type", value: "text/plain; charset=UTF-8")], bodyLength: 6)
        let client = FakeBreakpointClient(tickets: [a])
        client.setBody(Data("héllo".utf8), for: a.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .text && editor.bodyText == "héllo")
        editor.bodyText = "你好，世界"
        await model.continueSelected()
        let edit = BreakpointClientEdit(head: a.effectiveHead, body: .replace(Data("你好，世界".utf8)), encodingChoice: .unchanged)
        #expect(client.commands == [.continue(a.token, edit)])
    }

    @Test func encodedBodyIsDecodedWithinTheEditorLimitAndChargedFirst() async throws {
        // Per editor 32 KiB, all editors 48 KiB.
        let limits = RulesLimits(editorBodyBytes: 32_768, editorMemoryBytes: 49_152)
        let bomb = try gzipped(Data(repeating: UInt8(ascii: "a"), count: mebibyte))
        let fits = try gzipped(Data(repeating: UInt8(ascii: "b"), count: 24_000))
        let encoded = [HeaderField(name: "Content-Type", value: "text/plain"), HeaderField(name: "Content-Encoding", value: "gzip")]
        let a = responseTicket(headers: encoded, bodyLength: Int64(bomb.count))
        let b = responseTicket(flowID: 2, headers: encoded, bodyLength: Int64(fits.count))
        let c = responseTicket(flowID: 3, headers: encoded, bodyLength: Int64(fits.count))
        let client = FakeBreakpointClient(tickets: [a, b, c])
        client.setBody(bomb, for: a.id)
        client.setBody(fits, for: b.id)
        client.setBody(fits, for: c.id)
        let model = BreakpointQueueModel(client: client, limits: limits)
        await model.refresh()

        // A body that inflates past the editor limit stays raw hex. The decoded copy was charged
        // (up to the editor limit) before decoding, and the decoder was bounded by that charge.
        model.select(a.id)
        let bombEditor = try #require(model.selectedEditor)
        await bombEditor.loadBodyIfNeeded()
        #expect(bombEditor.body == .hex(bomb, truncated: false) && !bombEditor.canEditBody)
        #expect(model.budget.reservedBytes == bomb.count)
        #expect(model.budget.peakReservedBytes == bomb.count + 32_768)

        model.select(b.id)
        let first = try #require(model.selectedEditor)
        await first.loadBodyIfNeeded()
        #expect(first.body == .text && first.bodyText.utf8.count == 24_000)

        // Not enough memory left for the decoded copy: raw hex, charged only for the raw bytes.
        model.select(c.id)
        let second = try #require(model.selectedEditor)
        await second.loadBodyIfNeeded()
        #expect(second.body == .hex(fits, truncated: false))
        #expect(model.budget.peakReservedBytes == 49_152)
        #expect(model.budget.reservedBytes == bomb.count + fits.count + 24_000 + fits.count)

        // Closing releases each editor's charge once.
        client.publish([])
        await model.refresh()
        #expect(model.budget.reservedBytes == 0)
    }

    @Test func budgetRejectsOversizedAndReleasesOnce() {
        let budget = HTTPEditorMemoryBudget(totalBytes: 10, perEditorBytes: 6)
        let first = budget.reserve(bytes: 6)
        #expect(first != nil)
        #expect(budget.reserve(bytes: 5) == nil)
        let second = budget.reserve(bytes: 4)
        #expect(budget.reservedBytes == 10)
        first?.release()
        first?.release()
        #expect(budget.reservedBytes == 4)
        second?.release()
        #expect(budget.reservedBytes == 0)
    }

    @Test func binaryBodyIsHexReadOnly() async throws {
        let bytes = Data([0x00, 0xff, 0xfe, 0x10, 0x80])
        let a = responseTicket(headers: [HeaderField(name: "Content-Type", value: "application/octet-stream")], bodyLength: 5)
        let corrupt = responseTicket(headers: [HeaderField(name: "Content-Encoding", value: "gzip")], bodyLength: 3)
        let client = FakeBreakpointClient(tickets: [a, corrupt])
        client.setBody(bytes, for: a.id)
        client.setBody(Data("abc".utf8), for: corrupt.id)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()

        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .hex(bytes, truncated: false) && !editor.canEditBody)

        model.select(corrupt.id)
        let undecodable = try #require(model.selectedEditor)
        await undecodable.loadBodyIfNeeded()
        #expect(undecodable.body == .hex(Data("abc".utf8), truncated: false) && !undecodable.canEditBody)

        model.select(a.id)
        await model.continueSelected()
        guard case .continue(_, let edit) = try #require(client.commands.first) else { Issue.record("expected continue"); return }
        #expect(edit.body == .unchanged && edit.encodingChoice == .unchanged)
    }

    @Test func headersOnlyPauseDoesNotLoadABody() async throws {
        let a = requestTicket(phase: .pausedHeaders)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        await editor.loadBodyIfNeeded()
        #expect(editor.body == .streaming)
        #expect(client.bodyLoads == 0)
        #expect(model.budget.reservedBytes == 0)
    }

    @Test func remainingSecondsComputedFromDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(BreakpointCountdown.remainingSeconds(until: now.addingTimeInterval(120), now: now) == 120)
        #expect(BreakpointCountdown.remainingSeconds(until: now.addingTimeInterval(10.2), now: now) == 11)
        #expect(BreakpointCountdown.remainingSeconds(until: now.addingTimeInterval(10), now: now) == 10)
        #expect(BreakpointCountdown.remainingSeconds(until: now.addingTimeInterval(0.01), now: now) == 1)
        #expect(BreakpointCountdown.remainingSeconds(until: now, now: now) == 0)
        #expect(BreakpointCountdown.remainingSeconds(until: now.addingTimeInterval(-5), now: now) == 0)
        #expect(!BreakpointCountdown.isWarning(remainingSeconds: 11))
        #expect(BreakpointCountdown.isWarning(remainingSeconds: 10))
        #expect(BreakpointCountdown.isWarning(remainingSeconds: 0))
    }
}

/// A gzip member (RFC 1952) around a raw deflate stream from the Compression framework.
private func gzipped(_ data: Data) throws -> Data {
    let capacity = data.count + 1024
    var output = [UInt8](repeating: 0, count: capacity)
    let written = data.withUnsafeBytes { input in
        compression_encode_buffer(&output, capacity, input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
    }
    guard written > 0 else { throw CocoaError(.coderInvalidValue) }
    var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
    result.append(contentsOf: output.prefix(written))
    var crc = crc32(data), size = UInt32(truncatingIfNeeded: data.count)
    withUnsafeBytes(of: &crc) { result.append(contentsOf: $0) }
    withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
    return result
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
}
