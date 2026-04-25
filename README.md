## Repo contents

- `README.md` (this file) — full 10-section research deliverable.
- `swiftlint-rule/DeferBeforeUnstructuredTaskRule.swift` — paste-ready SwiftLint rule sketch.
- `swiftlint-rule/rule-request-issue.md` — paste-ready body for a realm/SwiftLint rule-request issue.
- `swift-forums/pitch.md` — draft Swift Forums pitch post that links back to this repo.

# Context

The user asked whether the Swift compiler should warn on a recurring bug shape:

```swift
func login() {
    isLoading = true
    defer { isLoading = false }
    Task { await doSomethingAsync() }
}
```

`defer` runs when `login()` returns (immediately, since `Task {}` only schedules), but the developer's intent is almost certainly "flip `isLoading` back when the work finishes." The user requested a thorough, skeptical investigation across Swift docs, Swift Forums, swift-evolution, and the swiftlang/swift compiler, plus a heuristic, patch sketch, tests, PR draft, and a fallback if the compiler is the wrong venue.

**Top-line conclusion: this should NOT be a Swift compiler change. It belongs in SwiftLint as a SwiftSyntax-based rule.** Section 10 is the operative section. Sections 1–9 document the compiler path for completeness because the user asked for it explicitly.

# 1. Research Summary

**Confirmed semantics.** `defer` runs when the lexical scope it sits in exits. `Task { ... }` constructs an unstructured task and returns immediately — the closure body runs asynchronously, decoupled from the enclosing function's lifetime. This is documented and intended. Konrad Malawski (Swift core team) on the Swift Forums: "I don't recommend wrapping in `Task{}` as that dramatically changes semantics and guarantees — the cleanup will not be guaranteed to complete before the function returns" (https://forums.swift.org/t/async-support-in-defer-blocks/69455).

