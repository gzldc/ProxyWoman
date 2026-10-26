/// The first generation of built-in templates (15 rules). They are no longer installed; the list stays so an
/// untouched copy of the old group can be recognised and replaced (`untouchedLegacyGroupIDs`).
public enum RuleTemplate: String, CaseIterable, Sendable, Hashable {
    case simulate404, simulate500, simulate429, addCORSHeaders, disableCaching, delay2Seconds, markDomain
    case httpToHttps, recordAllPOST, blockAnalytics, breakpointPUT, stripAuthorization, forceStatus200
    case hideNoise, closeConnection
}
