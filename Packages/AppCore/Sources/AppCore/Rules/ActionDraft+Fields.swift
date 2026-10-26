import Foundation
import RulesEngine

/// The boxes of a card's editor as plain text properties, so the view binds to the same names for every type
/// (spec 12.7): the key, the find box, the value box and the find box's "Aa". They read and write the card's form
/// (a table's first edit, the URL, body, comment, status, delay and magic string drafts); a type without the box ignores
/// a write and reads empty.
extension ActionDraft {
    /// The method is find and replace or a regular expression: the find box shows and the value box is the replacement.
    public var usesFindBox: Bool {
        guard let id = modeID else { return false }
        return id == "findReplace" || id == "regex"
    }

    /// The key box of a header, cookie or query card.
    public var keyText: String {
        get {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: headerRows.first?.name ?? ""
            case .editRequestCookies, .editResponseCookies: cookieRows.first?.name ?? ""
            case .modifyQuery: queryRows.first?.name ?? ""
            default: ""
            }
        }
        set {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: Self.first(&headerRows, HeaderEditRow()) { $0.name = newValue }
            case .editRequestCookies, .editResponseCookies: Self.first(&cookieRows, CookieEditRow()) { $0.name = newValue }
            case .modifyQuery: Self.first(&queryRows, QueryEditRow()) { $0.name = newValue }
            default: break
            }
        }
    }

    /// The text to look for (find and replace, regular expression).
    public var findText: String {
        get {
            switch type {
            case .modifyURL: url.find
            case .rewriteRequestBody, .rewriteResponseBody: body.find
            case .comment: comment.text
            default: rowValue
            }
        }
        set {
            switch type {
            case .modifyURL: url.find = newValue
            case .rewriteRequestBody, .rewriteResponseBody: body.find = newValue
            case .comment: comment.text = newValue
            default: rowValue = newValue
            }
        }
    }

    /// The value box: the value to write, what to append, or what to replace with when the find box shows.
    public var valueText: String {
        get {
            switch type {
            case .modifyURL: url.replacement
            case .rewriteRequestBody, .rewriteResponseBody: body.replacement
            case .comment: usesFindBox ? comment.replacement : comment.text
            case .rewriteStatus: status.status
            case .delay: delayText
            case .magicString: magicText
            default: usesFindBox ? rowReplacement : rowValue
            }
        }
        set {
            switch type {
            case .modifyURL: url.replacement = newValue
            case .rewriteRequestBody, .rewriteResponseBody: body.replacement = newValue
            case .comment:
                if usesFindBox { comment.replacement = newValue } else { comment.text = newValue }
            case .rewriteStatus: status.status = String(newValue.prefix(RewriteStatusAction.maxTextCharacters))
            case .delay: delayText = newValue
            case .magicString: magicText = newValue
            default:
                if usesFindBox { rowReplacement = newValue } else { rowValue = newValue }
            }
        }
    }

    /// The find box's "Aa": upper and lower case differ.
    public var matchCase: Bool {
        get {
            switch type {
            case .modifyURL: url.caseSensitive
            case .rewriteRequestBody, .rewriteResponseBody: body.caseSensitive
            case .comment: comment.caseSensitive
            case .editRequestHeaders, .editResponseHeaders: headerRows.first?.caseSensitive ?? false
            case .editRequestCookies, .editResponseCookies: cookieRows.first?.caseSensitive ?? false
            case .modifyQuery: queryRows.first?.caseSensitive ?? false
            default: false
            }
        }
        set {
            switch type {
            case .modifyURL: url.caseSensitive = newValue
            case .rewriteRequestBody, .rewriteResponseBody: body.caseSensitive = newValue
            case .comment: comment.caseSensitive = newValue
            case .editRequestHeaders, .editResponseHeaders: Self.first(&headerRows, HeaderEditRow()) { $0.caseSensitive = newValue }
            case .editRequestCookies, .editResponseCookies: Self.first(&cookieRows, CookieEditRow()) { $0.caseSensitive = newValue }
            case .modifyQuery: Self.first(&queryRows, QueryEditRow()) { $0.caseSensitive = newValue }
            default: break
            }
        }
    }

    /// The inputs an error of the key, find and value boxes belongs to, and the whole card's own list issue (the table's
    /// first edit; the URL, body or comment fields).
    public var editFields: (key: ActionField?, find: ActionField?, value: ActionField?, list: ActionField?) {
        switch type {
        case .modifyURL: return (nil, .urlFind, .urlReplacement, nil)
        case .rewriteRequestBody, .rewriteResponseBody: return (nil, .bodyFind, .bodyReplacement, nil)
        case .comment: return (nil, .commentFind, usesFindBox ? .commentReplacement : .commentText, nil)
        case .editRequestHeaders, .editResponseHeaders:
            let row = headerRows.first.map { ActionField.headerRow($0.id) }
            return (row, row, row, .headerRow(id))
        case .editRequestCookies, .editResponseCookies:
            let row = cookieRows.first.map { ActionField.cookieRow($0.id) }
            return (row, row, row, .cookieRow(id))
        case .modifyQuery:
            let row = queryRows.first.map { ActionField.queryRow($0.id) }
            return (row, row, row, .queryRow(id))
        case .rewriteStatus: return (nil, nil, .status, nil)
        case .delay: return (nil, nil, .delay, nil)
        case .magicString: return (nil, nil, .magicString, nil)
        default: return (nil, nil, nil, nil)
        }
    }

    // MARK: first edit of a table

    private static func first<Row>(_ rows: inout [Row], _ empty: Row, _ change: (inout Row) -> Void) {
        if rows.isEmpty { rows = [empty] }
        change(&rows[0])
    }

    private var rowValue: String {
        get {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: headerRows.first?.value ?? ""
            case .editRequestCookies, .editResponseCookies: cookieRows.first?.value ?? ""
            case .modifyQuery: queryRows.first?.value ?? ""
            default: ""
            }
        }
        set {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: Self.first(&headerRows, HeaderEditRow()) { $0.value = newValue }
            case .editRequestCookies, .editResponseCookies: Self.first(&cookieRows, CookieEditRow()) { $0.value = newValue }
            case .modifyQuery: Self.first(&queryRows, QueryEditRow()) { $0.value = newValue }
            default: break
            }
        }
    }

    private var rowReplacement: String {
        get {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: headerRows.first?.replacement ?? ""
            case .editRequestCookies, .editResponseCookies: cookieRows.first?.replacement ?? ""
            case .modifyQuery: queryRows.first?.replacement ?? ""
            default: ""
            }
        }
        set {
            switch type {
            case .editRequestHeaders, .editResponseHeaders: Self.first(&headerRows, HeaderEditRow()) { $0.replacement = newValue }
            case .editRequestCookies, .editResponseCookies: Self.first(&cookieRows, CookieEditRow()) { $0.replacement = newValue }
            case .modifyQuery: Self.first(&queryRows, QueryEditRow()) { $0.replacement = newValue }
            default: break
            }
        }
    }
}
