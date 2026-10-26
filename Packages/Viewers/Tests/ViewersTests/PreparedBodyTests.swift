import Foundation
import Testing

@testable import Viewers

@Suite(.productionChinese) struct PreparedBodyTests {
    @Test func headerEligibilityIncludesScalarJSONAndRetainsPreparedTree() throws {
        let body = try PreparedBody.prepare(
            data: Data("42".utf8), contentType: "application/json", contentEncoding: nil)
        #expect(body.hasJSONTree)
        #expect(body.content.jsonRoots != nil)
        #expect(body.content.text == "42")
    }

    @Test func incompleteBodyCannotOfferTree() throws {
        let body = try PreparedBody.prepare(
            data: Data("42".utf8), contentType: nil, contentEncoding: nil, isCaptureTruncated: true)
        #expect(!body.hasJSONTree)
    }

    @Test func oversizedJSONSkipsTree() throws {
        let data = Data(("[" + String(repeating: " ", count: BodyContent.jsonLimit) + "]").utf8)
        let body = try PreparedBody.prepare(data: data, contentType: nil, contentEncoding: nil)
        #expect(!body.hasJSONTree)
    }

    @Test func cancelledPreparationDoesNotPublishContent() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreparedBody.prepare(data: Data("42".utf8), contentType: nil, contentEncoding: nil)
        }
        do {
            _ = try await worker.value
            Issue.record("cancelled work must throw")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
