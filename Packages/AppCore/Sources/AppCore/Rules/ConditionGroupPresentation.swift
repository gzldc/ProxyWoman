import Foundation
import Localization
import RulesEngine

/// The tone of the whole-group match count line: red at zero, otherwise secondary grey.
public enum MatchCountTone: Equatable, Sendable { case failure, secondary }

/// "N matches in the current tab", one line for the whole group, at the end of the condition list.
public struct ConditionMatchCountLine: Equatable, Sendable {
    public var text: String
    public var count: Int
    public var tone: MatchCountTone
    /// The "view" link is there when something matched.
    public var showsViewLink: Bool
}

/// The line under the condition header: when the sessions are matched, with the direction icon of that moment.
public struct ConditionExecutionLine: Equatable, Sendable {
    public var text: String
    public var direction: ConditionDirection
}

/// The words around the whole group of conditions: when it is judged, how many sessions match, which rows are deprecated.
public enum ConditionGroupPresentation {
    /// R8F2-1: the line says when the engine really judges the group. A connection or request point reads "request", a
    /// response point "response"; the completion point (ours alone) reads "when finished" with the both-ways icon.
    public static func executionLine(point: EvaluationPoint, localizer: Localizer = L10n.localizer) -> ConditionExecutionLine {
        switch point {
        case .connect:
            ConditionExecutionLine(text: localizer.string("rules.builder.matchedAt.connect"), direction: .request)
        case .request:
            ConditionExecutionLine(text: localizer.string("rules.builder.matchedAt.request"), direction: .request)
        case .response:
            ConditionExecutionLine(text: localizer.string("rules.builder.matchedAt.response"), direction: .response)
        case .completion:
            ConditionExecutionLine(text: localizer.string("rules.builder.matchedAt.completion"), direction: .both)
        }
    }

    /// R8F3-1: which phase the line names, as the reference classifies the rows (not where the engine really judges).
    public enum Phase: Equatable, Sendable { case request, response, either }

    /// Either when any row is direction-agnostic, or when request and response rows are both present and the group is "any";
    /// else response when any response row is present; else request. "None" and an empty group get no special case.
    public static func phase(fields: [ConditionField], mode: ConditionGroup.Mode) -> Phase {
        var hasResponse = false, hasRequest = false, hasAgnostic = false
        for field in fields {
            switch ConditionFieldCatalog.direction(of: field) {
            case .response: hasResponse = true
            case .both: hasAgnostic = true
            case .request: hasRequest = true
            }
        }
        if hasAgnostic || (hasRequest && hasResponse && mode == .any) { return .either }
        return hasResponse ? .response : .request
    }

    public static func executionLine(phase: Phase, localizer: Localizer = L10n.localizer) -> ConditionExecutionLine {
        switch phase {
        case .request: executionLine(point: .request, localizer: localizer)
        case .response: executionLine(point: .response, localizer: localizer)
        case .either: eitherPhaseLine(localizer: localizer)
        }
    }

    /// "Either request or response".
    public static func eitherPhaseLine(localizer: Localizer = L10n.localizer) -> ConditionExecutionLine {
        ConditionExecutionLine(text: localizer.string("rules.builder.matchedAt.either"), direction: .both)
    }

    /// The count line; nil while the count is unknown. A group that is not valid yet matches nothing, so its line is a red zero.
    public static func matchCountLine(
        count: Int?, groupIsValid: Bool = true, localizer: Localizer = L10n.localizer
    ) -> ConditionMatchCountLine? {
        guard let known = groupIsValid ? count : 0 else { return nil }
        return ConditionMatchCountLine(
            text: localizer.format("rules.editor3.groupMatchCount", arguments: [known]), count: known,
            tone: known == 0 ? .failure : .secondary, showsViewLink: known > 0)
    }

    /// The yellow card for deprecated fields, nil when there are none: one sentence for a single field and one for several,
    /// the names joined with the list separator and the last joiner of the language.
    public static func deprecationText(for fields: [ConditionField], localizer: Localizer = L10n.localizer) -> String? {
        var unique: [ConditionField] = []
        for field in fields where !unique.contains(field) { unique.append(field) }
        let names = unique.map { ConditionPresentation.fieldTitle($0, localizer: localizer) }
        switch names.count {
        case 0: return nil
        case 1: return localizer.format("rules.editor3.deprecation.single", arguments: [names[0]])
        default:
            let head = names.dropLast().joined(separator: localizer.string("rules.editor3.list.separator"))
            let list = localizer.format("rules.editor3.list.lastJoiner", arguments: [head, names[names.count - 1]])
            return localizer.format("rules.editor3.deprecation.multiple", arguments: [list])
        }
    }
}

extension ConditionsDraft {
    /// The last row cannot be deleted: its delete button is disabled.
    public var canRemoveRows: Bool { rows.count > 1 }

    /// The deprecated fields among the rows, each once, in row order.
    public var deprecatedFields: [ConditionField] { ConditionFieldCatalog.deprecatedFields(in: rows.map(\.row)) }

    public func deprecationText(localizer: Localizer = L10n.localizer) -> String? {
        ConditionGroupPresentation.deprecationText(for: deprecatedFields, localizer: localizer)
    }

    public func executionLine(localizer: Localizer = L10n.localizer) -> ConditionExecutionLine {
        ConditionGroupPresentation.executionLine(
            phase: ConditionGroupPresentation.phase(fields: rows.map(\.row.field), mode: mode), localizer: localizer)
    }
}
