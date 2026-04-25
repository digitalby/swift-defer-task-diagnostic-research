# Rule request: `defer_before_unstructured_task`

## Pattern

In a synchronous function, `defer { x = ... }` followed by `Task { await ... ; ... uses x ... }` is a recurring bug. The deferred change runs the moment the function returns (before the Task body has a chance to run), so the cleanup is observed inverted from intent.

Canonical example (loading-flag management in SwiftUI view models):

```swift
func login() {
    isLoading = true
    defer { isLoading = false }
    Task {
        await doSomethingAsync()
    }
}
```

`isLoading` flips to `false` immediately when `login()` returns, while `doSomethingAsync()` is still running.

## Why a rule

- The pattern is widespread in tutorials, SwiftUI sample code, and production. Folklore-known but not flagged anywhere.
- The compiler does not warn (verified against current main).
- SwiftLint already has `unhandled_throwing_task` and `inert_defer`. This rule sits naturally between them.
- SE-0493 (async-defer) and SE-0520 (discardable Task) are the relevant Swift Evolution context, neither addresses this shape.

## Proposed heuristic (narrow, opt-in)

Trigger when ALL hold:

1. `DeferStmt` inside a synchronous function or closure.
2. The defer body contains one or two simple assignments to identifiers (filters out logging-only defers and lock release).
3. A sibling statement at the same scope is a discarded `Task { ... }` or `Task.detached { ... }` initializer.
4. The Task's trailing closure references at least one of the identifiers assigned in the defer.

Anything outside this shape does not warn. False-negative-friendly by design.

## Negative examples (must NOT warn)

```swift
func f() async {                        // async + await directly: correct
    isLoading = true
    defer { isLoading = false }
    await work()
}

func f() {                              // logging-only defer
    defer { print("done") }
    Task { await work() }
}

func f() {                              // Task is captured
    let t = Task { await work() }
    defer { print("leaving") }
    _ = t
}

func f() {                              // no shared state
    var localFlag = true
    defer { localFlag = false }
    Task { await work() }
    _ = localFlag
}
```

## Positive examples (must warn)

```swift
func login() {
    isLoading = true
    defer { isLoading = false }          // <- triggers
    Task {
        await doSomethingAsync()
        _ = isLoading
    }
}

func login() {
    isLoading = true
    defer { isLoading = false }          // <- triggers
    Task.detached {
        await doSomethingAsync()
        _ = await self.isLoading
    }
}
```

## Suggested fix-its (textual)

1. Move the `defer` inside the `Task` closure.
2. Make the enclosing function `async` and `await` the work directly.

## Reference template

`Source/SwiftLintBuiltInRules/Rules/Lint/UnhandledThrowingTaskRule.swift` is structurally near-identical (recognizes `Task` initializers and inspects their trailing closures).

A working sketch is in this repo at `swiftlint-rule/DeferBeforeUnstructuredTaskRule.swift`.

## Severity / opt-in

Default `warning`, opt-in. After adoption data accumulates, the heuristic could feed a Swift Forums pitch for a compiler-side diagnostic.
