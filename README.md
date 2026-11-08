# ImageGen

ImageGen is a native macOS, iPhone and iPad client for multimodal image generation and iterative editing powered by Google's Gemini REST API (`generateContent`). Using direct client-to-API communication with user managed API credentials, the application provides a conversational interface for text-to-image and image-to-image generation, persisting conversation state and generated media locally on device. The macOS app and the iOS app, which is one universal target for iPhone and iPad, are separate native targets (UIKit-free SwiftUI shared code plus per-platform code), not Catalyst.

## Capabilities

- **Text-to-Image Generation**: The default generation model is Gemini 3.1 Flash Image (`gemini-3.1-flash-image`), with support for per-conversation model selection across any compatible Gemini image models accessible to the user's API key.
- **Iterative Image Editing**: Image-to-image workflows chain context from the most recent image synthesized in the chat. Any previous image can be designated as a new starting checkpoint via **Edit from here**.
- **Multimodal Attachment Pipeline**: Supports importing up to 14 images per prompt across Photos, Files, and the system clipboard, and on macOS and iPad by dropping images on the chat. The ingestion pipeline normalizes HEIC to JPEG, strips EXIF and GPS metadata, and rescales images to configurable dimension thresholds.
- **Dimensional and Aspect Ratio Controls**: Aspect ratio (14 standard options) and output resolution (512, 1K, 2K, 4K) are governed by global defaults in Settings and can be overridden per conversation. Each dispatched request captures its exact operational parameters to guarantee deterministic re-execution upon **Regenerate**.
- **Resilient Background Execution**: Dispatched requests run via a background `URLSession`. On iOS, background task assertions keep them running across app suspension and process termination; on macOS a `ProcessInfo` activity assertion prevents idle system sleep and App Nap from the moment a request is prepared until its reply arrives. Local notifications are delivered on completion.
- **Bit-Identical Export Pipeline**: Export operations (Photos library or a save panel, Files filesystem, share sheet, pasteboard) deliver the uncompressed byte streams returned by the Gemini API without intermediate re-encoding.
- **Layout for each device**: macOS and a regular-width iPad window show the chat list as a sidebar beside the chat, with text and the composer in a readable column and reply images sized to the window and loaded at the resolution they are drawn. The iPhone and narrow iPad windows show the chat list with a chat pushed on top of it, at full width. Resizing and rotating keep the reader's place.
- **Structured Activity Logging**: Comprehensive activity instrumentation records request preparation parameters, transport phases, and terminal states in plain-text diagnostic logs, inspectable through an on device Developer menu without capturing sensitive credentials or binary image data.

## System Architecture

### Architectural Layers

| Directory | Layer | Architectural Responsibility |
|---|---|---|
| `ImageGen/Features/` | Presentation | SwiftUI user interfaces and `@Observable` view models governing chat interaction, settings, media viewing, and developer utilities. |
| `ImageGen/App/` | Composition Root | Application initialization, dependency injection (`AppEnvironment`), lifecycle monitoring, and lifecycle event routing. |
| `ImageGen/Pipeline/` | Generation Pipeline | Request preparation, input arbitration, background assertion management, transient fault recovery, and outcome reconciliation (`GenerationService`). |
| `ImageGen/Networking/` | Transport | Background HTTP communication via `URLSessionDownloadTask` and event stream demultiplexing. |
| `ImageGen/Gemini/` | Protocol Translation | Serialization and deserialization of Gemini API JSON contracts, error payload extraction, and data sanitization. |
| `ImageGen/Persistence/` | Persistence | SwiftData storage engine (`DataStore`) and on-disk payload management (`FileStore`), with automatic orphaned asset purging (`Janitor`). |
| `ImageGen/Imaging/` | Image Processing | CoreGraphics and ImageIO operations for metadata stripping, downscaling, format normalization, and thumbnail caching. |
| `ImageGen/Export/` | Export Services | System photo library writes, sandboxed document export, and pasteboard serialization. |
| `ImageGen/Security/` | Security | Secure storage of Gemini API credentials in the Keychain with device-locked protection attributes (the data protection keychain on macOS). |
| `ImageGen/Support/` | Foundations | Activity logging pipeline, typography, formatting utilities, and synchronization primitives. |
| `ImageGen/DebugSupport/` | Testing Support | In-memory mock transports and demo dataset seeders for automated tests and standalone mock-mode execution. Compiled in Debug only. |
| `Platforms/iOS/`, `Platforms/macOS/` | Platform | Per-platform UI and system glue (navigation, toolbars, composer attachments, viewer, log view, share sheet, app entry point and delegate). Both directories define the same type and function names, so `ImageGen/` calls them without conditional compilation. `ImageGen/` never imports UIKit or AppKit (enforced by `scripts/lint.sh`). |

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

