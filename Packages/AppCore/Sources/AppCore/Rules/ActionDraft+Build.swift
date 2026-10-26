import FlowStore
import Foundation
import RulesEngine

extension ActionDraft {
    /// Reads the form of the current type. Every broken field is reported at once, found by running the engine's
    /// own validation on the smallest action that contains it, so the sentences are the ones the saved rule would get.
    ///
    /// A card opened from a stored action hands that action back while the form still builds what it built on opening,
    /// so what the form cannot show exactly (a name stored as an empty text, a mark colour from before) is never rewritten.
    public func build(limits: RulesLimits = RulesLimits()) -> ActionBuildResult {
        var result = buildForm(limits: limits)
        if let baseline, isUnchanged(since: result) {
            result.action = RuleAction(baseline.original.kind, isFinal: isFinal)
        }
        return result
    }

    /// The form's own reading, without the stored action.
    func buildForm(limits: RulesLimits) -> ActionBuildResult {
        if let opaque { return ActionBuildResult(action: opaque) }
        let outcome: Outcome
        switch type {
        case .modifyURL: outcome = buildURL(limits)
        case .modifyQuery: outcome = buildQuery(limits)
        case .editRequestHeaders: outcome = buildHeaders(.request, limits)
        case .editResponseHeaders: outcome = buildHeaders(.response, limits)
        case .editRequestCookies: outcome = buildCookies(.request, limits)
        case .editResponseCookies: outcome = buildCookies(.response, limits)
        case .rewriteRequestBody: outcome = buildBody(.request, limits)
        case .rewriteResponseBody: outcome = buildBody(.response, limits)
        case .mapRemote: outcome = buildMapRemote(limits)
        case .requestBreakpoint: outcome = Outcome(kind: .breakpoint(direction: .request, mode: breakpointMode))
        case .responseBreakpoint: outcome = Outcome(kind: .breakpoint(direction: .response, mode: breakpointMode))
        case .delay: outcome = buildDelay(limits)
        case .rewriteStatus: outcome = buildStatus(limits)
        case .returnFile: outcome = buildFile(limits)
        case .returnDirectory: outcome = buildDirectory(limits)
        case .returnHandwritten: outcome = buildHandwritten(limits)
        case .returnPreset: outcome = buildPreset(limits)
        case .closeConnectionGraceful: outcome = Outcome(kind: .closeConnection(.graceful))
        case .closeConnectionReset: outcome = Outcome(kind: .closeConnection(.reset))
        case .returnConnectTunnel: outcome = Outcome(kind: .returnConnectTunnel)
        case .noDecrypt: outcome = Outcome(kind: .noDecrypt)
        case .hide: outcome = Outcome(kind: .hide, warnings: [.hideCutsLowerRules])
        case .mark: outcome = buildMark(limits)
        case .comment: outcome = buildComment(limits)
        case .magicString: outcome = buildMagicString(limits)
        }
        guard outcome.issues.isEmpty, let kind = outcome.kind else {
            return ActionBuildResult(action: nil, issues: outcome.issues, warnings: outcome.warnings)
        }
        return ActionBuildResult(action: RuleAction(kind, isFinal: isFinal), issues: [:], warnings: outcome.warnings)
    }

    struct Outcome {
        var kind: ActionKind?
        var issues: [ActionField: RuleDraftIssue] = [:]
        var warnings: [ActionWarning] = []
    }

    /// The engine's verdict on one action on its own, in the context of a rule judged at the request point.
    private static func verdict(_ kind: ActionKind, _ limits: RulesLimits) -> RuleValidationError? {
        do {
            try Rule(name: "", actions: [RuleAction(kind)]).validate(limits: limits)
            return nil
        } catch let error as RuleValidationError {
            return error
        } catch {
            return RuleValidationError(code: .invalidHeaderEdit, field: .name)
        }
    }

    private static func issue(_ kind: ActionKind, _ limits: RulesLimits) -> RuleDraftIssue? {
        verdict(kind, limits).map { RuleDraftIssue($0) }
    }