**Prior art / discussion of this exact misuse.**
- **SE-0493 "Support `async` calls in `defer` bodies"** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md). The motivation section names exactly this pattern and the workaround of "spawn a new top-level Task to perform the cleanup." SE-0493 fixes the underlying expressivity gap. **It introduces no new diagnostic for the sync-function antipattern.** Swift authors chose to fix the root cause rather than warn on the workaround.
- **SE-0520 "Discardable result use in Task initializers"** (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0520-discardableresult-task-initializers.md, accepted; announcement at https://forums.swift.org/t/accepted-se-0520-discardable-result-use-in-task-initializers/86159). Best precedent for "warn on suspicious unstructured-Task usage." It adds a warning only for `Task { throws in ... }` whose result is dropped. Notice how narrow it is: only throwing tasks, only dropped result. The Swift project's bar for adding a Task-related warning is high and tight.
- **Swift Forums "`defer` in async Task & actor isolation"** (https://forums.swift.org/t/defer-in-async-task-actor-isolation/57960). John McCall (compiler team) participates; no diagnostic suggested.
- **SE-0493 review thread** (https://forums.swift.org/t/se-0493-support-async-calls-in-defer-bodies/82293). Searched specifically for "warn on defer-before-Task-in-sync-func." Not raised.
- **Donny Wals** (https://www.donnywals.com/what-is-defer-in-swift/) and **Swift by Sundell** (https://www.swiftbysundell.com/articles/using-defer-within-async-and-throwing-contexts/) flag the antipattern as folklore. **No swiftlang/swift issue or pitch asks the compiler to flag it.**
- **SwiftLint** has `inert_defer` and `unhandled_throwing_task`, but no rule targeting "defer-then-Task in sync function" (https://realm.github.io/SwiftLint/rule-directory.html).

**Could not confirm:** precise file/line where the check would wire into Sema (see §6).

# 2. Minimal Repro Matrix

| Case | Actual behavior | Probable intent | Warn? | Justification |
|---|---|---|---|---|
| A. `defer { print("done") }` then `Task { await work() }` (sync func) | "done" prints immediately | "done" after work | depends | Pure side effect. Could be either bug or intentional. |
| B. `lock.lock(); defer { lock.unlock() }` then `Task { await work() }` | Unlock immediately; Task runs unprotected | Hold lock across work | yes-ish | Bug, but locks aren't typically captured into the `Task`. Real lock APIs don't compose with unstructured Tasks. |
| C. `isLoading = true; defer { isLoading = false }` then `Task { await work() }` | Flag flips false immediately | Flag flips false after work | yes | Canonical bug. defer body and Task body both touch the same mutable state. |
| D. Same as C but the function is `async` and awaits `work()` directly | Flag flips after work — correct | Same | no | Correct usage. Must not warn. |
| E. `let t = Task { ... }; defer { print("leaving") }; _ = t` | "leaving" on func return; Task continues | Log on scope exit | no | defer is intentionally about scope exit; Task is captured. |
| F. `defer { cleanup() }` then `Task.detached { await work() }` | cleanup runs immediately | depends | depends | Same shape as A/C; treat identically to unstructured-`Task.init` for diagnostic purposes. |

The matrix shows the heuristic must condition on **shared mutable state between the defer body and the Task body**, not just adjacency.

# 3. Candidate Diagnostic Heuristic

Single, narrow, high-confidence shape. Attach to the **`defer`** statement (it's the construct that misbehaves relative to expectation). The `Task` is the symptom.

**AST shape required (all must hold):**
1. `DeferStmt` D inside a function or closure F.
2. F is **synchronous** (no `async` effect).
3. F's body contains, at the same lexical scope as D, a `Task.init` or `Task.detached` call expression whose closure argument is async.
4. The `Task` closure's return value is discarded (no `let t = Task { ... }`).
5. **Shared-state filter:** D's body assigns to (or calls a setter on) a storage location L, AND the `Task`'s closure body also reads or writes L. Implement as: collect l-value `VarDecl`s referenced in D, intersect with `VarDecl`s referenced anywhere in the `Task` closure. Non-empty intersection = warn.
6. Only simple assignment patterns in the defer (single statement, `x = literal-or-simple-expr`). Excludes lock-like APIs (method calls). Accept some false negatives to crush false positives.

**Diagnostic ID:** `warn_defer_runs_before_task_completes`

**Primary text (defer site):**
> warning: 'defer' will run when the enclosing scope exits, which is before the work in the unstructured 'Task' on line N completes; the deferred assignment to 'isLoading' is observed before that work finishes

**Note (Task site):**
> note: this 'Task' returns immediately; its body runs asynchronously after the enclosing function has returned

**Fix-its (textual, two):**
1. *Move cleanup into the Task.* Rewrite to `Task { defer { isLoading = false }; await work() }`. Caveat: changes actor isolation.
2. *Make function async.* Annotate F with `async` and replace `Task { await work() }` with `await work()`. Only viable when callers can be async.

# 4. False Positive Analysis

**Case B (locks).** Filter step 5 only fires on assignments. NSLock-style `lock.unlock()` is a method call, not an assignment, and the lock isn't typically read inside the `Task` closure. Heuristic does **not** fire on lock release — silently correct.

**Other plausible false positives:**
- Logging defer (case A). No assignment. Filter rejects.
- Computed-property side effects with no overlap. Filter rejects.
- `didSet` pings on a flag the Task doesn't read. Filter rejects.
- Intentional "kick off and forget" with a flag flip on entry/exit only locally observable. **This is wrong.** Mitigation: warning is suppressible by `_ = Task { ... }` or by moving the defer outside the function.

**Honest verdict.** The shared-state filter does kill the obvious false positives, but it imposes flow analysis (collect l-value decls in defer, free decls in Task closure, intersect) on every sync function with a defer, and the *high-confidence* set is narrow — essentially "boolean flag flip plus matching read/write in the Task." Signal-to-implementation ratio is poor for a compiler check. SwiftLint can do exactly this analysis with SwiftSyntax in 50 lines and an opt-in flag.

# 5. Playground-Style Fixes

**Rewrite 1: defer goes inside the Task.**
```swift
func login() {
    isLoading = true
    Task {
        defer { isLoading = false }
        await doSomethingAsync()
    }
}
```
Tradeoffs: simplest. Pitfalls: closure may capture `self` strongly; actor isolation differs inside the Task closure; thrown errors silently dropped by the unstructured Task.

**Rewrite 2: function becomes async.**
```swift
func login() async {
    isLoading = true
    defer { isLoading = false }
    await doSomethingAsync()
}
```
Tradeoffs: cleanest. Cleanup ordered and guaranteed. Forces caller contagion, often correct. SwiftUI view-action sites become `Task { await viewModel.login() }` at the call site, which is the *one* place where unstructured Task is correct because the UI event loop is fire-and-forget there. SE-0493 lets you use `await` inside the defer too.

Rewrite 2 is almost always the right answer.

# 6. Compiler Exploration Notes

I searched swiftlang/swift but did not directly read source files at line precision. All locations below are **candidate, unverified** unless noted.

- **`include/swift/AST/DiagnosticsSema.def`** (https://github.com/swiftlang/swift/blob/main/include/swift/AST/DiagnosticsSema.def). Confirmed location of Sema diagnostic definitions. New `WARNING(warn_defer_runs_before_task_completes, ...)` and `NOTE(note_defer_unstructured_task_site, ...)` lines belong here. Verified existence.
- **`lib/Sema/MiscDiagnostics.cpp`** (https://github.com/swiftlang/swift/blob/main/lib/Sema/MiscDiagnostics.cpp). Confirmed location of post-typecheck `DiagnoseWalker` for flow-insensitive AST-shape checks. Strongest candidate for wiring `walkToStmtPre(DeferStmt*)` or extending the function-body walker. Candidate, unverified for the precise insertion point.
- **`lib/Sema/TypeCheckStmt.cpp`** (https://github.com/swiftlang/swift/blob/main/lib/Sema/TypeCheckStmt.cpp). Contains `isDefer()` helper and existing defer-related diagnostics. Plausible alternative home. Candidate, unverified.
- **SE-0520 implementation commit on swiftlang/swift.** Closest existing analog: special-cased AST recognition of `Task.init` / `Task.detached` / `Task.immediate` initializer calls in expression-statement position with a discarded result. The SE-0520 PR is **the single most relevant precedent.** A real implementer would locate it via `git log --grep "SE-0520"` and graft the new check at the same site.

# 7. Patch / Patch Sketch

Sketch only.

```
include/swift/AST/DiagnosticsSema.def
+ WARNING(warn_defer_runs_before_task_completes, none,
+   "'defer' runs when the enclosing scope exits, before the unstructured "
+   "'Task' on line %0 completes; the deferred change to %1 is observed "
+   "before that asynchronous work finishes", (unsigned, DeclName))
+ NOTE(note_defer_unstructured_task_site, none,
+   "this unstructured 'Task' returns immediately; its body runs after "
+   "the enclosing function has returned", ())

lib/Sema/MiscDiagnostics.cpp
  bool walkToStmtPre(Stmt *S) override {
    if (auto *D = dyn_cast<DeferStmt>(S)) {
      checkDeferBeforeUnstructuredTask(D);
    }
    return BaseDiagnosticWalker::walkToStmtPre(S);
  }

  void checkDeferBeforeUnstructuredTask(DeferStmt *D) {
    // 1. Bail if the enclosing AbstractFunctionDecl/closure is async.
    // 2. Walk D's body; collect l-value VarDecls. Bail if empty or > 2.
    // 3. Walk later same-scope statements for an ExprStmt whose expression
    //    is an ApplyExpr to a Task or Task.detached initializer (reuse
    //    SE-0520's recognizer). Skip if result is bound (let t = Task{...}).
    // 4. Walk that Task's trailing closure body; collect referenced VarDecls.
    // 5. If the two decl sets intersect, emit warn_defer_runs_before_task_completes
    //    at D's loc with note_defer_unstructured_task_site at the Task's loc.
  }
```

Diagnostic group: new group `DeferBeforeTask`. Opt-in via `-Wwarning DeferBeforeTask` initially; promote later if false-positive rate stays low.

# 8. Tests

`test/Sema/defer_before_task.swift`:

```swift
// RUN: %target-typecheck-verify-swift -strict-concurrency=complete

@MainActor
class VM {
  var isLoading = false
  func doSomethingAsync() async {}

  // Case C: positive — should warn.
  func loginC() {
    isLoading = true
    defer { isLoading = false } // expected-warning {{'defer' runs when the enclosing scope exits, before the unstructured 'Task'}}
    Task { // expected-note {{this unstructured 'Task' returns immediately}}
      await self.doSomethingAsync()
      _ = self.isLoading
    }
  }

  // Case A: print only — no shared state, no warning.
  func loginA() {
    defer { print("done") }
    Task { await self.doSomethingAsync() }
  }

  // Case D: async function awaiting directly — no warning.
  func loginD() async {
    isLoading = true
    defer { isLoading = false }
    await doSomethingAsync()
  }

  // Case E: Task is captured — no warning.
  func loginE() {
    let t = Task { await self.doSomethingAsync() }
    defer { print("leaving") }
    _ = t
  }

  // Case F: Task.detached — same shape as C, should warn.
  func loginF() {
    isLoading = true
    defer { isLoading = false } // expected-warning {{'defer' runs when the enclosing scope exits, before the unstructured 'Task'}}
    Task.detached { // expected-note {{this unstructured 'Task' returns immediately}}
      await self.doSomethingAsync()
      _ = await self.isLoading
    }
  }

  // No-overlap: defer touches a different decl than Task body — no warning.
  func loginNoOverlap() {
    var localFlag = true
    defer { localFlag = false }
    Task { await self.doSomethingAsync() }
    _ = localFlag
  }
}
```

Add closure coverage and a test verifying the warning is silenced by storing the Task in a `let`.

# 9. PR Draft

**Title:** `[Sema] Warn when defer mutates state read by an immediately-following unstructured Task`

**Description.**

In a synchronous function or closure, `defer { x = ... }` followed by `Task { await ... ; ... use x ... }` is a recurring bug: the defer runs synchronously when the enclosing scope exits, before the Task body runs, so the deferred state change is observed inverted from intent. Canonical example: loading-flag management:

```swift
func login() {
    isLoading = true
    defer { isLoading = false }
    Task { await doSomethingAsync() }
}
```

`isLoading` is observed as `false` by everything outside the function the moment `login()` returns. Intended behavior requires either moving the defer inside the Task closure, or making `login()` async and awaiting directly.

This PR adds a narrow Sema warning:

- enclosing function/closure is sync;
- `DeferStmt` at lexical scope mutates one or more decls;
- same-scope expression-statement initializes `Task` or `Task.detached` (recognized via SE-0520's machinery) whose result is discarded;
- the Task closure body references at least one of the decls mutated by the defer.

Diagnostic: `warn_defer_runs_before_task_completes` with a note at the `Task` initializer. Textual fix-it suggestions describe the two safe rewrites.

**Known limitations.** Logging defers not flagged (by design). Method-call cleanup not flagged (NSLock-style); intentional. Shared-state check is syntactic decl-reference intersection; indirect mutation through method calls is missed.

**False-positive discussion.** Intentional "kick off work and immediately reset UI flag" is rare but real. Suppressed by `_ = Task { ... }` or by moving the defer out of the function. Rolling out under named warning group `DeferBeforeTask` lets adopters silence selectively.

# 10. If Not Compiler-Worthy, Best Alternative

This is the operative section. **Ship as a SwiftLint rule, not a compiler diagnostic.**

Reasons:

1. **The Swift project's own bar.** SE-0520 added a single, narrow, strongly-motivated warning specifically about Task misuse, and only after a community proposal and language steering group review. A "smart" defer + Task warning that depends on shared-state intersection is a style/lint check, not a soundness check.
2. **SE-0493 fixed the root cause.** With async defer landing, the *correct* answer is "make the function async and await directly," and `defer` handles cleanup correctly with no compiler help. The misuse pattern degrades naturally as codebases adopt async APIs.
3. **The heuristic is opinionated.** Compiler warnings ship to every Swift user globally. SwiftLint rules are opt-in, configurable, and the right venue for "looks like a bug shape in 95% of cases" judgments.
4. **Implementation cost.** SwiftSyntax visitor in a few dozen lines, ships in days. Compiler-side equivalent requires proposal review, multi-release evolution, and ecosystem-wide false-positive cost.

**Concrete SwiftLint rule sketch.**

`.swiftlint.yml`:
```yaml
opt_in_rules:
  - defer_before_unstructured_task

defer_before_unstructured_task:
  severity: warning
```

`Source/SwiftLintBuiltInRules/Rules/Lint/DeferBeforeUnstructuredTaskRule.swift`:

```swift
import SwiftSyntax

@SwiftSyntaxRule(optIn: true)
struct DeferBeforeUnstructuredTaskRule: Rule {
    static let description = RuleDescription(
        identifier: "defer_before_unstructured_task",
        name: "Defer Before Unstructured Task",
        description: """
            A 'defer' that mutates state read by a sibling unstructured \
            'Task' will run before the Task's async work completes, \
            inverting the developer's likely intent.
            """,
        kind: .lint,
        nonTriggeringExamples: [
            Example("func f() async { isLoading = true; defer { isLoading = false }; await work() }"),
            Example("func f() { defer { print(\"done\") }; Task { await work() } }"),
            Example("func f() { let t = Task { await work() }; defer { print(\"leaving\") }; _ = t }")
        ],
        triggeringExamples: [
            Example("""
                func login() {
                    isLoading = true
                    ↓defer { isLoading = false }
                    Task { await doSomethingAsync(); _ = isLoading }
                }
                """)
        ]
    )
}

private extension DeferBeforeUnstructuredTaskRule {
    final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
        override func visitPost(_ node: CodeBlockSyntax) {
            guard !isEnclosingAsync(node) else { return }
            let stmts = node.statements
            for (idx, item) in stmts.enumerated() {
                guard let deferStmt = item.item.as(DeferStmtSyntax.self) else { continue }
                let mutatedNames = collectAssignedIdentifiers(in: deferStmt.body)
                guard !mutatedNames.isEmpty else { continue }
                for laterItem in stmts.dropFirst(idx + 1) {
                    guard let taskCall = unstructuredTaskInit(in: laterItem),
                          isResultDiscarded(laterItem) else { continue }
                    let referenced = collectReferencedIdentifiers(in: taskCall.trailingClosure)
                    if !mutatedNames.isDisjoint(with: referenced) {
                        violations.append(deferStmt.deferKeyword.positionAfterSkippingLeadingTrivia)
                        break
                    }
                }
            }
        }
    }
}
```

Helpers (`collectAssignedIdentifiers`, `collectReferencedIdentifiers`, `unstructuredTaskInit`, `isEnclosingAsync`) are straightforward SwiftSyntax walks. SwiftLint's existing `unhandled_throwing_task` rule is the near-identical Task-recognizer reference.

**Action plan.**

1. Open a rule-request issue at https://github.com/realm/SwiftLint/issues describing the pattern, the matrix from §2, and the heuristic from §3.
2. Implement the rule following `UnhandledThrowingTaskRule.swift` as the structural template.
3. Add tests at `Tests/BuiltInRulesTests/DeferBeforeUnstructuredTaskRuleTests.swift` mirroring the matrix.
4. If the rule earns its keep with low false-positive reports across a few releases, *then* it has the empirical track record to justify a Swift Evolution pitch for the compiler. Not before.

**Critical files (SwiftLint path):**
- `Source/SwiftLintBuiltInRules/Rules/Lint/DeferBeforeUnstructuredTaskRule.swift` (new)
- `Source/SwiftLintBuiltInRules/Rules/Lint/UnhandledThrowingTaskRule.swift` (reference template)
- `Tests/BuiltInRulesTests/DeferBeforeUnstructuredTaskRuleTests.swift` (new)

**Critical files (compiler path, if pursued against this recommendation):**
- `include/swift/AST/DiagnosticsSema.def`
- `lib/Sema/MiscDiagnostics.cpp`
- `lib/Sema/TypeCheckStmt.cpp`
- `test/Sema/defer_before_task.swift` (new)
- SE-0520 implementation commit (locate via `git log --grep "SE-0520"` in a swiftlang/swift checkout) — read first.

# Verification

This is a research deliverable, not a code change against any local repo. Verification:

1. **Citations resolve.** Open each linked URL in §1 and confirm: SE-0493 motivation section names the Task-cleanup workaround; SE-0520 announcement text matches the bespoke-Task-warning description; Malawski quote is on the linked Forums thread.
2. **Heuristic sanity.** Run the §2 matrix mentally against §3's filter. Cases A, D, E, no-overlap must NOT trigger. Cases C, F MUST trigger. Case B MUST NOT trigger under the assignment-only filter.
3. **SwiftLint scaffold compiles.** When implementing §10, drop the rule file in alongside `UnhandledThrowingTaskRule.swift` and run `swift test` from the SwiftLint repo root; triggering and non-triggering examples in `RuleDescription` are self-checking.
