import Foundation
import RulesEngine

/// What an Execute run was asked to do (D4, D13): which rules, and the flow ids each scope can offer.
public struct ExecuteRequest: Sendable, Equatable {
    public var rules: ExecuteRuleScope
    /// The flows selected in the list at the moment of asking.
    public var selectedIDs: [Int]
    /// The flows the current filter shows.
    public var filteredIDs: [Int]

    public init(rules: ExecuteRuleScope, selectedIDs: [Int] = [], filteredIDs: [Int] = []) {
        self.rules = rules
        self.selectedIDs = selectedIDs
        self.filteredIDs = filteredIDs
    }
}

public enum ExecuteFlowScope: Sendable, Equatable { case selected, filtered, all }

/// The result of one run (D12).
public struct ExecuteSummary: Sendable, Equatable {
    public struct RuleLine: Sendable, Equatable {
        public var ruleID: UUID
        public var flows: Int
        public init(ruleID: UUID, flows: Int) {
            self.ruleID = ruleID
            self.flows = flows
        }
    }

    public var runID: UUID
    /// Evaluation order; rules that matched nothing are listed with 0.
    public var rules: [RuleLine]
    /// Flows that went through the rules (skipped ones included, flows already gone when picked up excluded).
    public var considered: Int
    public var matchedFlows: Int
    public var modifiedFlows: Int
    public var hiddenFlows: Int
    public var annotatedFlows: Int
    public var skippedInProgress: Int
    public var skippedHidden: Int
    public var notApplicableActions: Int
    public var vanished: Int
    public var wasCancelled: Bool

    public init(
        runID: UUID, rules: [RuleLine] = [], considered: Int = 0, matchedFlows: Int = 0, modifiedFlows: Int = 0,
        hiddenFlows: Int = 0, annotatedFlows: Int = 0, skippedInProgress: Int = 0, skippedHidden: Int = 0,
        notApplicableActions: Int = 0, vanished: Int = 0, wasCancelled: Bool = false
    ) {
        self.runID = runID
        self.rules = rules
        self.considered = considered
        self.matchedFlows = matchedFlows
        self.modifiedFlows = modifiedFlows
        self.hiddenFlows = hiddenFlows
        self.annotatedFlows = annotatedFlows
        self.skippedInProgress = skippedInProgress
        self.skippedHidden = skippedHidden
        self.notApplicableActions = notApplicableActions
        self.vanished = vanished
        self.wasCancelled = wasCancelled
    }
}
