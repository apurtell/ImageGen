# ImageGen

ImageGen is a native macOS, iPhone and iPad client for multimodal image generation and iterative editing powered by Google's Gemini REST API. Using direct client-to-API communication with user-managed API credentials, the application provides a conversational interface for text-to-image and image-to-image generation, persisting conversation state and generated media locally on device.

## Capabilities

- **Text-to-Image Generation**: The default generation model is Gemini 3.1 Flash Image (`gemini-3.1-flash-image`), with support for per-conversation model selection across any compatible Gemini image models accessible to the user's API key.
- **Iterative Image Editing**: Image-to-image workflows chain context from the most recent image synthesized in the chat. Any previous image can be designated as a new starting checkpoint via **Edit from here**.
- **Multimodal Attachment Pipeline**: Supports importing up to 14 images per prompt across Photos, Files, and the system clipboard, and on macOS and iPad by dropping images on the chat. The ingestion pipeline normalizes HEIC to JPEG, strips EXIF and GPS metadata, and rescales images to configurable dimension thresholds.
- **Dimensional and Aspect Ratio Controls**: Aspect ratio (14 standard options) and output resolution (512, 1K, 2K, 4K) are governed by global defaults in Settings and can be overridden per conversation. Each dispatched request captures its exact operational parameters to guarantee deterministic re-execution upon **Regenerate**.
- **Resilient Background Execution**: Dispatched requests run via a background `URLSession`. On iOS, background task assertions keep them running across app suspension and process termination; on macOS a `ProcessInfo` activity assertion prevents idle system sleep and App Nap from the moment a request is prepared until its reply arrives. Local notifications are delivered on completion.
- **Bit-Identical Export Pipeline**: Export operations (Photos library or a save panel, Files filesystem, share sheet, pasteboard) deliver the uncompressed byte streams returned by the Gemini API without intermediate re-encoding.
- **Adaptive Multi-Platform Layouts**: macOS and regular-width iPad presentations utilize a two-column sidebar layout with constrained reading column widths and dynamic high-resolution image scaling. iPhone and compact iPad windows use full-width stack navigation, maintaining scroll positions and navigation state across orientation changes and window resizes.
- **Structured Activity Logging**: Comprehensive activity instrumentation records request preparation parameters, transport phases, and terminal states in plain-text diagnostic logs, inspectable through an on device Developer menu without capturing sensitive credentials or binary image data.

## System Architecture

### Architectural Layers

The codebase is organized into modular subsystems with unidirectional dependency boundaries:

- **Presentation (`ImageGen/Features/`)**: SwiftUI user interfaces and `@Observable` view models governing chat interaction, settings, media viewing, and developer utilities.
- **Composition Root (`ImageGen/App/`)**: Application initialization, dependency injection (`AppEnvironment`), lifecycle monitoring, and lifecycle event routing.
- **Generation Pipeline (`ImageGen/Pipeline/`)**: Request preparation, input arbitration, background assertion management, transient fault recovery, and outcome reconciliation (`GenerationService`).
- **Transport (`ImageGen/Networking/`)**: Background HTTP communication via `URLSessionDownloadTask` and event stream demultiplexing.
- **Protocol Translation (`ImageGen/Gemini/`)**: Serialization and deserialization of Gemini API JSON contracts, error payload extraction, and data sanitization.
- **Persistence (`ImageGen/Persistence/`)**: SwiftData storage engine (`DataStore`) and on-disk payload management (`FileStore`), with automatic orphaned asset purging (`Janitor`).
- **Image Processing (`ImageGen/Imaging/`)**: CoreGraphics and ImageIO operations for metadata stripping, downscaling, format normalization, and thumbnail caching.
- **Export Services (`ImageGen/Export/`)**: System photo library writes, sandboxed document export, and pasteboard serialization.
- **Security (`ImageGen/Security/`)**: Secure storage of Gemini API credentials in the Keychain with device-locked protection attributes (the data protection keychain on macOS).
- **Foundations (`ImageGen/Support/`)**: Activity logging pipeline, typography, formatting utilities, and synchronization primitives.
- **Testing Support (`ImageGen/DebugSupport/`)**: In-memory mock transports and demo dataset seeders for automated tests and standalone mock-mode execution. Compiled in Debug only.
- **Platform Implementations (`Platforms/iOS/`, `Platforms/macOS/`)**: Per-platform UI and system integration components, including navigation structures, toolbars, composer attachments, media viewing, log presentation, share sheet integration, and application lifecycle delegates. Both directories expose identical type and function interfaces, allowing shared code in `ImageGen/` to call platform operations without conditional compilation. Enforced by static analysis, `ImageGen/` contains no direct imports of UIKit or AppKit.

### Request Lifecycle

