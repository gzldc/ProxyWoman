# Task 7 report: RulesEngine snapshot requirements

Commit: 848b872 feat(rules): snapshot requirements for body, app and completion conditions

## RED
Command: `perl -e 'alarm 1800; exec @ARGV' swift test --filter SnapshotRequirementsTests --jobs 2 --disable-index-store -debug-info-format none`
Output: compile failure, 37 errors: `cannot find 'SnapshotRequirements' in scope`, `value of type 'RuleSnapshot' has no member 'requirements'`. Log: scratchpad `task7-red.log`.

## GREEN
Focused: 11 tests in SnapshotRequirementsTests passed (run twice, second time in foreground).
G-PKG(RulesEngineTests): 898 tests in 57 suites passed (887 before + 11 new; includes EvaluatorOracleTests, unchanged).
G-BUILD (`-Xswiftc -warnings-as-errors`): Build complete, 0 warnings.
Leftover processes: none (`pgrep` clean).

## Changes
- `Sources/RulesEngine/SnapshotRequirements.swift` (new): `SnapshotRequirements` and `RuleSnapshot.requirements`, as given in D2.
- `Sources/RulesEngine/Rule.swift`: `EvaluationOrderCache.Storage` gains a `requirements` slot and `requirements(_:)` method, mirroring `canHide`. `orderCache` changed from `private var` to `private(set) var` so the extension in the new file can read it.
- `Sources/RulesEngine/RuleSnapshotProvider.swift`: `init` and `publish` warm `requirements` next to `evaluationOrder`.
- `Tests/RulesEngineTests/SnapshotRequirementsTests.swift` (new): 11 tests covering all names in the brief.

## Gates not run
- G-END (full `swift test --no-parallel`, then build, then pgrep). The first background attempt was cut off mid-compile and produced no result; the foreground run requested by the controller covered focused, package and build only. Full-suite G-END is still outstanding for this task (the plan lists it at the RulesEngine phase close).

## Concerns
- `requirementsAreComputedOncePerSnapshotValue` checks values across a copy and a mutated copy; it does not count how many times the closure runs (the cache is private and not observable). The "once" property is by construction, not directly tested.
- The `requirements` cache slot is only warmed in `init` and `publish`; a snapshot created elsewhere computes it lazily, which is correct but not warmed.
