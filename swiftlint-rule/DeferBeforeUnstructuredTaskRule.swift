import SwiftSyntax

@SwiftSyntaxRule(optIn: true)
struct DeferBeforeUnstructuredTaskRule: Rule {
    var configuration = SeverityConfiguration<Self>(.warning)

    static let description = RuleDescription(
        identifier: "defer_before_unstructured_task",
        name: "Defer Before Unstructured Task",
        description: """
            A 'defer' that mutates state read or written by a sibling \
            unstructured 'Task' will run when the enclosing scope exits, \
            before the Task's async work completes. This inverts the \
            developer's likely intent (run the cleanup after the work).
            """,
        kind: .lint,
        nonTriggeringExamples: [
            Example("""
                func f() async {
                    isLoading = true
                    defer { isLoading = false }
                    await work()
                }
                """),
            Example("""
                func f() {
                    defer { print("done") }
                    Task { await work() }
                }
                """),
            Example("""
                func f() {
                    let t = Task { await work() }
                    defer { print("leaving") }
                    _ = t
                }
                """),
            Example("""
                func f() {
                    var localFlag = true
                    defer { localFlag = false }
                    Task { await work() }
                    _ = localFlag
                }
                """)
        ],
        triggeringExamples: [
            Example("""
                func login() {
                    isLoading = true
                    ↓defer { isLoading = false }
                    Task {
                        await doSomethingAsync()
                        _ = isLoading
                    }
                }
                """),
            Example("""
                func login() {
                    isLoading = true
                    ↓defer { isLoading = false }
                    Task.detached {
                        await doSomethingAsync()
                        _ = await self.isLoading
                    }
                }
                """)
        ]
    )
}

private extension DeferBeforeUnstructuredTaskRule {
    final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
        override func visitPost(_ node: CodeBlockSyntax) {
            guard !isEnclosingAsync(node) else { return }
            let stmts = Array(node.statements)
            for (idx, item) in stmts.enumerated() {
                guard let deferStmt = item.item.as(DeferStmtSyntax.self) else { continue }
                let mutated = collectAssignedIdentifiers(in: deferStmt.body)
                guard !mutated.isEmpty, mutated.count <= 2 else { continue }
                for laterItem in stmts.dropFirst(idx + 1) {
                    guard isResultDiscarded(laterItem),
                          let closure = unstructuredTaskTrailingClosure(in: laterItem) else { continue }
                    let referenced = collectReferencedIdentifiers(in: closure)
                    if !mutated.isDisjoint(with: referenced) {
                        violations.append(deferStmt.deferKeyword.positionAfterSkippingLeadingTrivia)
                        break
                    }
                }
            }
        }

        private func isEnclosingAsync(_ node: CodeBlockSyntax) -> Bool {
            var current: Syntax? = node.parent
            while let n = current {
                if let fn = n.as(FunctionDeclSyntax.self) {
                    return fn.signature.effectSpecifiers?.asyncSpecifier != nil
                }
                if let init_ = n.as(InitializerDeclSyntax.self) {
                    return init_.signature.effectSpecifiers?.asyncSpecifier != nil
                }
                if let closure = n.as(ClosureExprSyntax.self) {
                    if closure.signature?.effectSpecifiers?.asyncSpecifier != nil { return true }
                }
                current = n.parent
            }
            return false
        }

        private func collectAssignedIdentifiers(in body: CodeBlockSyntax) -> Set<String> {
            var names: Set<String> = []
            for item in body.statements {
                guard let seq = item.item.as(SequenceExprSyntax.self) else {
                    if let expr = item.item.as(InfixOperatorExprSyntax.self) {
                        if expr.operator.is(AssignmentExprSyntax.self) {
                            if let name = trailingIdentifier(of: expr.leftOperand) {
                                names.insert(name)
                            }
                        }
                    }
                    continue
                }
                if isAssignment(seq), let lhs = seq.elements.first,
                   let name = trailingIdentifier(of: lhs) {
                    names.insert(name)
                }
            }
            return names
        }

        private func isAssignment(_ seq: SequenceExprSyntax) -> Bool {
            seq.elements.contains { $0.is(AssignmentExprSyntax.self) }
        }

        private func trailingIdentifier(of expr: ExprSyntax) -> String? {
            if let decl = expr.as(DeclReferenceExprSyntax.self) {
                return decl.baseName.text
            }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text
            }
            return nil
        }

        private func collectReferencedIdentifiers(in closure: ClosureExprSyntax) -> Set<String> {
            var names: Set<String> = []
            class Walker: SyntaxVisitor {
                var names: Set<String> = []
                override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                    names.insert(node.baseName.text); return .visitChildren
                }
                override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                    names.insert(node.declName.baseName.text); return .visitChildren
                }
            }
            let walker = Walker(viewMode: .sourceAccurate)
            walker.walk(closure.statements)
            names.formUnion(walker.names)
            return names
        }

        private func isResultDiscarded(_ item: CodeBlockItemSyntax) -> Bool {
            item.item.is(ExprSyntax.self) || item.item.is(FunctionCallExprSyntax.self)
        }

        private func unstructuredTaskTrailingClosure(in item: CodeBlockItemSyntax) -> ClosureExprSyntax? {
            guard let call = item.item.as(FunctionCallExprSyntax.self) ?? extractCall(item) else { return nil }
            guard isTaskInit(call.calledExpression) || isTaskDetached(call.calledExpression) else { return nil }
            return call.trailingClosure
        }

        private func extractCall(_ item: CodeBlockItemSyntax) -> FunctionCallExprSyntax? {
            item.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self)
        }

        private func isTaskInit(_ expr: ExprSyntax) -> Bool {
            if let ref = expr.as(DeclReferenceExprSyntax.self) { return ref.baseName.text == "Task" }
            return false
        }

        private func isTaskDetached(_ expr: ExprSyntax) -> Bool {
            if let member = expr.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "detached",
               let base = member.base?.as(DeclReferenceExprSyntax.self),
               base.baseName.text == "Task" {
                return true
            }
            return false
        }
    }
}
