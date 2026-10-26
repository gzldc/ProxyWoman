import Foundation

/// A bounded, prepared body shared by tree eligibility and the body viewer, without parsing twice.
public struct PreparedBody: Sendable {
    let content: BodyContent
    let rawCount: Int
    let contentType: String?
    let contentEncoding: String?
    let isTruncated: Bool
    let isCaptureTruncated: Bool

    public var hasJSONTree: Bool { content.decodeError == nil && content.jsonRoots != nil }

    public static func prepare(
        data: Data, contentType: String?, contentEncoding: String?, isTruncated: Bool = false,
        isCaptureTruncated: Bool = false
    ) throws -> PreparedBody {
        try Task.checkCancellation()
        let content = BodyContent.make(
            data: data, contentType: contentType, contentEncoding: contentEncoding,
            isTruncated: isTruncated || isCaptureTruncated)
        try Task.checkCancellation()
        return PreparedBody(
            content: content, rawCount: data.count, contentType: contentType, contentEncoding: contentEncoding,
            isTruncated: isTruncated, isCaptureTruncated: isCaptureTruncated)
    }
}
