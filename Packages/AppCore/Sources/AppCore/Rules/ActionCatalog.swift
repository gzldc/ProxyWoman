import Foundation
import Localization
import RulesEngine

/// One entry of the action menu.
public struct ActionCatalogEntry: Equatable, Sendable {
    public var type: ActionType
    public var direction: ConditionDirection
}

/// Which action types the menu offers, in what groups and order, and the direction icon of each (spec 12.7).
/// Map Remote and Return Directory are not offered to new cards (R8F2-8) but a saved rule that has one still shows
/// and edits it.
public enum ActionCatalog {
    private static func entry(_ type: ActionType, _ direction: ConditionDirection) -> ActionCatalogEntry {
        ActionCatalogEntry(type: type, direction: direction)
    }

    /// The menu in order; a line falls between two groups.
    public static let menuGroups: [[ActionCatalogEntry]] = [
        [entry(.mark, .both)],
        [entry(.modifyURL, .request), entry(.modifyQuery, .request), entry(.rewriteStatus, .response)],
        [entry(.rewriteRequestBody, .request), entry(.rewriteResponseBody, .response)],
        [entry(.editRequestHeaders, .request), entry(.editResponseHeaders, .response)],
        [entry(.editRequestCookies, .request), entry(.editResponseCookies, .response)],
        [entry(.requestBreakpoint, .request), entry(.responseBreakpoint, .response)],
        [
            entry(.returnFile, .both), entry(.returnHandwritten, .both), entry(.returnPreset, .both),
            entry(.returnConnectTunnel, .request),
        ],
        [entry(.hide, .both), entry(.noDecrypt, .request)],
        [entry(.closeConnectionGraceful, .both), entry(.closeConnectionReset, .both)],
        [entry(.delay, .both)],
        [entry(.comment, .both)],
        [entry(.magicString, .both)],
    ]

    /// The types the menu offers, flat and in order.
    public static var menuTypes: [ActionType] { menuGroups.flatMap { $0.map(\.type) } }

    /// Not in the menu (a new card cannot pick it) but a saved rule can still hold it.
    public static let legacyOnlyTypes: [ActionType] = [.mapRemote, .returnDirectory]

    public static func isLegacyOnly(_ type: ActionType) -> Bool { legacyOnlyTypes.contains(type) }

    /// The direction of any type; the two legacy ones read the request (they route it).
    public static func direction(of type: ActionType) -> ConditionDirection {
        for group in menuGroups {
            if let found = group.first(where: { $0.type == type }) { return found.direction }
        }
        return .request
    }
}

extension ActionType {
    /// The circle arrow the menu and the card header show.
    public var direction: ConditionDirection { ActionCatalog.direction(of: self) }

    /// Not offered to a new card (R8F2-8).
    public var isLegacyOnly: Bool { ActionCatalog.isLegacyOnly(self) }
}

public struct ActionMenuItem: Equatable, Sendable, Identifiable {
    public var type: ActionType
    public var direction: ConditionDirection
    /// Why the type cannot be chosen now; nil when it can.
    public var reason: ActionType.Reason?
    public var id: String { type.id }
    public var isAvailable: Bool { reason == nil }
}

public struct ActionMenuSection: Equatable, Sendable, Identifiable {
    public var index: Int
    public var items: [ActionMenuItem]
    public var id: Int { index }
}

/// The grouped action menu, one section per group of `ActionCatalog.menuGroups`.
public enum ActionMenuPresentation {
    public static func sections(availability: (ActionType) -> ActionType.Availability) -> [ActionMenuSection] {
        ActionCatalog.menuGroups.enumerated().map { index, group in
            ActionMenuSection(
                index: index,
                items: group.map { entry in
                    if case .unavailable(let reason) = availability(entry.type) {
                        return ActionMenuItem(type: entry.type, direction: entry.direction, reason: reason)
                    }
                    return ActionMenuItem(type: entry.type, direction: entry.direction, reason: nil)
                })
        }
    }

    /// The type a new card starts as: Mark with both colours unchanged (spec 12.6).
    public static var defaultNewType: ActionType { .mark }
}