```
[Composer Input]
       │
       ▼
[InputSelector] ───────── Selects attachments, pinned image, or conversation checkpoint
       │
       ▼
[RequestPreparer] ────── Normalizes attachments, applies downscaling budget, serializes JSON to disk
       │
       ▼
[URLSessionTransport] ── Dispatches via background URLSession with assertion tracking
       │
       ▼
[ResponseParser] ─────── Streams JSON response, writes binary images directly to FileStore
       │
       ▼
[DataStore] ──────────── Atomically commits message and asset snapshots to SQLite
       │
       ▼
[NotificationRouter] ─── Triggers local completion alert if execution concluded in background
```

1. **Submission**: The composer captures prompt text and validated media drafts, delegating execution to `GenerationService` and resetting input state immediately.
2. **Input Arbitration**: `InputSelector` determines the target baseline (active tray attachments, explicit pin, or the chronologically latest image in the conversation) and commits the request state to the persistence store.
3. **Payload Streaming**: `RequestBodyWriter` writes the request JSON directly to a temporary file, streaming base64 image data without materializing entire payload buffers in memory. If total payload size exceeds memory thresholds, `BudgetPlanner` dynamically reduces image dimensions.
4. **Background Transfer**: The payload file is handed off to an iOS background `URLSession`, delegating transmission and response reception to the platform daemon (`nsurlsessiond`).
5. **Ingestion & Reconciliation**: On response delivery, `ResponseParser` ingests the JSON payload, extracts image data directly to distinct disk files, persists the assistant message, and primes thumbnail caches.
6. **Background Alerting**: If the application is suspended or terminated during transmission, a local notification alerts the user upon completion, routing navigation directly to the target conversation on activation.

Transient HTTP errors (408, 429, 500, 502, 503, 504) and transport disconnects trigger automated retry schedules via `RetryPolicy`. In the event of process termination during inflight requests, the next launch phase invokes `Reconciler` to restore or finalize pending request states.

### Concurrency and State Integrity

The application enforces Swift 6 complete concurrency checking, ensuring compile-time verification of data race safety:

- **Isolated Actor Domains**: Core state machines (`GenerationService`, `DataStore`) run within dedicated actors.
- **Mutual Exclusion per Request**: `GenerationService.exclusive(_:_:)` guarantees sequential processing for any single request ID, preventing concurrent execution across late transport events, user retries, or termination recovery.
- **Snapshot-and-Validate Lifecycle**: Asynchronous suspensions re-validate data store state before committing mutations, preventing stale writes across long-running background tasks.
- **Persistent Cancellation Semantics**: Cooperative cancellation flags persist across lifecycle stages, ensuring user cancellation is respected even when triggered prior to network task materialization.

### Security and Data Isolation

- **Keychain Storage**: API credentials reside exclusively within the Keychain (the data protection keychain on macOS) using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Credentials are never written to disk, included in logs, or exposed in URLs.
- **Data Sanitization**: Diagnostic activity logs filter out API keys and binary base64 payloads prior to persistence.
- **Metadata Stripping**: Media attachments are scrubbed of EXIF and GPS metadata prior to network dispatch.
- **Self-Contained Dependency Graph**: The application contains no third-party tracking, analytics, or external binary dependencies, communicating exclusively with the Gemini API endpoint.

## Development and Verification

### Prerequisites

- macOS 26 with **Xcode 26** or later, configured with the iOS 26 simulator runtime for the iPhone and iPad apps (the macOS app needs no simulator).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later (`brew install xcodegen`). Project files are generated deterministically from `project.yml`.
- An active Apple Developer Program team for on device installation and for running the macOS app, whose Keychain needs a signed build.
- A Gemini API key obtained from Google AI Studio.

Run the diagnostic script to verify the local toolchain:

```bash
scripts/doctor.sh
```

### Simulator Execution

Generate the project file and compile the debug configuration:

```bash
scripts/gen.sh
scripts/build.sh
```

Launch the application in mock mode (bypassing external network calls and API key requirements):

```bash
scripts/run-sim.sh -UITestMockGemini 1 -SeedDemoData 1
```

The scripts use a dedicated iPhone simulator, `ImageGen-Sim` (`scripts/sim.sh ensure` creates it). `IMAGEGEN_SIM`, the name or UDID of an existing simulator, picks another for `build.sh`, `run-sim.sh` and `test.sh`, such as an iPad. `run-sim.sh` boots it if it's shut down:

```bash
IMAGEGEN_SIM="iPad Pro 11-inch (M5)" scripts/run-sim.sh -UITestMockGemini 1 -SeedDemoData 1
```

### Test Suites and Quality Gates

Execute unit and integration tests under the Swift Testing framework:

