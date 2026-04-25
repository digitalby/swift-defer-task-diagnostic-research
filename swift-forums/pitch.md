# Pitch: warn on `defer` immediately preceding an unstructured `Task` in a sync function

**Category:** Discussion → Pitches (or Evolution → Pitches if escalated later)

**Status:** pre-pitch, gauging interest. SwiftLint rule prototyped first (see end). Not a Swift Evolution proposal yet.

---

## Motivation

The following is a recurring bug shape in real Swift code:

```swift
func login() {
    isLoading = true
    defer { isLoading = false }
    Task {
        await doSomethingAsync()
    }
}
```

The author's intent is "flip `isLoading` back to `false` when the async work finishes." The actual behavior is that `isLoading` flips to `false` the moment `login()` returns, since `Task { ... }` schedules and returns immediately. The Task body still runs, but anything observing `isLoading` (a SwiftUI binding, a downstream component) sees the flag inverted from intent.

This is documented and intended language behavior. From Konrad Malawski on the forums (https://forums.swift.org/t/async-support-in-defer-blocks/69455): "I don't recommend wrapping in `Task{}` as that dramatically changes semantics and guarantees, the cleanup will not be guaranteed to complete before the function returns." Folklore-known. Not flagged anywhere.

The compiler does not warn. SwiftLint does not warn. The pattern survives in tutorials, blog posts, and production codebases.

## Why now

Two pieces of recent evolution are the relevant context:

- **SE-0493 "Support `async` calls in `defer` bodies"** removes the pretext for using `Task { ... }` as an async-cleanup workaround. The right rewrite (`func login() async { defer { isLoading = false }; await ... }`) is now first-class.
- **SE-0520 "Discardable result use in Task initializers"** is the precedent. Swift recently added a narrow Task-shape warning for the throwing-task footgun (`Task { throws in ... }` whose result is dropped silently swallows errors). That warning was a single, targeted, judgment-call diagnostic about an unstructured-Task footgun. Structurally identical to what's pitched here.

The shape we want to flag is similar in spirit to SE-0520: a pattern where the surface syntax suggests one ordering and the runtime delivers another.

## Proposed diagnostic

Single, narrow, high-confidence shape. Attach to the `defer` (the construct that misbehaves relative to expectation). The `Task` is the symptom.

Trigger when ALL hold:

1. `DeferStmt` inside a synchronous function or closure.
2. The defer body contains one or two simple assignments (`x = ...`, `self.x = ...`).
3. A sibling statement at the same scope is a discarded `Task { ... }` or `Task.detached { ... }` initializer (use the SE-0520 recognizer).
4. The Task's trailing closure references at least one of the identifiers assigned in the defer.

Diagnostic text (defer site):

> warning: 'defer' will run when the enclosing scope exits, before the work in the unstructured 'Task' on line N completes; the deferred change to `isLoading` is observed before that work finishes

Note (Task site):

> note: this 'Task' returns immediately; its body runs asynchronously after the enclosing function has returned

Two textual fix-it suggestions: (a) move the defer inside the Task closure; (b) make the function `async` and `await` directly.

## False-positive analysis

The shared-state filter (step 4) is the load-bearing piece. Without it the warning would be too noisy.

- `defer { print("done") }` then `Task { await work() }`, does not trigger (no assignment).
- `lock.lock(); defer { lock.unlock() }` then `Task { await work() }`, does not trigger (lock release is a method call, not an assignment, and the Task body doesn't typically reference the lock).
- `let t = Task { await work() }; defer { print("leaving") }; _ = t`, does not trigger (Task is captured).
- `func f() async { isLoading = true; defer { isLoading = false }; await work() }`, does not trigger (function is async).

The remaining false-positive class is intentional "kick off work and immediately reset a flag." Rare in practice. Suppressible by `_ = Task { ... }` or by moving the defer outside the function.

## Why scope it this narrowly

I deliberately exclude method-call cleanup (lock release, observer removal) because the heuristic cannot tell intent from a method call. Accepting false negatives there to crush false positives elsewhere. The single highest-confidence, highest-impact case is "boolean flag flip plus a matching read in the Task body," which covers the canonical loading-flag bug almost completely.

## Alternatives considered

1. **Lint-only.** The natural alternative is a SwiftLint rule. I prototyped exactly that (see below). If the answer is "lint-only," that's a defensible position. The argument against is reach: SwiftLint adoption is a fraction of the ecosystem and Xcode's default sourcekit-lsp diagnostics aren't.
2. **Detect at the `Task` site.** Possible, but the construct that misbehaves relative to author expectation is the `defer`. A diagnostic at the Task obscures where the fix belongs.
3. **Detect any `defer` followed by any `Task`, no shared-state check.** Too noisy. The shared-state intersection is what makes this a high-precision warning rather than a stylistic nag.

## Prototype

I built this as a SwiftLint rule first, partly to validate the heuristic and partly to gather adoption data before pitching the compiler. Sketch (full source in the linked research repo):

```swift
@SwiftSyntaxRule(optIn: true)
struct DeferBeforeUnstructuredTaskRule: Rule {
    // visitor: for each CodeBlockSyntax,
    //   skip if enclosing context is async,
    //   for each DeferStmt at this scope,
    //     collect simple assignment LHS identifier set M (size 1..2),
    //     scan later sibling statements for a discarded Task/Task.detached init,
    //     collect identifier references R inside its trailing closure,
    //     if M ∩ R is non-empty, flag the defer keyword.
}
```

Reference template inside SwiftLint: `Source/SwiftLintBuiltInRules/Rules/Lint/UnhandledThrowingTaskRule.swift`. The Task-init recognizer pattern there transfers directly.

Repository (research summary, repro matrix, false-positive analysis, full SwiftLint rule source, test cases): https://github.com/digitalby/swift-defer-task-diagnostic-research

## Open questions for the community

1. Is the shared-state intersection check acceptable as a Sema-time analysis cost on every sync function with a defer, or does this need to live in a separate pass?
2. Should `Task.immediate` (introduced separately) be treated identically to `Task.init` and `Task.detached` for this check?
3. Is the diagnostic group `DeferBeforeTask` worth introducing on its own, or should it ride under an existing concurrency-warnings group?
4. Anyone aware of a real false-positive case the shared-state filter misses?

If there's interest, next steps are:

1. Land the SwiftLint rule, gather adoption data and false-positive reports across a few real codebases (Vapor, swift-nio, swift-package-manager, a handful of SwiftUI apps).
2. Return here with empirical numbers.
3. Write a real swift-evolution proposal if the data supports it.