### macOS App

The macOS target (`ImageGenMac`, product name `ImageGen`, sandboxed) needs `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`; the data protection keychain refuses unsigned binaries. The scripts pass `-allowProvisioningUpdates`.

```bash
scripts/gen.sh
scripts/build-mac.sh              # Debug; --release for Release
scripts/run-mac.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -SeedDemoData 1
scripts/test-mac.sh               # tests hosted in the signed app
```

`run-mac.sh` quits any running copy, waits for it to exit, and opens the built Debug app through Launch Services, trying again for a few seconds if Launch Services is still tearing down the old instance. `RUN_MAC_BACKGROUND=1` opens it with `open -g`, which asks the system not to bring it to the front. The Debug configuration has its own bundle ID (`<IMAGEGEN_BUNDLE_ID>.debug`) and so its own sandbox container (`~/Library/Containers/com.andrewpurtell.imagegen.debug`), keychain item and defaults, which makes `-ResetStore 1` safe: it can't reach a Release install's data.

Two layout rules hold on the Mac, explained in `doc/DESIGN.md` section 3.11:

- **The transcript's width doesn't depend on the scroll bar.** With "Show scroll bars: Always", a bar takes width while content overflows, and an image's height follows its width, so content can overflow only when the bar is absent. Left alone, the bar toggles on every layout pass and hangs the app. So the width is capped from the scroll view's outer frame with the bar's width always reserved. It's a cap and not a fixed width, because a fixed width would become the window's minimum width.
- **The composer is an opaque system-background bar.** Its pills and chips sit directly on that background, outlined by a hairline capsule, instead of the glass they use on iPhone and iPad.

Typing a character while the sidebar has the keyboard starts a prompt in the composer, with the caret after any draft; arrow keys, Return, Tab and menu shortcuts stay with the list and the menus.

### iPad

The iPhone and iPad share the `ImageGen` target (`TARGETED_DEVICE_FAMILY = 1,2`). The iPad has all four orientations; the iPhone is in portrait except in the full-screen viewer, which also turns to the two landscapes. `doc/DESIGN.md` section 3.12 has the details.

- **Navigation follows the window.** A window of regular width is a sidebar and a detail; a narrow one, such as Slide Over or a small Stage Manager window, is the iPhone's stack. Crossing between them keeps the selected chat, the draft and the attachment tray. The viewer stays up and the reader's place comes across. The crossing rebuilds the chat's screen, so a sheet open on it closes.
- **The transcript in the sidebar layout follows the Mac's policy**, with the composer floating on glass as on the iPhone. The stack layout is the same as on the iPhone.
- **A hardware keyboard:** Return sends and Shift-Return inserts a newline. The on-screen keyboard's Return inserts a newline. The menu bar has New Chat (Cmd-N), Settings (Cmd-comma), Delete Chat, Jump to Latest and the Chat menu.
- **A pointer:** hover effects and tooltips on icon controls, a secondary click for the context menus, and a double click (or double tap) to open an image.
- **Images can be dropped on the chat** from another app.

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
