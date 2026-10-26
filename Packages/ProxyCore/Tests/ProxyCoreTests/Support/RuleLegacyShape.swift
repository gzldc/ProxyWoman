import RulesEngine

// Test fixtures built for the one-matcher, one-action rule read and write `rule.matcher` and `rule.action`.
// A rule that the old editor can state (`simple`) still has them; reading them from any other rule is a
// bug in the test, and writing one rebuilds the rule from the matcher and action given (identity, state,
// group, note and combination mode stay).

extension Rule {
    /// The matcher of a rule the old editor can state.
    var matcher: RuleMatcher {
        get { simple.unsafelyShown.matcher }
        set { self = rebuilt(matcher: newValue, action: simple.unsafelyShown.action) }
    }

    /// The action of a rule the old editor can state.
    var action: LegacyRuleAction {
        get { simple.unsafelyShown.action }
        set { self = rebuilt(matcher: simple.unsafelyShown.matcher, action: newValue) }
    }

    /// The same rule with another matcher and action; identity, state, group, note and combination stay.
    private func rebuilt(matcher: RuleMatcher, action: LegacyRuleAction) -> Rule {
        var rule = Rule(id: id, name: name, enabled: enabled, order: order, matcher: matcher, action: action)
        rule.groupID = groupID
        rule.note = note
        rule.conditions.mode = conditions.mode
        return rule
    }
}

extension Optional where Wrapped == SimpleRule {
    fileprivate var unsafelyShown: SimpleRule {
        guard let self else { preconditionFailure("the test read matcher or action of a rule the old editor cannot state") }
        return self
    }
}
