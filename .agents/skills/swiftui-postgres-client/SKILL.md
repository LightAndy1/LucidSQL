---
name: swiftui-postgres-client
description: Use for all SwiftUI, Swift concurrency, macOS integration, navigation, keyboard shortcuts, settings, and Rust bridge work in this PostgreSQL client.
---

# SwiftUI + Rust PostgreSQL client

## Architecture

- SwiftUI owns the interface, navigation, keyboard shortcuts, settings, and macOS integration.
- Rust owns PostgreSQL connections, connection pooling, SQL execution, schema metadata, exports, and query safety.
- Swift communicates with Rust only through a narrow FFI/UniFFI boundary.
- Never expose connection strings, passwords, or generic SQL-execution APIs to SwiftUI.
- Never expose raw Rust connection pools, transactions, or database clients to Swift.

## Swift rules

- Use Swift 6 concurrency: async/await, structured concurrency, `Sendable`, and task cancellation.
- Use `@Observable` view models; avoid global mutable singletons.
- Keep views simple and declarative.
- Put database orchestration, validation, and error handling in view models or services.
- Cancel in-flight work when a view disappears or the user cancels a query.
- Never block the main thread with database work, file I/O, or long-running computations.
- Use Swift Testing or XCTest for view models, services, and Rust bridge adapters.
- Prefer native SwiftUI APIs over AppKit bridging unless AppKit is genuinely required.

## Rust bridge rules

- Expose small command-style functions, not broad Rust objects.
- Return typed errors, not raw strings.
- Validate all inputs at the Rust boundary.
- Keep credentials, transactions, cancellation, and destructive-query safety in Rust.
- Use opaque handles for connections and queries.
- Convert Rust async operations into Swift async APIs safely.
- Do not let SwiftUI construct SQL strings that Rust executes directly.

## macOS rules

- Follow Apple Human Interface Guidelines.
- Prefer native sidebar, toolbar, menus, settings, and keyboard shortcuts.
- Support keyboard-first workflows.
- Use Liquid Glass only on selected chrome surfaces, such as sidebar or toolbar.
- Never reduce readability of SQL, tables, errors, or diffs for visual effects.
- Support Dark Mode and system appearance.
- Preserve user-facing state across window resizing and tab switching where appropriate.

## UI priorities

1. Correctness and safety.
2. Fast, responsive interaction.
3. Clear error messages.
4. Keyboard efficiency.
5. Visual polish.

## When implementing a feature

1. Read the relevant milestone in `docs/PLAN.md`.
2. Identify the SwiftUI views, view models, Rust commands, and tests required.
3. Implement the smallest complete vertical slice.
4. Add or update tests.
5. Run the relevant verification commands.
6. Summarize changed files, assumptions, and remaining risks.
