# Swift Architecture and iOS Platform Integration

This document outlines the architecture of the ImageGen codebase.

---

## 1. Architecture

High level feature workflows delegate downwards through pipeline coordination, protocol translation, and platform infrastructure, preventing cyclic references and isolating subsystem failures.

| Layer | Subsystem Directory | Architectural Invariants & Scope |
|---|---|---|
| **Presentation** | `Features/` | Declarative SwiftUI views and `@Observable` view models. View models are isolated to `@MainActor`, orchestrating UI state, user intents, and presentation lifecycles without maintaining persistent storage references. |
| **Composition Root** | `App/` | Centralizes application initialization, singleton service composition (`AppEnvironment`), UIKit lifecycle adaptation, and system notification dispatch. |
| **Generation Pipeline** | `Pipeline/` | Coordinates multimodal request arbitration, background execution assertions, transient network recovery, and state reconciliation (`GenerationService`). |
| **Transport** | `Networking/` | Manages background network transfers via `URLSessionDownloadTask` and serializes transport event streams for consumption by the pipeline. |
| **Protocol Translation** | `Gemini/` | Implements bidirectional serialization for the Gemini REST API (`generateContent`), structured error parsing, and sensitive data redaction. |
| **Persistence** | `Persistence/` | Implements an isolated SwiftData actor (`DataStore`) for relational conversation state alongside disk-backed payload storage (`FileStore`) and orphaned file garbage collection (`Janitor`). |
| **Image Processing** | `Imaging/` | Executes CoreGraphics and ImageIO operations for metadata sanitization, downscaling, format transformation, and thumbnail generation off the main thread. |
| **Export Services** | `Export/` | Handles platform export operations (Photos library, Files document tree, system share sheets) while preserving bit-identical payload integrity. |
| **Security** | `Security/` | Manages credential lifecycle in the iOS Keychain with hardware-enforced protection classes. |
| **Foundations** | `Support/` | Implements structured diagnostic logging (`ActivityLog`), formatting utilities, and synchronization primitives. |
| **Test Instrumentation** | `DebugSupport/` | In-memory protocol interception and deterministic fixture generation utilized during automated testing and simulator demonstration modes. Excluded from production binaries. |

---

## 2. Type Semantics and State Representation

The domain model enforces data ownership boundaries through Swift's type system:

- **Immutable Value Semantics (`struct`)**: Domain snapshots, request options, API representations, and configuration models are modeled as immutable structs. Value copying guarantees absence of unintended shared state across tasks.
- **Stateful Coordinators (`class` / `actor`)**: Entities managing operational lifecycles, active network connections, or long-lived caches are implemented as reference types.
- **Sealed Finite-State Machines (`enum`)**: Operational states (`RequestState`), transport outcomes (`ParsedOutcome`), and error domains utilize enums with typed associated payloads. Exhaustive pattern matching guarantees complete handling of state transitions across the application.
- **Interface Segregation via Protocols**: Protocol abstractions define boundaries across architectural layers (`GenerationServicing`, `GenerationTransport`, `APIKeyStore`), enabling deterministic test substitution via mock protocols and test harness injectors.
- **Concurrency Boundary Crossing (`Sendable`)**: All data structures crossing actor or thread boundaries conform strictly to `Sendable`. Immutable structs composed of `Sendable` primitives conform implicitly, while reference types enforce thread safety through internal synchronization or actor encapsulation.

---

## 3. Concurrency Architecture and Data Isolation

ImageGen enforces Swift 6 complete strict concurrency checking. All data races are eliminated at compile time through compiler verified actor boundaries and task isolation.

### 3.1 Actor Isolation and Reentrancy Mitigations

Actors isolate their internal mutable state, serializing external invocations. However, actor execution is inherently **reentrant across suspension points (`await`)**:

- When an actor function suspends awaiting an asynchronous dependency (e.g., persistence I/O, network responses, file system operations), the actor's lock is relinquished, permitting interleaved execution of concurrent requests.
- Upon resumption, external state or actor-internal variables may have mutated.

To ensure consistency in complex state machines like `GenerationService`:
1. **Re-validation Pattern**: State observed prior to an `await` is treated as a snapshot. Upon resuming, the actor re-reads current state from storage before executing state transitions.
2. **Mutual Exclusion per Entity (`exclusive(_:_:)`)**: Concurrent operations targeting the same logical request ID (such as concurrent transport completion events, recovery routines, or retry attempts) are serialized sequentially via a per-key FIFO queue.
3. **Atomic Context Preservation**: State that must survive across suspension boundaries without corruption is preserved within dedicated immutable execution contexts.

