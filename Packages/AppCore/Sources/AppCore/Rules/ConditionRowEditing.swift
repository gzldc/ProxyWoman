import Foundation
import RulesEngine

extension ConditionRowDraft {
    /// Whether the comparison menu entry is the row's current one. The certificate's validity entries share `equals` and
    /// tell themselves apart by the value they set.
    public func isSelected(_ item: ConditionOperatorItem) -> Bool {
        guard let itemValue = item.value else { return op == item.op }
        return op == item.op && value.lowercased() == itemValue
    }

    /// Picks the comparison menu entry: a validity entry sets the comparison and the value, any other only the comparison.
    public mutating func select(_ item: ConditionOperatorItem) {
        if let itemValue = item.value, let valid = CertificateValidity.decode(op: item.op, value: itemValue) {
            setCertificateValidity(valid: valid)
        } else {
            setOperator(item.op)
        }
    }
}

extension ConditionSuggestions {
    /// What the popup under a box lists for the text typed so far: the candidates that contain it (any case), in the order
    /// given, without the one that is already typed out. Nothing typed lists the first candidates.
    public static func matching(_ candidates: [String], typed: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let needle = typed.lowercased()
        let found = candidates.filter { candidate in
            candidate != typed && (needle.isEmpty || candidate.lowercased().contains(needle))
        }
        return Array(found.prefix(limit))
    }
}
