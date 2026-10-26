# R4 Task 2 report

Pure transforms: URLEditing, QueryEditing, CookieEditing (+ CookieEditResult, URLEditFailure, LiteralReplace helper).
Also added `RegexPattern.replacingMatches(in:template:allowance:)` (RegexPattern.swift, additive) because RegexPattern had no template replace under the shared allowance; same breaker/allowance semantics as `matches(_:allowance:)`.

RED: tests written first; `swift test --filter 'URLEditingTests|QueryEditingTests|CookieEditingTests'` failed to compile ("cannot find 'URLEditing' in scope").
GREEN: same filter -> 43 tests in 3 suites passed.
G-PKG RulesEngineTests: 988 tests in 65 suites passed. G-BUILD (-warnings-as-errors): Build complete.

Notes/decisions: regex inputTooLong in cookies = edit skipped silently (no outcome code exists); invalid regex compile in URL -> .patternDisabled, in cookie -> patternProblem .patternDisabled. Request-side `set` collapses duplicate names; response-side `set` edits every matching Set-Cookie. New request Cookie is appended at end of headers.

## Fix round 1
- Byte semantics: added `bytesEqual` (utf8.elementsEqual) in URLEditing.swift; used for name matches, value/segment/raw change detection in CookieEditing, QueryEditing, URLEditing. Tests `namesAndChangesAreByteWise` (Kelvin sign, NFC vs NFD, canonically-equal set is applied) and a URL NFC/NFD findReplace test.
- New RegexReplaceTests (multi match, empty match, non-BMP, $-template, allowance consumption, exhausted allowance, input cap, .whole mode no-op). `replacingMatches` returns .noMatch on .whole; shared preamble factored into `grantTime(for:from:)` used by `matches(_:allowance:)` too.
- Oversize and unreadable cookie regex pinned as silent skip (R3 convention: unreadable => never applies, no outcome). URL regex compile failure now `.invalidResult` (was .patternDisabled).
- Gates: focused 57 tests pass; RulesEngineTests (incl. EvaluatorOracleTests) 1002 tests pass; build -warnings-as-errors complete.

## Fix round 2
- All separator search/split now on UTF-8 bytes via `ByteText` (URLEditing.swift): URL parse, query (`?` `&` `=`), cookie (`;` `=`); header-name match is ASCII-lowercase bytes; NUL sentinel replaced by optional check; response guard extracted to `unchanged`.
- Tests: combining mark after `&`, `;`, `?` in query/cookie/URL; Kelvin-sign header name. Note: "/" + combining mark is rejected by the existing HTTPMutationValidator.pathError (`hasPrefix("/")` is Character-based) - safe reject, validator untouched.
- Gates: RulesEngineTests (incl. EvaluatorOracleTests) 1006 pass; build -warnings-as-errors complete.