### 3.2 Main Actor Demarcation

The main execution domain (`@MainActor`) is reserved strictly for UI presentation and event delivery:
- All feature view models conform to `@MainActor`.
- Computationally intensive operations—including image format transcoding, base64 payload serialization, and large-file directory scans—are explicitly offloaded to detached background tasks or dedicated actors to preserve frame rates and eliminate main-thread hitches.

### 3.3 Low-Level Synchronization

In scenarios where synchronous callbacks from legacy frameworks (such as UIKit or CoreFoundation) must coordinate shared state without asynchronous suspension, ImageGen utilizes lightweight mutual exclusion primitives (`Mutex` from `Synchronization`, wrapped in `Locked`). This ensures thread-safe atomic access within synchronous critical sections without thread contention.

### 3.4 Asynchronous Streams

Ordered event delivery between disparate concurrency domains is facilitated by `AsyncStream`. Transport lifecycle updates and activity logging events are fed into unidirectional streams, ensuring serialized, backpressure-managed processing without race conditions.

---

## 4. Persistence Architecture and SwiftData Isolation

Data persistence couples relational metadata management in SwiftData with discrete on-disk asset storage:

- **Actor-Isolated Context (`ModelActor`)**: SwiftData's `DataStore` implements `ModelActor`, binding its private `ModelContext` to a dedicated serial executor. SwiftData managed objects (`@Model`) never escape this actor domain.
- **Disconnected Snapshot DTOs**: Callers interact with `DataStore` exclusively using detached, immutable `Sendable` data transfer objects (`ConversationSnapshot`, `RequestSnapshot`, `ImageAssetSnapshot`). This prevents concurrent access to managed object graphs across threads.
- **Transaction Atomicity**: State changes spanning multiple records are committed within unified context transactions, ensuring database integrity in the event of process termination.

---

## 5. iOS Lifecycle and Background Execution Semantics

Mobile runtime constraints necessitate robust handling of process suspension and system-triggered terminations:

- **Background URLSession Delegation**: Network transfers use `URLSessionConfiguration.background`, handing request payloads directly to the system daemon (`nsurlsessiond`). Out-of-process transfers continue unimpeded when ImageGen is suspended or terminated by the operating system.
- **Background Event Relaying**: When transfers finish while the app is dormant, iOS awakens the process in the background via `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The application registers completion callbacks with `BackgroundEventsRelay`, delaying completion acknowledgement until all response payloads are ingested, persisted, and verified.
- **Background Task Assertions**: Transient preparation steps (image downscaling, JSON compilation, and initial disk serialization) are shielded against abrupt process suspension using `UIApplication.beginBackgroundTask(withName:expirationHandler:)`.
- **System Launch Reconciliation**: In the event of an unrecoverable process termination during active generation, the subsequent launch sequence executes `Reconciler`, identifying interrupted requests and either completing ingestion from orphaned response files or transitioning states to allow explicit user retry.
- **Data Protection Compliance**: File system assets and Keychain entries apply `NSFileProtectionCompleteUntilFirstUserAuthentication` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, ensuring accessibility during background execution once the user has unlocked the device after boot.

---

## 6. Structural Engineering Invariants

1. **Deterministic Regeneration**: Every dispatched generation request permanently captures its operative parameters (model ID, aspect ratio, resolution class, prompt text, and input image reference). Regeneration operations reconstruct the request from the historical snapshot rather than active workspace defaults.
2. **Bit-Identical Export**: Binary image payloads returned by Gemini are stored verbatim to disk and exposed through export interfaces without recompression, transcoding, or metadata alteration.
3. **Idempotent Cancellation**: User cancellation flags are recorded immediately in an in-memory registry, terminating active network tasks and pre-empting pending background attempts even if the cancellation signal arrives during asynchronous request preparation.
4. **Sanitized Diagnostic Logging**: Diagnostic activity logs adhere to a strict structured lifecycle (*Begin*, *Step*, *Result*). All log pipelines automatically sanitize bearer tokens, API keys, and binary image representations prior to persistence.