```bash
scripts/test.sh                                      # iPhone simulator
IMAGEGEN_SIM="iPad Pro 11-inch (M5)" scripts/test.sh # iPad simulator
scripts/test-mac.sh                                  # macOS
```

Run static analysis checks for architectural rules and banned patterns:

```bash
scripts/lint.sh
```

Validate zero-warning compilation across the codebase:

```bash
scripts/check-warnings.sh
```

Execute live integration verification against the production Gemini API:

```bash
TEST_RUNNER_GEMINI_API_KEY="$GEMINI_API_KEY" scripts/live-smoke.sh
```

### macOS Application

The macOS target (`ImageGenMac`, product name `ImageGen`, sandboxed) requires `DEVELOPMENT_TEAM` configuration in `Config/Local.xcconfig` to sign the binary for data protection keychain access. Build and execution scripts automatically request provisioning updates.

```bash
scripts/gen.sh
scripts/build-mac.sh              # Debug build; pass --release for Release
scripts/run-mac.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -SeedDemoData 1
scripts/test-mac.sh               # Unit and integration test suite
```

The execution runner terminates prior running instances and launches the built Debug binary through Launch Services. Setting `RUN_MAC_BACKGROUND=1` invokes `open -g` to launch without stealing focus. The Debug build utilizes an isolated application bundle identifier (`<IMAGEGEN_BUNDLE_ID>.debug`) and a distinct sandbox container (`~/Library/Containers/com.andrewpurtell.imagegen.debug`), preventing interference with production data when running with store-reset flags (`-ResetStore 1`).

macOS layout architecture adheres to specific desktop invariants detailed in `doc/DESIGN.md` Section 3.11:

- **Scrollbar-Independent Content Sizing**: To prevent circular layout oscillations when persistent scrollbars are enabled in system settings, the transcript column width is constrained relative to the enclosing viewport width with legacy scrollbar gutter width continuously reserved.
- **Opaque Desktop Composer Surface**: The composer bar renders on an opaque window background surface with a structural divider, presenting accessory controls within bordered capsule containers rather than translucent materials.
- **Keystroke Forwarding**: Alphanumeric input received while focus resides in the navigation sidebar automatically transfers focus to the composer text field, appending to existing draft text while preserving standard keyboard navigation shortcuts (Return, Tab, arrow keys) for list selection.

### iPadOS Application

The iOS target supports both iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`). iPadOS supports all four device orientations, whereas iPhone presentation is constrained to portrait mode outside active full-screen media viewing (detailed in `doc/DESIGN.md` Section 3.12).

- **Adaptive Window Navigation**: View hierarchy adapts between split-view and stack navigation based on horizontal size class. Regular-width windows present a two-column sidebar and detail layout; compact windows (including Slide Over and constrained Stage Manager configurations) transition to stack navigation. Active conversation selection, message drafts, attachment trays, and scroll positions are preserved across container transitions.
- **Responsive Transcript Geometry**: Regular-width split presentations apply desktop-aligned reading column widths and proportional image constraints, floating the composer bar over transcript content on translucent material. Compact presentations utilize full-width stack layouts identical to iPhone.
- **Hardware Keyboard Integration**: Physical keyboard input maps Return to message submission and Shift-Return to line insertion, while the software keyboard preserves standard multi-line insertion semantics. Global keyboard shortcuts and menu bar commands provide quick access to common actions (New Chat, Settings, Delete Conversation, Jump to Latest).
- **Pointer and Gesture Support**: Interactive controls provide hover states, tooltips, secondary click context menus, and double-tap activation for media inspection. Drag-and-drop ingestion allows images to be imported directly from external applications.

### Physical Device Installation

1. Create `Config/Local.xcconfig` from `Config/Local.xcconfig.example` and set `DEVELOPMENT_TEAM` to your Apple Developer team ID.
2. Enable Developer Mode on the target iPhone or iPad (**Settings › Privacy & Security › Developer Mode**) and connect via USB or trusted Wi-Fi.
3. Deploy the release build:

```bash
scripts/device-install.sh --release
```

With several devices connected, `DEVICE_UDID` selects one.

## Architectural Specifications

- [`doc/DESIGN.md`](doc/DESIGN.md): Authoritative architectural specification defining state machines, protocol contracts, persistence schemas, background processing semantics, and failure modes.
- [`doc/IMPLEMENTATION_PLAN.md`](doc/IMPLEMENTATION_PLAN.md): Milestone execution roadmap, verification requirements, and  change log.
- [`doc/SWIFT_PRIMER.md`](doc/SWIFT_PRIMER.md): Guide to Swift concurrency, isolation guarantees, and iOS platform patterns implemented in the codebase.

## License

ImageGen is licensed under the [Apache License, Version 2.0](LICENSE).
