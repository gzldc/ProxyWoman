import Foundation

/// The texts the first template group (the one a build before this round installed) was written with, in
/// the language it was installed in. Only used to tell an untouched copy of that group from an edited one.
public struct LegacyTemplateTexts: Sendable, Equatable {
    public var groupName: String
    public var names: [RuleTemplate: String]
    public var notes: [RuleTemplate: String]

    public init(groupName: String, name: (RuleTemplate) -> String, note: (RuleTemplate) -> String) {
        self.groupName = groupName
        var names: [RuleTemplate: String] = [:]
        var notes: [RuleTemplate: String] = [:]
        for template in RuleTemplate.allCases {
            names[template] = name(template)
            notes[template] = note(template)
        }
        self.names = names
        self.notes = notes
    }
}

extension RuleTemplateCatalog {
    /// The groups that are exactly the old template group as it was installed: at the root, disabled, named
    /// as `texts` says, with no subgroup, and holding exactly the 15 rules of the old catalog (same texts,
    /// conditions, actions, disabled, numbered `0…14`) and nothing else. A group the user changed in any
    /// way, or one that holds anything else, is not listed.
    static func untouchedLegacyGroupIDs(groups: [RuleGroup], rules: [Rule], texts: LegacyTemplateTexts) -> [UUID] {
        groups.filter { group in
            guard group.parentID == nil, !group.enabled, group.name == texts.groupName,
                !groups.contains(where: { $0.parentID == group.id })
            else { return false }
            let inside = rules.filter { $0.groupID == group.id }.sorted { $0.order < $1.order }
            guard inside.count == RuleTemplate.allCases.count else { return false }
            for (index, template) in RuleTemplate.allCases.enumerated() {
                let rule = inside[index]
                let installed = self.rule(
                    template, name: texts.names[template] ?? "", note: texts.notes[template] ?? "", id: rule.id,
                    order: index, groupID: group.id)
                if rule != installed { return false }
            }
            return true
        }.map(\.id)
    }
}
