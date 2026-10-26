import RulesEngine

/// Which inputs a row of a header, query or cookie table shows besides its name. `value` is what to write, or what to find
/// when `replacement` is also shown.
public struct RowInputs: Equatable, Sendable {
    public var value: Bool
    public var replacement: Bool
    public var caseSensitive: Bool

    public init(value: Bool, replacement: Bool, caseSensitive: Bool) {
        self.value = value
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }

    /// The value input is the text to look for.
    public var valueIsFind: Bool { replacement }

    static let nameOnly = RowInputs(value: false, replacement: false, caseSensitive: false)
    static let nameAndValue = RowInputs(value: true, replacement: false, caseSensitive: false)
    static let lookUp = RowInputs(value: true, replacement: true, caseSensitive: true)
}

extension HeaderMethod {
    public var inputs: RowInputs {
        switch self {
        case .set, .addIfMissing, .append, .appendToValue: .nameAndValue
        case .findReplace, .regex: .lookUp
        case .remove: .nameOnly
        }
    }

    /// An empty name means every field (spec 12.7), except where a field is created: there a name is needed.
    public var allowsEmptyName: Bool { self != .addIfMissing && self != .append }
}

extension QueryMethod {
    public var inputs: RowInputs {
        switch self {
        case .set, .add, .addIfMissing, .appendToValue: .nameAndValue
        case .findReplace, .regex: .lookUp
        case .remove: .nameOnly
        }
    }

    /// An empty name means every parameter, except where a parameter is created.
    public var allowsEmptyName: Bool { self != .add && self != .addIfMissing }
}

extension CookieMethod {
    public var inputs: RowInputs {
        switch self {
        case .set, .addIfMissing, .appendToValue: .nameAndValue
        case .findReplace, .regex: .lookUp
        case .remove: .nameOnly
        }
    }

    /// An empty name means every cookie, except where a cookie is created.
    public var allowsEmptyName: Bool { self != .addIfMissing }
}

/// Which extra texts a preset response form shows.
public struct PresetInputs: Equatable, Sendable {
    public var location: Bool
    public var challenge: Bool
    public var body: Bool

    public init(location: Bool, challenge: Bool, body: Bool) {
        self.location = location
        self.challenge = challenge
        self.body = body
    }

    public init(_ preset: PresetResponse.Preset) {
        let shape = PresetResponse(preset: preset)
        location = shape.requiresLocation
        challenge = preset == .unauthorized401 || preset == .proxyAuthRequired407
        body = shape.acceptsBody
    }
}

/// The size counter under the handwritten response.
public enum HandwrittenCounter {
    public static func bytes(_ text: String) -> Int { text.utf8.count }
    public static func isOver(_ text: String, limit: Int) -> Bool { bytes(text) > limit }
}

extension BodyRewriteOperation {
    public var titleKey: String {
        switch self {
        case .findReplace: "rules.bodyOperation.findReplace"
        case .setValue: "rules.bodyOperation.setValue"
        case .clear: "rules.bodyOperation.clear"
        }
    }
}

extension ActionType.Side {
    /// The word that goes with the direction dot (the dot's colour is never the only information).
    public var titleKey: String {
        switch self {
        case .request: "rules.side.request"
        case .response: "rules.side.response"
        case .both: "rules.side.both"
        case .none: "rules.side.neither"
        }
    }
}