    /// A number typed into a form: nil with the issue when it is empty or not an integer.
    private static func number(_ text: String, _ field: ActionField, issues: inout [ActionField: RuleDraftIssue]) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            issues[field] = .required
            return nil
        }
        guard let value = Int(trimmed) else {
            issues[field] = .notANumber
            return nil
        }
        return value
    }

    // MARK: URL

    private func buildURL(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let edit = URLEditAction(
            mode: url.mode, find: url.find, replacement: url.replacement, caseSensitive: url.caseSensitive,
            preserveCredentials: url.preserveCredentials)
        let kind = ActionKind.modifyURL(edit)
        if url.mode == .set || url.mode == .append, url.replacement.isEmpty {
            outcome.issues[.urlReplacement] = .required
        } else if let error = Self.verdict(kind, limits) {
            switch error.code {
            case .emptyEditFind, .findTooLong, .invalidRegex, .regexTooComplex: outcome.issues[.urlFind] = RuleDraftIssue(error)
            default: outcome.issues[.urlReplacement] = RuleDraftIssue(error)
            }
        }
        outcome.kind = kind
        return outcome
    }

    // MARK: rows

    /// Checks each row as an action of its own; a problem that only the whole list has lands on `listField`.
    private func checkRows<Row: Identifiable>(
        _ rows: [Row], field: (UUID) -> ActionField, listField: ActionField, emptyIssue: RuleDraftIssue, limits: RulesLimits,
        blankName: (Row) -> RuleDraftIssue?, edit: (Row) -> ActionKind, whole: ActionKind
    ) -> [ActionField: RuleDraftIssue] where Row.ID == UUID {
        var issues: [ActionField: RuleDraftIssue] = [:]
        guard !rows.isEmpty else { return [listField: emptyIssue] }
        for row in rows {
            // The engine reads an empty name as "all keys" now; this form still asks for a name where it did.
            if let blank = blankName(row) {
                issues[field(row.id)] = blank
            } else if let found = Self.issue(edit(row), limits) {
                issues[field(row.id)] = found
            }
        }
        if issues.isEmpty, let found = Self.issue(whole, limits) { issues[listField] = found }
        return issues
    }

    private func buildHeaders(_ direction: HTTPMessageDirection, _ limits: RulesLimits) -> Outcome {
        func edit(_ row: HeaderEditRow) -> HeaderEdit {
            let flag = row.nameCaseSensitive
            return switch row.method {
            case .set: .set(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .addIfMissing: .addIfMissing(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .append: .append(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .appendToValue: .appendToValue(name: row.name, text: row.value, nameCaseSensitive: flag)
            case .findReplace:
                .findReplace(
                    name: row.name, find: row.value, replacement: row.replacement, caseSensitive: row.caseSensitive,
                    nameCaseSensitive: flag)
            case .regex:
                .regex(
                    name: row.name, pattern: row.value, replacement: row.replacement, caseSensitive: row.caseSensitive,
                    nameCaseSensitive: flag)
            case .remove: .remove(name: row.name, nameCaseSensitive: flag)
            }
        }
        let kind = ActionKind.editHeaders(direction: direction, operations: headerRows.map(edit))
        let issues = checkRows(
            headerRows, field: { .headerRow($0) }, listField: .headerRow(id), emptyIssue: .required, limits: limits,
            blankName: { $0.name.isEmpty && !$0.method.allowsEmptyName ? .headerNameInvalid : nil },
            edit: { .editHeaders(direction: direction, operations: [edit($0)]) }, whole: kind)
        return Outcome(kind: kind, issues: issues)
    }

    private func buildQuery(_ limits: RulesLimits) -> Outcome {
        func edit(_ row: QueryEditRow) -> QueryEdit {
            let flag = row.nameCaseSensitive
            return switch row.method {
            case .set: .set(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .add: .add(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .remove: .remove(name: row.name, nameCaseSensitive: flag)
            case .addIfMissing: .addIfMissing(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .appendToValue: .appendToValue(name: row.name, text: row.value, nameCaseSensitive: flag)
            case .findReplace:
                .findReplace(
                    name: row.name.isEmpty ? nil : row.name, find: row.value, replacement: row.replacement,
                    caseSensitive: row.caseSensitive, nameCaseSensitive: flag)
            case .regex:
                .regex(
                    name: row.name.isEmpty ? nil : row.name, pattern: row.value, replacement: row.replacement,
                    caseSensitive: row.caseSensitive, nameCaseSensitive: flag)
            }
        }
        let kind = ActionKind.modifyQuery(QueryEditAction(operations: queryRows.map(edit)))
        let issues = checkRows(
            queryRows, field: { .queryRow($0) }, listField: .queryRow(id), emptyIssue: .invalidQueryEdit, limits: limits,
            blankName: { $0.name.isEmpty && !$0.method.allowsEmptyName ? .invalidQueryEdit : nil },
            edit: { .modifyQuery(QueryEditAction(operations: [edit($0)])) }, whole: kind)
        return Outcome(kind: kind, issues: issues)
    }

    private func buildCookies(_ direction: HTTPMessageDirection, _ limits: RulesLimits) -> Outcome {
        func edit(_ row: CookieEditRow) -> CookieEdit {
            let name: String? = row.name.isEmpty ? nil : row.name
            let flag = row.nameCaseSensitive
            switch row.method {
            case .set: return .set(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .addIfMissing: return .addIfMissing(name: row.name, value: row.value, nameCaseSensitive: flag)
            case .remove: return .remove(name: row.name, nameCaseSensitive: flag)
            case .appendToValue: return .appendToValue(name: row.name, text: row.value, nameCaseSensitive: flag)
            case .findReplace:
                return .findReplace(
                    name: name, find: row.value, replacement: row.replacement, caseSensitive: row.caseSensitive,
                    nameCaseSensitive: flag)
            case .regex:
                return .regex(
                    name: name, pattern: row.value, replacement: row.replacement, caseSensitive: row.caseSensitive,
                    nameCaseSensitive: flag)
            }
        }
        let kind = ActionKind.editCookies(direction: direction, operations: cookieRows.map(edit))
        let issues = checkRows(
            cookieRows, field: { .cookieRow($0) }, listField: .cookieRow(id), emptyIssue: .invalidCookieEdit, limits: limits,
            blankName: { $0.name.isEmpty && !$0.method.allowsEmptyName ? .invalidCookieEdit : nil },
            edit: { .editCookies(direction: direction, operations: [edit($0)]) }, whole: kind)
        return Outcome(kind: kind, issues: issues)
    }

    // MARK: body

    private func buildBody(_ direction: HTTPMessageDirection, _ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let rewrite: BodyRewriteAction
        switch body.operation {
        case .clear:
            // Nothing is looked up or written, so whatever else is typed is neither checked nor kept.
            rewrite = BodyRewriteAction(find: "", replacement: "", operation: .clear)
        case .setValue:
            rewrite = BodyRewriteAction(
                find: "", replacement: body.replacement, operation: .setValue, editorLanguage: body.editorLanguage)
            if let found = Self.issue(.rewriteBody(direction: direction, rewrite), limits) {
                outcome.issues[.bodyReplacement] = found
            }
        case .findReplace:
            rewrite = BodyRewriteAction(
                find: body.find, replacement: body.replacement, syntax: body.syntax, caseSensitive: body.caseSensitive,
                scope: body.scope, editorLanguage: body.syntax == .text ? body.editorLanguage : nil)
            // The find text on its own, then the replacement against a known-good find text.
            var findOnly = rewrite
            findOnly.replacement = ""
            if let found = Self.issue(.rewriteBody(direction: direction, findOnly), limits) { outcome.issues[.bodyFind] = found }
            let replacementOnly = BodyRewriteAction(find: "x", replacement: body.replacement)
            if let found = Self.issue(.rewriteBody(direction: direction, replacementOnly), limits) {
                outcome.issues[.bodyReplacement] = found
            }
        }
        outcome.kind = .rewriteBody(direction: direction, rewrite)
        return outcome
    }

    // MARK: map remote, status, delay

    private func buildMapRemote(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let host = remote.targetHost.trimmingCharacters(in: .whitespaces)
        let port = Self.number(remote.targetPort, .targetPort, issues: &outcome.issues)
        let path: RemotePathPolicy = remote.pathChoice == .preserve ? .preserve : .replace(remote.replacementPath)
        // Each target field on its own, the others replaced by known-good values.
        func probe(host: String = "a.invalid", port: Int = 443, path: RemotePathPolicy = .preserve) -> ActionKind {
            .mapRemote(MapRemoteAction(targetScheme: "https", targetHost: host, targetPort: port, path: path))
        }
        if let found = Self.issue(probe(host: host), limits) { outcome.issues[.targetHost] = found }
        if let port, let found = Self.issue(probe(port: port), limits) { outcome.issues[.targetPort] = found }
        if let found = Self.issue(probe(path: path), limits) { outcome.issues[.targetPath] = found }
        outcome.kind = .mapRemote(
            MapRemoteAction(
                targetScheme: remote.targetScheme.rawValue, targetHost: host, targetPort: port ?? 443, path: path,
                preserveCredentials: remote.preserveCredentials))
        return outcome
    }

    /// The one status field, `404` or `404 Not Found` (at most 200 characters).
    private func buildStatus(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let text = status.status.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            outcome.issues[.status] = .required
            return outcome
        }
        guard let parsed = RewriteStatusAction.parse(text, includeLocalResponses: status.includeLocalResponses) else {
            outcome.issues[.status] = text.utf8.first.map { $0 >= 48 && $0 <= 57 } == true ? .invalidStatus : .notANumber
            return outcome
        }
        let kind = ActionKind.rewriteStatus(parsed)
        if let found = Self.issue(kind, limits) { outcome.issues[.status] = found }
        outcome.kind = kind
        return outcome
    }

    private func buildDelay(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        guard let value = Self.number(delayText, .delay, issues: &outcome.issues) else { return outcome }
        let kind = ActionKind.delay(milliseconds: value)
        if let found = Self.issue(kind, limits) { outcome.issues[.delay] = found }
        outcome.kind = kind
        return outcome
    }

    // MARK: magic string

    /// The text must be one of the Classic action strings; the engine's own check decides.
    private func buildMagicString(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        guard !magicText.isEmpty else {
            outcome.issues[.magicString] = .required
            return outcome
        }
        let kind = ActionKind.magicString(magicText)
        if let found = Self.issue(kind, limits) {
            if case .failure(.localFilePath) = MagicStringAction.resolve(magicText) {
                outcome.issues[.magicString] = .magicStringLocalFile
            } else {
                outcome.issues[.magicString] = found
            }
        }
        outcome.kind = kind
        return outcome
    }

    // MARK: return actions

    /// Probes the header rows of a file or directory form one by one; a problem lands on its row.
    private static func checkHeaders(
        _ rows: [HeaderFieldRow], limits: RulesLimits, probe: (HeaderField) -> ActionKind, issues: inout [ActionField: RuleDraftIssue]
    ) {
        for row in rows {
            if let found = issue(probe(HeaderField(name: row.name, value: row.value)), limits) { issues[.headerRow(row.id)] = found }
        }
    }

    private func buildFile(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let status = Self.number(file.status, .status, issues: &outcome.issues)
        let placeholder = UUID()
        if let status, let found = Self.issue(.returnFile(MapLocalAction(assetID: placeholder, status: status, headers: [])), limits) {
            outcome.issues[.status] = found
        }
        Self.checkHeaders(
            file.headers, limits: limits, probe: { .returnFile(MapLocalAction(assetID: placeholder, headers: [$0])) },
            issues: &outcome.issues)
        guard let asset = file.asset else {
            outcome.issues[.file] = .assetRequired
            return outcome
        }
        outcome.kind = .returnFile(
            MapLocalAction(
                assetID: asset.id, status: status ?? 200, headers: file.headers.map { HeaderField(name: $0.name, value: $0.value) }))
        return outcome
    }

    private func buildDirectory(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        func served(bookmark: Data, name: String = "", headers: [HeaderField] = []) -> MapLocalDirectoryAction {
            MapLocalDirectoryAction(bookmark: bookmark, displayName: name, headers: headers)
        }
        let probeBookmark = directory.bookmark ?? Data([0])
        if let found = Self.issue(.returnDirectory(served(bookmark: probeBookmark), pathPrefix: directoryPrefix), limits),
            found == .directoryNeedsPrefix
        {
            outcome.issues[.directoryPrefix] = found
        }
        if let found = Self.issue(.returnDirectory(served(bookmark: probeBookmark, name: directory.displayName), pathPrefix: "/"), limits) {
            outcome.issues[.directory] = found
        }
        Self.checkHeaders(
            directory.headers, limits: limits, probe: { .returnDirectory(served(bookmark: probeBookmark, headers: [$0]), pathPrefix: "/") },
            issues: &outcome.issues)
        guard let bookmark = directory.bookmark else {
            outcome.issues[.directory] = .directoryRequired
            return outcome
        }
        outcome.kind = .returnDirectory(
            MapLocalDirectoryAction(
                bookmark: bookmark, displayName: directory.displayName, servesIndex: directory.servesIndex, missing: directory.missing,
                headers: directory.headers.map { HeaderField(name: $0.name, value: $0.value) }),
            pathPrefix: directoryPrefix)
        return outcome
    }

    private func buildHandwritten(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let response = HandwrittenResponse(text: handwrittenText)
        let kind = ActionKind.returnHandwritten(response)
        if let found = Self.issue(kind, limits) {
            outcome.issues[.handwritten] = found
            return outcome
        }
        if case .success(let parsed) = response.parse(limits: limits), parsed.warnings.contains(.contentLengthCorrected) {
            outcome.warnings = [.contentLengthCorrected]
        }
        outcome.kind = kind
        return outcome
    }

    private func buildPreset(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        // Only what the chosen preset takes is stored; the other texts stay in the form for when the user changes back.
        let shape = PresetResponse(preset: preset)
        let location = shape.requiresLocation ? presetLocation : nil
        let challenge = preset == .unauthorized401 || preset == .proxyAuthRequired407 ? presetChallenge.nilIfEmpty : nil
        let body = shape.acceptsBody ? presetBody.nilIfEmpty : nil
        let stored = PresetResponse(preset: preset, body: body, location: location, challenge: challenge)
        let kind = ActionKind.returnPreset(stored)
        guard Self.issue(kind, limits) != nil else {
            outcome.kind = kind
            return outcome
        }
        // Each text on its own, the others replaced by known-good values.
        let goodLocation = shape.requiresLocation ? "/x" : nil
        func probe(_ field: ActionField, location: String? = nil, challenge: String? = nil, body: String? = nil) {
            let alone = PresetResponse(preset: preset, body: body, location: location ?? goodLocation, challenge: challenge)
            if let found = Self.issue(.returnPreset(alone), limits) { outcome.issues[field] = found }
        }
        if let location { probe(.presetLocation, location: location) }
        if let challenge { probe(.presetChallenge, challenge: challenge) }
        if let body { probe(.presetBody, body: body) }
        if outcome.issues.isEmpty, let found = Self.issue(kind, limits) { outcome.issues[.presetLocation] = found }
        return outcome
    }

    // MARK: record actions

    private func buildMark(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let background = mark.background.trimmingCharacters(in: .whitespaces)
        let foreground = mark.foreground?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let text = mark.text.nilIfEmpty
        let valid = MarkPalette.presets[0].lightHex
        if let found = Self.issue(.mark(MarkAction(background: background)), limits) { outcome.issues[.markColor] = found }
        if let foreground, let found = Self.issue(.mark(MarkAction(background: valid, foreground: foreground)), limits) {
            outcome.issues[.markForeground] = found
        }
        if let text, let found = Self.issue(.mark(MarkAction(background: valid, text: text)), limits) {
            outcome.issues[.markText] = found
        }
        // A text colour is painted on a coloured row: with no background colour of its own it has nothing to sit on.
        if MarkAction.isNoColorChoice(background), let foreground, FlowMark.normalizedHex(foreground) != nil {
            outcome.warnings = [.markTextColorNeedsBackground]
        }
        outcome.kind = .mark(
            MarkAction(
                background: FlowMark.normalizedHex(background) ?? background,
                foreground: foreground.map { FlowMark.normalizedHex($0) ?? $0 }, text: text))
        return outcome
    }

    private func buildComment(_ limits: RulesLimits) -> Outcome {
        var outcome = Outcome()
        let mode = comment.mode.engineMode
        func check(_ field: ActionField, _ action: CommentAction) {
            if outcome.issues[field] == nil, let found = Self.issue(.comment(action), limits) { outcome.issues[field] = found }
        }
        switch comment.mode {
        case .clear:
            outcome.kind = .comment(CommentAction(mode: mode))
            return outcome
        case .set, .append, .addIfMissing:
            check(.commentText, CommentAction(mode: mode, text: comment.text))
            outcome.kind = .comment(CommentAction(mode: mode, text: comment.text))
        case .findReplace, .regex:
            check(.commentFind, CommentAction(mode: mode, text: comment.text))
            check(.commentReplacement, CommentAction(mode: .findReplace, text: "x", replacement: comment.replacement))
            outcome.kind = .comment(
                CommentAction(
                    mode: mode, text: comment.text, replacement: comment.replacement, caseSensitive: comment.caseSensitive))
        }
        return outcome
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
