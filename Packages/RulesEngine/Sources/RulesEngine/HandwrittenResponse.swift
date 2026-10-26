import FlowStore
import Foundation

/// A whole HTTP response written out by the user: status line, headers, blank line, body. Parsed
/// when the rule is validated and evaluated, so the original text is what is stored.
public struct HandwrittenResponse: Codable, Sendable, Equatable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public enum HandwrittenResponseError: Error, Equatable, Sendable {
    case empty, tooLarge, invalidStatusLine, unsupportedVersion, invalidStatus
    /// `line` counts from 1; the status line is line 1.
    case invalidHeader(line: Int)
    case forbiddenHeader(name: String)
    case bodyNotAllowed
}

public enum HandwrittenResponseWarning: Sendable, Equatable {
    case contentLengthCorrected, contentLengthAdded
}

extension HandwrittenResponse {
    private static let forbiddenNames: [String] = [
        "transfer-encoding", "connection", "keep-alive", "proxy-connection", "te", "trailer", "upgrade",
    ]

    /// Parses the text into the response a rule sends. Works on UTF-8 bytes throughout (no
    /// `Character` or `String ==` semantics). Only `HTTP/1.1` text is accepted; the body is the bytes
    /// after the first blank line, verbatim; `Content-Length` is added or corrected to match.
    public func parse(limits: RulesLimits = RulesLimits())
        -> Result<(response: GeneratedResponse, warnings: [HandwrittenResponseWarning]), HandwrittenResponseError>
    {
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return .failure(.empty) }
        if bytes.count > limits.handwrittenResponseBytes { return .failure(.tooLarge) }

        // Line splitting: LF ends a line, one CR before it is dropped.
        var position = 0
        var lineNumber = 0
        func nextLine() -> ArraySlice<UInt8>? {
            guard position < bytes.count else { return nil }
            let start = position
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            position = min(end + 1, bytes.count)
            lineNumber += 1
            var line = bytes[start..<end]
            if line.last == 0x0D { line = line.dropLast() }
            return line
        }

        guard let statusLine = nextLine() else { return .failure(.empty) }
        let status: Int
        let reasonBytes: ArraySlice<UInt8>
        switch Self.parseStatusLine(statusLine) {
        case .failure(let error): return .failure(error)
        case .success(let parsed): (status, reasonBytes) = parsed
        }
        let reasonText = ByteText.string(reasonBytes)
        guard HTTPMutationValidator.isValidValue(reasonText) else { return .failure(.invalidStatusLine) }

        var headers: [HeaderField] = []
        var body = Data()
        while let line = nextLine() {
            if line.isEmpty {
                body = Data(bytes[position...])
                break
            }
            guard let colon = line.firstIndex(of: 0x3A) else { return .failure(.invalidHeader(line: lineNumber)) }
            let name = ByteText.string(line[..<colon])
            let value = ByteText.trimmed(ByteText.string(line[(colon + 1)...]))
            guard HTTPMutationValidator.isToken(name), HTTPMutationValidator.isValidValue(value) else {
                return .failure(.invalidHeader(line: lineNumber))
            }
            let lowered = ByteText.asciiLowercased(name)
            if Self.forbiddenNames.contains(where: { bytesEqual($0, lowered) }) {
                return .failure(.forbiddenHeader(name: name))
            }
            headers.append(HeaderField(name: name, value: value))
        }

        let bodyless = status == 204 || status == 304
        if bodyless, !body.isEmpty { return .failure(.bodyNotAllowed) }
        // RFC 9110 8.6: a 204 never carries Content-Length (a 304 may repeat the one of the 200).
        if status == 204, headers.contains(where: { bytesEqual(ByteText.asciiLowercased($0.name), "content-length") }) {
            return .failure(.bodyNotAllowed)
        }

        var warnings: [HandwrittenResponseWarning] = []
        if !bodyless {
            let actual = String(body.count)
            let lengthIndices = headers.indices.filter { bytesEqual(ByteText.asciiLowercased(headers[$0].name), "content-length") }
            if let first = lengthIndices.first {
                if lengthIndices.count > 1 || !bytesEqual(headers[first].value, actual) {
                    warnings.append(.contentLengthCorrected)
                    headers[first].value = actual
                    for index in lengthIndices.dropFirst().reversed() { headers.remove(at: index) }
                }
            } else {
                warnings.append(.contentLengthAdded)
                headers.append(HeaderField(name: "Content-Length", value: actual))
            }
        }

        let reason = reasonBytes.isEmpty ? GeneratedResponse.standardReason(for: status) : reasonText
        let response = GeneratedResponse(status: status, reason: reason, headers: headers, body: body, kind: .handwritten)
        return .success((response, warnings))
    }

    /// `HTTP/1.1 SP 3DIGIT [SP reason]`; an empty or blank reason counts as missing.
    private static func parseStatusLine(_ line: ArraySlice<UInt8>)
        -> Result<(Int, ArraySlice<UInt8>), HandwrittenResponseError>
    {
        let prefix = Array("HTTP/".utf8)
        guard line.starts(with: prefix) else { return .failure(.invalidStatusLine) }
        let versionEnd = line.firstIndex(of: 0x20) ?? line.endIndex
        guard line[line.startIndex..<versionEnd].elementsEqual(Array("HTTP/1.1".utf8)) else {
            return .failure(.unsupportedVersion)
        }
        guard versionEnd < line.endIndex else { return .failure(.invalidStatusLine) }
        let codeStart = versionEnd + 1
        guard codeStart + 3 <= line.endIndex else { return .failure(.invalidStatusLine) }
        let digits = line[codeStart..<(codeStart + 3)]
        guard digits.allSatisfy({ (48...57).contains($0) }) else { return .failure(.invalidStatusLine) }
        let afterCode = codeStart + 3
        if afterCode < line.endIndex, line[afterCode] != 0x20 { return .failure(.invalidStatusLine) }
        let status = digits.reduce(0) { $0 * 10 + Int($1 - 48) }
        guard (200...599).contains(status) else { return .failure(.invalidStatus) }
        let rest = afterCode < line.endIndex ? line[(afterCode + 1)...] : line[line.endIndex...]
        return .success((status, Self.trimSpaces(rest)))
    }

    private static func trimSpaces(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = bytes
        while slice.first == 0x20 || slice.first == 0x09 { slice = slice.dropFirst() }
        while slice.last == 0x20 || slice.last == 0x09 { slice = slice.dropLast() }
        return slice
    }
}
