# ImageGen for iPhone: Implementation Plan

Date: 2026-10-15

---

## 0. Implementation Guidelines

1. Execute milestone by milestone following dependency ordering (section 3). Parallel tracks may be worked in isolated git worktrees.
2. Each milestone defines: **Goal**, **Files and types**, **Implementation notes**, **Tests**, **Simulator verification**, and **Done when** criteria. A milestone is complete once all criteria are demonstrably validated via automated test runs or visual inspection.
3. Verify toolchain readiness using `scripts/doctor.sh`.
4. API credentials must never be written to repository files, shell logs, URLs, or captured screenshots. Mock mode (section 2.6) operates without credentials, and live smoke tests inject credentials exclusively via environment variables.
5. In the event implementation necessitates architectural deviation from `DESIGN.md`, document the rationale and update the change log (section 8).
6. Commit changes at milestone boundaries using the convention `M<n>: <title>`. Avoid committing local configuration (`Config/Local.xcconfig`), generated projects, or build artifacts.

### 0.1 Cross-cutting requirement: aspect ratio and resolution
Aspect ratio and output resolution are configurable, defaulting to 16:9 and 2K across the architecture:

- **Vocabulary Layer (M0)**: `AspectRatio` (14 standard cases) and `ImageSize` (`512`, `1K`, `2K`, `4K`) define exact Gemini wire format strings, verified by `VocabularyTests`.
- **Application Defaults (M2)**: `AppSettings` initializes default values to `16:9` and `2K`, verified by `AppSettingsTests.defaultsAre16x9And2K`.
- **Resolution and Coercion (M1)**: `GenerationSettingsResolver` resolves overrides and enforces model capabilities (D§2.5), verified by `SettingsResolverTests`.
- **Wire Serialization (M1)**: `RequestBodyWriter` explicitly serializes `generationConfig.imageConfig` specifying `aspectRatio` and `imageSize`, verified by golden fixtures and `PipeParityTests`.
- **Persistence Auditing (M2, M4)**: `GenerationRequest` captures operative `aspectRatio` and `imageSize` values committed to `DataStore`, verified by `GenerationServiceTests.recordsSentValues`.
- **Deterministic Regeneration (M4, M5)**: Regeneration operations reconstruct requests from historical snapshots rather than active settings, verified by `GenerationServiceTests.regenerateUsesRecordedSettings`.
- **Composer Controls (M5)**: The composer surfaces Model, Aspect, and Resolution selector pills, dynamically displaying current global defaults, verified by `ChatScreenModelTests` and UI captures.
- **Settings Management (M8)**: Global generation defaults are configured under Settings › Generation defaults, verified by UI captures and persistence tests.
- **Runtime Verification (M5, M10)**: Reply metadata displays synthesized pixel dimensions with warning indicators for non-conforming dimensions, verified via mock scenarios and physical device testing.

---

## 1. Toolchain and repository

### 1.1 Toolchain prerequisites (checked by `scripts/doctor.sh`)

Development and verification require the following toolchain components:

- **Xcode**: Version 26.0 or later (`xcodebuild -version`), located in `/Applications/Xcode.app` or specified via `DEVELOPER_DIR`.
- **Active Developer Directory**: Configured via `xcode-select -s /Applications/Xcode.app/Contents/Developer` or exported in the environment (`scripts/env.sh`).
- **Xcode License and First Launch**: License accepted via `sudo xcodebuild -license accept` and core components installed via `xcodebuild -runFirstLaunch`.
- **iOS Simulator Runtime**: iOS 26.0 or later runtime (`xcrun simctl list runtimes`), installed via `xcodebuild -downloadPlatform iOS`.
- **XcodeGen**: Version 2.46.0 or later (`xcodegen --version`), installed via Homebrew (`brew install xcodegen`).
- **Python 3**: Python 3.9 or later (`python3 --version`) utilized for generating reference parity fixtures (`scripts/gen_pipe_fixtures.py`).
- **Apple Developer Account**: Enrolled Apple Developer Program team signed into Xcode Accounts for signing and on-device deployment.

Privileged system commands (`sudo`) and Apple account authentication require manual user execution. Step 0 lists the required setup commands and verifies readiness via `scripts/doctor.sh`.

### 1.2 Repository layout

```
imagegen/
  doc/
    DESIGN.md                         the normative spec
    IMPLEMENTATION_PLAN.md            this plan
    openwebui_gemini_filter.py        reference pipe (read-only)
  project.yml                         XcodeGen spec (source of truth for the project)
  .gitignore                          ImageGen.xcodeproj/, build/, artifacts/, Config/Local.xcconfig, .DS_Store
  Config/
    Base.xcconfig                     checked in; bundle ID, signing defaults, `#include? "Local.xcconfig"`
    Local.xcconfig.example            checked in; DEVELOPMENT_TEAM placeholder
    Local.xcconfig                    git-ignored; user's team ID (optional for simulator)
  scripts/
    env.sh                            sourced by every script: DEVELOPER_DIR, SIM name, paths
    doctor.sh                         toolchain checks (section 1.1)
    sim.sh                            ensure|udid|boot|reset|erase the dedicated simulator
    gen.sh                            xcodegen generate
    build.sh                          build for simulator (default) or device; --release for Release; tees log
    test.sh                           run unit tests; passes extra args through (e.g. -only-testing)
    run-sim.sh                        install + launch on the simulator with launch options
    shot.sh                           simctl screenshot → artifacts/<milestone>/<name>.png
    check-warnings.sh                 clean builds of both apps into their own logs; fails on any warning in ImageGen/ or Platforms/ sources
    lint.sh                           banned-pattern greps (section 2.7); --self-test checks the rules fire
    gen_image_fixtures.swift          generates the four checked-in binary test images (M0)
    device-install.sh                 build + install + launch on a connected iPhone
    live-smoke.sh                     opt-in live API test (section 2.5)
    gen_pipe_fixtures.py              produces pipe-reference request bodies (M1)
  ImageGen/                           app sources (layers per D§4.1)
    App/  Features/  Pipeline/  Gemini/  Networking/  Imaging/  Persistence/
    Export/  Security/  Settings/  Support/  DebugSupport/
    Resources/Assets.xcassets         AppIcon, AccentColor
    Info.plist                        generated by XcodeGen from project.yml (git-ignored is fine; regenerated)
  ImageGenTests/
    Support/                          BundleToken, MockURLProtocol, TestFileRoot, FixtureLoader, ImageFactory (M0);
                                      InMemoryStore (M2: in-memory ModelContainer + DataStore + TestFileRoot);
                                      ActivityLogProbe (M2: an ActivityLog on a TestFileRoot file, plus line queries)
    <Suite>Tests.swift                one file per suite (D§9)
    Fixtures/                         folder reference (copied as a folder into the test bundle)
      Requests/  PipeReference/  Responses/  Errors/  Models/  Images/
  artifacts/                          git-ignored; screenshots and logs per milestone
```

"Sources grouping" means `ImageGen/<Layer>/`; there is no separate `Sources/` folder, which matches D§4.1.

### 1.3 `project.yml` (target state after M0)

```yaml
name: ImageGen
options:
  bundleIdPrefix: com.andrewpurtell
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated   # D§5: keep @Model/@ModelActor compatible
    SWIFT_APPROACHABLE_CONCURRENCY: NO
    TARGETED_DEVICE_FAMILY: "1,2"
    CODE_SIGN_STYLE: Automatic
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    DEAD_CODE_STRIPPING: YES
targets:
  ImageGen:
    type: application
    platform: iOS
    sources:
      - path: ImageGen
        excludes: ["Info.plist"]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(IMAGEGEN_BUNDLE_ID)
        PRODUCT_NAME: ImageGen
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        SUPPORTS_MACCATALYST: NO
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO
    info:
      path: ImageGen/Info.plist
      properties:
        CFBundleDisplayName: ImageGen
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        NSPhotoLibraryAddUsageDescription: "ImageGen saves the images you choose to your photo library."
        ITSAppUsesNonExemptEncryption: false
        # No UIBackgroundModes and no BGTaskSchedulerPermittedIdentifiers in v1 (D§10).
  ImageGenTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: ImageGenTests
        excludes: ["Fixtures/**"]
      - path: ImageGenTests/Fixtures
        type: folder
        buildPhase: resources
    dependencies:
      - target: ImageGen
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(IMAGEGEN_BUNDLE_ID).tests
        GENERATE_INFOPLIST_FILE: YES
schemes:
  ImageGen:
    build:
      targets:
        ImageGen: all
        ImageGenTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: true
      targets:
        - ImageGenTests
    archive:
      config: Release
```

`Config/Base.xcconfig`:
```
// Checked in. Local overrides (team ID) go in Local.xcconfig, which is git-ignored and optional.
IMAGEGEN_BUNDLE_ID = com.andrewpurtell.imagegen
DEVELOPMENT_TEAM =
CODE_SIGN_IDENTITY[sdk=iphonesimulator*] = -
#include? "Local.xcconfig"
```
The `#include?` form is optional, so `xcodegen generate` and simulator builds work on a fresh clone without `Local.xcconfig`. (XcodeGen refuses a `configFiles` path that doesn't exist, which is why the git-ignored file isn't referenced directly.)

`Config/Local.xcconfig.example`:
```
// Copy to Config/Local.xcconfig and fill in. Find the team ID in Xcode › Settings › Accounts.
DEVELOPMENT_TEAM = ABCDE12345
// IMAGEGEN_BUNDLE_ID = com.andrewpurtell.imagegen
```

### 1.4 Standard automation commands

All scripts source `scripts/env.sh`, configuring `DEVELOPER_DIR`, simulator identifiers (`ImageGen-Sim`), bundle identifiers, and output paths. Common workflows include:

- **Environment Diagnostics (`scripts/doctor.sh`)**: Validates local developer directory, SDK versions, runtime simulators, and XcodeGen installations.
- **Simulator Provisioning (`scripts/sim.sh ensure`)**: Provisions and boots the dedicated test simulator (`ImageGen-Sim`), creating an iPhone 17 Pro device with the newest available iOS 26 runtime.
- **Project Generation (`scripts/gen.sh`)**: Generates deterministic Xcode project files from `project.yml` via XcodeGen.
- **Compilation (`scripts/build.sh [--release]`)**: Invokes `xcodebuild` targeting simulator destinations under Debug or Release configurations, capturing full build transcripts to `build/logs/`.
- **Test Execution (`scripts/test.sh [options]`)**: Executes Swift Testing suites against the simulator, streaming output and generating structured `.xcresult` bundles.
- **Static Analysis and Linting (`scripts/lint.sh`)**: Validates structural boundaries, layer separation rules, and architectural invariants.
- **Compiler Warning Verification (`scripts/check-warnings.sh`)**: Executes a clean build pass into an isolated derived data path, enforcing zero-warning compilation across the codebase.
- **Simulator Execution (`scripts/run-sim.sh [args]`)**: Deploys the Debug build to the simulator and executes with specified launch options.
- **Automated Screenshot Capture (`scripts/shot.sh <milestone> <name>`)**: Captures standardized device screenshots with normalized status bar geometry into `artifacts/`.
- **Physical Device Deployment (`scripts/device-install.sh [--release]`)**: Builds, signs, and deploys release binaries to connected physical hardware via `devicectl`.

**Interactive simulator driving.** Use the iOS Simulator tool (`control` actions `attach`, `screenshot`, `tap`, `swipe`, `text`) for taps and gestures, and `scripts/run-sim.sh` for launches that need launch options. The simulator tool's `launch` takes no arguments; to use it, persist the options first with `xcrun simctl spawn $UDID defaults write com.andrewpurtell.imagegen UITestMockGemini -bool YES` (and so on). `LaunchOptions` reads `UserDefaults.standard`, which holds both launch arguments and persisted defaults. Clear them with `defaults delete com.andrewpurtell.imagegen <key>`.

**Reviewing screenshots.** After capturing, open each PNG with the Read tool and check the listed elements. Record the result in `artifacts/<milestone>/REVIEW.txt`, one line per screenshot: `<file>: PASS|FAIL <note>`. This is a working log, not a deliverable.

---

## 2. Cross-cutting engineering rules

### 2.1 Concurrency and isolation (D§5)
- Swift 6 language mode; `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, set explicitly.
- Mark `@MainActor` explicitly on views' models (`@Observable` classes), `AppSettings`, `ModelAvailability`, `BackgroundEventsRelay` and `NotificationRouter`.
- Pure logic is nonisolated value types. Heavy work uses `@concurrent` async functions (Swift 6.2, Xcode 26).
- `@Model` classes are declared `nonisolated` explicitly, as a belt-and-braces measure, and never cross actors. Only `UUID`s and `Sendable` snapshots do.
- `Synchronization.Mutex` protects mutable state in `Sendable` classes.
- **Zero** compiler warnings in `ImageGen/` (`scripts/check-warnings.sh`).

### 2.2 Testing conventions
- Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`, parameterized `arguments:`). No XCTest assertions.
- Tags: `.pure` (no I/O), `.io` (temporary files), `.integration` (transport + store), `.live` (network, opt-in).
- Use `@testable import ImageGen`.
- File I/O goes under a per-test `TestFileRoot` (a temporary directory, removed in `deinit`). No test touches the real Application Support folder or the Keychain item, except `KeychainStoreTests`, which uses a distinct service name `com.andrewpurtell.imagegen.tests`.
- **Network:** `MockURLProtocol` in `ImageGenTests/Support/` (created in M0) serves a **queue** of `(status, headers, bodyChunks: [Data], delay)` responses per URL, one per request in order (so "429, then 200" is one registration), and records each `URLRequest` along with its body file bytes. It's registered with `URLSessionConfiguration.ephemeral.protocolClasses = [MockURLProtocol.self]`. Upload-from-file bodies arrive to `URLProtocol` as `httpBodyStream`; the mock reads the stream so tests can assert on body contents.
- `MockURLProtocol` keeps its state in a `Mutex`-protected registry keyed by a per-test token, which is sent in a header (`X-Test-Token`) that the transport adds only in tests through a request decorator. This makes it safe when Swift Testing runs suites in parallel. Mark suites that share the global registry `.serialized` if the token approach isn't used.
- **Activity log in tests.** Every component that logs takes an `ActivityLog` in its `init`. Tests build a real one on a `TestFileRoot` file through `ActivityLogProbe` (M2), which also injects an OSLog sink that records the strings it's given and a `sanitize:` closure. The probe's sanitizer defaults to the identity, because M2 can't reference M1's `Redactor`; from M4 on, every suite that checks redaction (`ActivityLogRedactionTests`, and any "no base64" assertion) passes `Redactor.forLog(secrets:)` explicitly. `probe.action(named:)`, `probe.lines()` and `probe.assertPaired()` first await `flush()`, which travels through the log's ordered stream, so assertions see every earlier call. No test writes the real `Logs/` folder.
- **Fixtures** are loaded with `FixtureLoader.url("Responses/resp_text_image.json")` from `Bundle(for: BundleToken.self)`, where `BundleToken` is a `final class` in the test target.
- **Test images are made in code** with ImageIO (`ImageFactory.jpeg(width:height:orientation:gps:)`, `.png(alpha:)`, `.heic(alpha:)`, `.gif()`). The only binaries checked in are these four, all under `Fixtures/Images/`, as D§9 says: `sample.heic` (≤ 300 KB), `rotated_exif6.jpg` (≤ 100 KB, EXIF orientation 6), `tiny_16x9.png` and `tiny_square.jpg` (each under 2 KB). M0 generates all four once with `xcrun swift scripts/gen_image_fixtures.swift ImageGenTests/Fixtures/Images` (ImageIO: a gradient written as HEIC; a 400×300 JPEG with `kCGImagePropertyOrientation = 6`; a 32×18 PNG; a 16×16 JPEG) and checks them in. Re-running the script must reproduce files that pass the same tests. No WebP file is checked in, because ImageIO on iOS can't encode WebP.
- **App host isolation.** Unit tests are hosted by the app. `AppEnvironment` detects the test host (`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`). Under test it does **not** create the background `URLSession` or the activity log file, run the Reconciler or Janitor, or request notification permission, and `ImageGenApp` shows an empty `Color.clear` scene.

### 2.3 Golden JSON fixtures (request building)
Location: `ImageGenTests/Fixtures/Requests/`. Each golden file holds the full request body with base64 data replaced by the token `"<b64:FILENAME>"`. Tests expand tokens against test image assets and compare payloads structurally via `JSONSerialization`:

- **`flash_text_only_16x9_2k.json`**: Baseline text-only prompt verifying single text part serialization, `imageConfig` parameters (16:9, 2K), five safety categories at `BLOCK_NONE`, and `["TEXT", "IMAGE"]` modalities.
- **`flash_three_images.json`**: Multimodal request verifying three ordered `inlineData` parts preceding the prompt text part.
- **`flash_image_only.json`**: Single-attachment request with empty prompt text, verifying omission of text parts.
- **`flash_512_9x16.json`**: Request override testing exact serialization of 9:16 aspect ratio and `"imageSize": "512"`.
- **`pro_16x9_1k.json`**: Pro model request verifying routing to `gemini-3-pro-image` and parameter coercion to 16:9 / 1K.
- **`flash25_no_image_size.json`**: Legacy Gemini 2.5 Flash request verifying serialization of `aspectRatio` with complete omission of the `imageSize` key.
- **`flash_no_civic.json`**: Fallback request body verifying omission of the deprecated `CIVIC_INTEGRITY` safety category.
- **`flash_image_modality_only.json`**: Request verifying modality restriction to `["IMAGE"]` when text response generation is disabled.
- **`flash_threshold_only_high.json`, `flash_threshold_medium.json`, `flash_threshold_low.json`**: Parameterized safety threshold tests verifying exact serialization across `BLOCK_ONLY_HIGH`, `BLOCK_MEDIUM_AND_ABOVE`, and `BLOCK_LOW_AND_ABOVE`.
- **`flash_escaping.json`**: Prompt string sanitization test verifying exact round-trip escaping for quotes, backslashes, line breaks, tabs, emoji, and Unicode line separators.
- **`custom_model_4k.json`**: Custom model endpoint test verifying path routing to user-defined model identifiers with pass-through aspect and resolution settings.

**Pipe parity fixtures** (`Fixtures/PipeReference/`). These are generated once by `scripts/gen_pipe_fixtures.py` and checked in. The script:
- imports `doc/openwebui_gemini_filter.py` with stub `pydantic` and `requests` modules injected into `sys.modules` (so it needs no third-party packages);
- calls `Pipe().pipe(body)` with OpenAI-style `messages` built from `Fixtures/Images/tiny_16x9.png`, `tiny_square.jpg` and text;
- captures `json=payload`, `url` and `headers` from the stubbed `requests.post`, and writes `<case>.payload.json` plus `<case>.url.txt` with the key replaced by `<KEY>`.

Run it as `python3 -I scripts/gen_pipe_fixtures.py --pipe doc/openwebui_gemini_filter.py --out ImageGenTests/Fixtures/PipeReference`.

Pipe parity verification scenarios evaluate input selection and wire parity against reference pipeline outputs:
- **`p1_text_only`**: Single text message; verified against `.noImage` selection reason.
- **`p2_upload_and_text`**: Text message with single image URL; verified against `.attachments` selection reason with identical image payload bytes.
- **`p3_edit_latest`**: Conversation turn following assistant image output; verifies `.latest` selection of the model output asset.
- **`p4_image_only`**: Image attachment without prompt text; verifies `.attachments` selection.
- **`p5_threshold_only_high`**: Pipeline configuration testing `BLOCK_ONLY_HIGH` safety threshold serialization under `.noImage`.
- **`p6_latest_is_user_upload`**: Conversation turn following assistant text reply; verifies `.latest` fallback to the preceding user upload asset.
- **`p7_latest_of_two_outputs`**: Conversation turn following assistant reply containing multiple images; verifies `.latest` selection of the final ordinal image.
- **`p8_latest_of_two_uploads`**: Conversation turn following user message with multiple attachments; verifies `.latest` selection of the final user attachment.

`PipeParityTests` (Track 1B) asserts: `appBody` with `generationConfig.imageConfig` removed deep-equals `pipeBody`, and the app URL equals the pipe URL with `?key=<KEY>` removed. Every other difference fails the test. That is the proof of D§1.2 goal 1, with only the D§2.6 deviations allowed. Track 1B builds each app-side input list by hand, so it doesn't depend on Track 1A. `PipeParitySelectionTests` (M1 integration step, after all tracks merge) builds the equivalent `SelectionInput` history for each case, with ordinals assigned as D§4.3 says, runs `InputSelector.select`, and asserts that the selected image is the one the pipe sent.

### 2.4 Response fixtures (parsing)
Location: `ImageGenTests/Fixtures/Responses/` and `Errors/`. Image payloads contain small valid PNG and JPEG byte streams to verify complete decode pipelines:

- **Successful Multimodal Responses**:
  - `resp_text_image.json`: Verifies `.success([.text, .image])` with `STOP` finish reason.
  - `resp_image_text.json`: Verifies part ordering preservation when image precedes text.
  - `resp_two_images.json`: Verifies parsing of multiple synthesized image parts.
  - `resp_adjacent_text.json`: Verifies verbatim concatenation of contiguous text segments into a single `.text` part, trimming only outer boundaries.
  - `resp_split_sentence.json`: Verifies interleaved text and image parts maintain internal whitespace and line breaks without spurious paragraph breaks.
  - `resp_whitespace_run.json`: Verifies whitespace-only text parts are discarded when preceding image content.
  - `resp_thought_parts.json`: Verifies filtering and omission of thought parts (`thought: true`), retaining final synthesized images.
  - `resp_no_mime.json`: Verifies fallback to `image/jpeg` when the MIME type is unspecified.
  - `resp_bad_image.json`: Verifies unparseable image parts are omitted with non-blocking diagnostic notices while retaining valid text parts.
- **Text-Only Responses and Finish Reason Boundaries**:
  - `resp_text_only.json`, `resp_text_only_max_tokens.json`, `resp_text_only_unspecified.json`, `resp_text_only_no_finish.json`: Verifies text-only model replies parse as `.success([.text])` with appropriate metadata footnotes and UI badge derivation.
  - `resp_image_with_safety_finish.json`: Verifies candidate responses retaining valid images are evaluated as `.success` regardless of safety finish reasons.
- **Safety and Policy Refusals**:
  - `resp_prompt_refused.json`: Verifies prompt-level blocks (`promptFeedback.blockReason = PROHIBITED_CONTENT`) parse as `.refused(PROHIBITED_CONTENT)`.
  - `resp_image_safety.json`: Verifies candidate safety blocks without image parts parse as `.refused(IMAGE_SAFETY, finishMessage)`.
  - `resp_finish_no_image.json`, `resp_image_other.json`, `resp_no_image_no_parts.json`, `resp_escalation.json`, `resp_no_parts_other.json`: Verifies various non-standard finish reasons without images evaluate as `.refused`.
  - `resp_refused_with_text.json`: Verifies text returned alongside refused image requests is captured in inspector details rather than rendered as successful reply parts.
  - `resp_unknown_finish_reason.json`: Verifies unrecognized finish reasons pass through verbatim.
  - `resp_pup_limited.json`: Verifies account-level restrictions evaluate as `.refused(PUP_LIMITED_DISABLED)` with retry suppression.
- **Empty and Malformed Payloads**:
  - `resp_empty_candidates.json`, `resp_no_parts_stop.json`, `resp_no_parts_max_tokens.json`, `resp_no_parts_unspecified.json`, `resp_no_parts_no_finish.json`: Verifies empty candidate structures evaluate as `.empty`.
  - `resp_unexpected_shape.json`: Verifies JSON structures missing required Gemini response fields decode as `.empty(nil)`.
  - `resp_malformed.txt`, `resp_html.html`: Verifies truncated JSON or captive-portal HTML payloads evaluate as `.malformed`.
- **API Error Payloads**:
  - `Errors/err_400_invalid_argument.json`: Verifies decoding of HTTP 400 `INVALID_ARGUMENT`.
  - `Errors/err_400_civic.json`: Verifies extraction of `HARM_CATEGORY_CIVIC_INTEGRITY` rejection messages.
  - `Errors/err_400_api_key_invalid.json`: Verifies extraction of `API_KEY_INVALID` reason codes.
  - `Errors/err_402.json`, `Errors/err_403.json`, `Errors/err_404.json`, `Errors/err_503.json`: Verifies extraction of standard API status domains.
  - `Errors/err_429_retryinfo.json`: Verifies extraction of `google.rpc.RetryInfo` backoff delay intervals.
  - `Errors/err_500_text.txt`: Verifies non-JSON server error text truncation to 2 KB.
- **Model Discovery Responses**:
  - `Models/models_page1.json`, `Models/models_page2.json`: Verifies catalog pagination traversal via `nextPageToken`.
  - `Models/models_no_flash.json`: Verifies catalog parsing triggering unlisted default warnings.
  - `Models/model_get_custom.json`: Verifies single-model endpoint validation.

### 2.5 Live smoke test (opt-in)
- `LiveSmokeTests` is tagged `.live` and enabled only when `GEMINI_API_KEY` is in the test process environment.
- Run it with `TEST_RUNNER_GEMINI_API_KEY="$GEMINI_API_KEY" scripts/live-smoke.sh`. xcodebuild forwards `TEST_RUNNER_`-prefixed variables to the test runner without the prefix. The script runs `-only-testing:ImageGenTests/LiveSmokeTests` and never echoes the key.
- It runs through the real `URLSessionTransport` using an ephemeral configuration, plus the real parser:
  1. a text-to-image request with Flash at 1:1/512 (cheap);
  2. an edit of that output, sent as original bytes, at 16:9/2K;
  3. it asserts both are `.success` with an image, and logs the actual pixel sizes for R3/R4 under the OSLog category `smoke`. The 2K edit's size class is the R3 measurement that M9 task 8 acts on.
- Executed on demand when the API key is supplied in the environment. It is excluded from the default `scripts/test.sh` suite via execution tags.

### 2.6 DEBUG harness (`ImageGen/DebugSupport/`, all `#if DEBUG`)
Deterministic testing and simulator execution operate via launch arguments and persisted user defaults without requiring network access or live credentials:

- **`-UITestMockGemini 1`**: Configures `AppEnvironment` with `MockGeminiURLProtocol` over an ephemeral transport and substitutes `InMemoryKeyStore` holding `"mock-key"`, bypassing Keychain access and onboarding screens.
- **`-MockScenario <name>`**: Specifies active mock behavior: `success` (default completion), `textOnly`, `twoImages`, `promptRefused`, `imageSafety`, `imageSafetyThenSuccess`, `imageOther`, `empty`, `malformed`, `rateLimitThenSuccess` (HTTP 429 with 2 s backoff before 200), `badRequest`, `notFound`, `keyRejected`, `civicRejectedOnce`, `lowRes` (1K pixels response), or `wrongAspect` (1:1 response).
- **`-MockLatency <seconds>`**: Configures mock response latency (default 2 seconds; 15 seconds used to capture in-flight progress cards).
- **`-SeedDemoData 1`**: Pre-populates the persistence store with representative test conversations upon initial launch.
- **`-ResetStore 1`**: Wipes local databases, asset directories, and log files prior to initialization via `DebugHooks.resetBeforeLaunchIfRequested(root:)`.
- **`-Scene <name>`**: Directs navigation immediately post-launch (`chatList`, `chat:<seedKey>`, `settings`, `settings:models`, `viewer:<seedKey>`, `onboarding`).
- **`-SeedPasteboardImage 1`**: Seeds a generated test image into `UIPasteboard.general` at launch.
- **`-ForceNotificationState denied`**: Simulates denied system notification permissions in settings interfaces.
- **`-SkipNotificationPrompt 1`**: Defers notification permission requests during automated runs.
- **`-SeedLargeChat 1`**: Generates a high-volume conversation (60 messages, 40 images) to evaluate scrolling and layout reflow performance.

- **`MockGeminiURLProtocol`** builds its responses in code:
  - It parses `imageConfig` from the request body and makes a JPEG at the pixel size from `MockImageSizes` for that aspect and size. The image is a gradient whose hue comes from the prompt's hash, with the prompt and the settings drawn as text.
  - **`MockImageSizes`** is this table of 1K sizes, plus a rule: 512 is exactly half of 1K, 2K is 2× and 4K is 4× (that is how the documented 3.1 Flash table is built). Where this plan quotes the documented values (16:9, 21:9, 1:8, 1:1) they match; the others are close to the documented ones, and every entry passes the app's own checks (aspect within 3%, megapixels within 1.5× of the class). One documented cell is an apparent error, 21:9 at 512 listed as 792×168 (4.7:1); the rule gives 792×336, and a comment in the file notes it.

    | Ratio | 1K | Ratio | 1K | Ratio | 1K |
    |---|---|---|---|---|---|
    | 1:1 | 1024×1024 | 3:4 | 896×1200 | 16:9 | 1376×768 |
    | 2:3 | 848×1264 | 4:3 | 1200×896 | 9:16 | 768×1376 |
    | 3:2 | 1264×848 | 4:5 | 928×1152 | 21:9 | 1584×672 |
    | 1:4 | 512×2048 | 5:4 | 1152×928 | 1:8 | 384×3072 |
    | 4:1 | 2048×512 | 8:1 | 3072×384 | | |

    Values tests and screenshots depend on: 16:9 at 2K = **2752×1536**; 16:9 at 4K = 5504×3072; 9:16 at 4K = 3072×5504; 1:1 at 1K = 1024×1024; 1:8 at 1K = 384×3072; 21:9 at 512 = 792×336. `lowRes` returns the 1K size for the requested ratio; `wrongAspect` returns 1:1 at the requested size.
  - It returns that JPEG base64-encoded in a real `generateContent` JSON shape.
  - It also answers `GET models` with a list of Flash, 3 Pro and 2.1, so in mock mode Flash Lite and 2.5 Flash are "Not listed for this key" and left out of the model menu (the availability filter, D§2.5).
- **`DemoSeeder` seed keys:**
  - `lighthouse`: 3 turns; reply 2 regenerated; the image in turn 1 is pinned;
  - `uploads`: a user message with 3 uploaded images, then a reply;
  - `refused`: a turn with an uploaded image whose reply is refused (`IMAGE_SAFETY`, card "Request refused: IMAGE_SAFETY"), then a turn whose reply is a 429 error card;
  - `textonly`: a text-only reply with Markdown (heading, list, code), so it has the "No image returned" badge;
  - `empty-overrides`: a chat with overrides 9:16 / 4K / 3 Pro, used to show the override dots. Despite the name it is **not** empty: it holds one text-only turn (a user prompt and a short text reply), so `deleteIfEmpty` never removes it and its list row has a snippet. It has no image, so its row shows the placeholder glyph.
  
  Images are generated with the same renderer. Seeded requests are all in terminal states, so the Reconciler leaves them alone. The `lighthouse`, `uploads` and `refused` rows have thumbnails; `textonly` and `empty-overrides` show the placeholder glyph.
- None of this code is compiled into Release builds. `scripts/lint.sh` checks that every file in `DebugSupport/` starts with `#if DEBUG`. Code outside `DebugSupport/` reaches it only through `App/DebugHooks.swift`: its `#if DEBUG` branch calls `LaunchOptions`, `MockGeminiURLProtocol`, `DemoSeeder` and the `-Scene` routing, and its `#else` branch is no-op stubs with the same signatures. `scripts/build.sh --release` proves the Release branch compiles.

### 2.7 Lint (`scripts/lint.sh`, must pass from M1 on)
The patterns are extended regular expressions for `grep -rnE`, written exactly as they go in the script. (They're in a code block, not a table, because a Markdown table would need `\|` for the alternation, and `\|` in `grep -E` on macOS matches a literal `|`, so the rule would never fire.)

```
# rule                                 pattern                                                  scope
no-key-in-urls                         '\?key=|&key='                                           ImageGen/ Platforms/
no-full-decode                         'UIImage\(data:|UIImage\(contentsOfFile:|NSImage\(data:|NSImage\(contentsOf:|NSImage\(contentsOfFile:|NSImage\(byReferencing|NSBitmapImageRep\(data:'    ImageGen/ Platforms/ except DebugSupport/
no-reencoding-exports                  'UIImageWriteToSavedPhotosAlbum|jpegData\(|pngData\(|tiffRepresentation|representation\(using:|NSBitmapImageRep'    ImageGen/Export/ ImageGen/Features/ Platforms/
no-swiftui-in-pure-layers              '^import SwiftUI'                                        ImageGen/{Gemini,Imaging,Pipeline,Security,Networking}/
no-print                               '\bprint\('                                              ImageGen/ except DebugSupport/
no-async-urlsession-for-generation     '\.data\(for:|\.upload\(for:'                            ImageGen/Networking/ ImageGen/Pipeline/
debug-names-only-via-hooks             '\bLaunchOptions\b|MockGeminiURLProtocol|DemoSeeder|SceneRoute'   ImageGen/ except DebugSupport/ and App/DebugHooks.swift
no-key-in-activity-log                 (multiline, perl; see below)                             ImageGen/ Platforms/
debug-guard                            first non-comment line of each DebugSupport/*.swift and of App/DebugHooks.swift is '#if DEBUG'
```

`no-key-in-activity-log` is the one rule that isn't a `grep -E` line, because log calls span several lines (section 2.8's example does). `lint.sh` runs it with `perl -0777 -ne` over each Swift file, so the whole file is one string. It finds every `.begin(`, `.step(` and `.result(` call with its balanced argument list, `\.(?:begin|step|result)\s*(\((?:[^()]++|(?1))*\))`, and fails if the captured arguments match `(?i)api_?key|keyStore|secretRegistry|x-goog-api-key|\.read\(\)`. It catches the key passed on a continuation line, and the usual names for it. It's a tripwire, not the guarantee: a key held in an unrelated variable name gets past it, and `Redactor.forLog(secrets:)` (M1, D§4.13) is what keeps the key out of the log.

`scripts/lint.sh --self-test` copies one planted violation per rule into a temporary directory laid out like `ImageGen/`, runs every rule against it, and fails unless **each** rule reports its violation. For `no-key-in-activity-log` it plants two: a single-line call and a call whose key argument is on a continuation line. Run it once in M1 and whenever a rule changes.

### 2.8 Activity logging (D§4.13; from M2 on)
Every milestone instruments the actions it builds. The contract:
1. **One action per operation.** Each operation in the D§4.13 table is an action, named exactly as the table names it, with origin `user` when a tap started it and `system` otherwise. Work done on behalf of an action is a sub-action (`parent:`, no origin: the store copies the parent's).
2. **Begin first, with every operative parameter.** Call `begin` before doing anything, with every value that decides what the action will do, as the table lists. If a parameter is only known later, log it as a step.
3. **A result on every exit path.** Every path ends with exactly one `result`, with the outcome D§4.13 Outcomes defines: success with the key measurements, or failed (partial failures included, with the counts), refused, cancelled or interrupted with the reason. That includes throws, early returns, cancellation and the background-task expiry. Use a `defer` with a result variable, so no path is missed. A parent with asynchronous sub-actions (Attach, Edit and Resend) puts that `defer` in the function that awaits all of them (a task group), not in the import or clone step, so it ends after its last child. The store's pairing backstop (D§4.13) is a safety net, not the mechanism.
4. **Steps for decisions.** Log a step for each decision the action makes, with its reason: a retry and its delay, a re-prepare, a coercion, a notification not posted.
5. **Terse, with fixed conventions.** One line in natural language, using the D§4.13 conventions (short IDs, MB, seconds, `W×H`, API spellings, ` · ` separators, inputs described by origin). Mark every piece of user-entered or user-derived text with `\(private:)` in the `ActivityMessage`: the prompt, chat titles (old and new), message and copied text, typed custom model IDs, and API messages and error bodies.
6. **Never** the API key, its length, request or response headers, image bytes or base64, or thought signatures. API error bodies go through `Redactor.errorBodyForLog`. `Redactor.forLog(secrets:)` is the guarantee; `ActivityLogRedactionTests` prove it, and the lint rule `no-key-in-activity-log` (section 2.7) is a tripwire for mistakes.7. **Owner logs; pure code doesn't.** Pure functions return what the caller needs to log (sizes, decisions, coercions) instead of logging themselves (D§4.1).
8. **Tests prove it.** Each milestone's test list names the log assertions for its actions, made through `ActivityLogProbe`. Each assertion checks the Begin parameters, the result outcome with its key measurement, and `assertPaired()`.
9. **Flush before handing control to the system.** Await `log.flush()` before calling a background-events completion handler, before ending a background-task assertion (normal or expiry), and before storing an `ActionID` anywhere outside the log (`GenerationRequest.activityActionID`). Otherwise the OS can suspend the app with entries still in the stream, and the next launch closes a finished action as `interrupted` (D§4.13).

```swift
let a = log.begin("Save to Photos", origin: .user,
                  "img \(asset.shortID) · \(mime) · \(bytes.mb) · \(w)×\(h)")
var outcome = ActivityOutcome.failed; var summary: ActivityMessage = "unknown error"
defer { log.result(a, outcome, summary) }
let status = await saver.requestAuthorization()
// … on success:
outcome = .success; summary = "in \(elapsed.s) · authorization \(status) · saved"
```

---

## 3. Milestones and dependencies

```mermaid
graph LR
  M0[M0 Toolchain + scaffold + vocabulary] --> M1[M1 Gemini wire format + pure policies]
  M0 --> M2[M2 Persistence, files, Keychain, settings, activity log]
  M0 --> M3[M3 Imaging + Markdown]
  M1 --> M4[M4 Transport + generation pipeline]
  M2 --> M4
  M3 --> M4
  M4 --> M5[M5 Core UI: onboarding, list, chat, composer, pills, pin]
  M5 --> M6[M6 Attachments, paste, Edit and Resend]
  M5 --> M7[M7 Image actions, export, viewer]
  M5 --> M8[M8 Settings + model availability + storage]
  M6 --> M9[M9 Hardening, accessibility, perf, regression]
  M7 --> M9
  M8 --> M9
  M9 --> M10[M10 Device install + on-device validation]
```

### Milestone Execution Sequence and Module Ownership

Milestone dependencies, concurrency allowances, and module directory boundaries structure development to prevent merge conflicts:

- **Milestone M0 (Toolchain, Scaffold, and Shared Vocabulary):** Acts as the foundational gating milestone with no prerequisites. Owns project scaffolding across the repository, establishing `Pipeline/SharedTypes.swift`, `Support/ActivityLogTypes.swift`, `Support/Logging.swift`, `App/DebugHooks.swift` stubs, and shared test infrastructure.
- **Milestone M1 (API Pipeline Foundation):** Depends on M0. Can execute in parallel with M2 and M3. Owns `Gemini/`, `Pipeline/InputSelector.swift`, `Pipeline/GenerationSettingsResolver.swift`, `Pipeline/RetryPolicy.swift`, along with associated unit test suites and JSON fixtures.
- **Milestone M2 (Persistence, Security, and Activity Log Storage):** Depends on M0. Can execute in parallel with M1 and M3. Owns `Persistence/`, `Security/`, `Settings/`, `Support/ActivityLog.swift`, `Support/ActivityLogStore.swift`, `Support/ActivityLogQuery.swift`, `Support/ActivityLogFormatter.swift`, and `ImageGenTests/Support/ActivityLogProbe.swift`.
- **Milestone M3 (Image Processing and UI Primitives):** Depends on M0. Can execute in parallel with M1 and M2. Owns `Imaging/`, `Support/MarkdownBlocks*.swift`, and their respective test suites.
- **Milestone M4 (Networking, Service Integration, and Transport Parity):** Depends on M1, M2, and M3. Operates sequentially without parallel tracks. Owns `Networking/`, remaining `Pipeline/` components, `App/`, and `DebugSupport/MockGemini*`.
- **Milestone M5 (Core UI, Chat Screen, and Developer Menu):** Depends on M4. View prototyping against seeded demo data can begin once M2 completes, but final integration merges strictly after M4. Owns `Features/ChatList`, `Features/Chat`, `Features/Onboarding`, `Features/Developer`, `DebugSupport/DemoSeeder`, and `DebugSupport/LaunchOptions`.
- **Milestone M6 (Attachments, Import, and Multimodal Composer):** Depends on M5. Can execute concurrently with M7 and M8. Owns `Features/Chat/Composer/*Attachment*`, `AttachmentTray.swift`, `PasteSupport.swift`, `Features/Chat/ChatScreenModel+Attachments.swift`, and the Edit and Resend actions in `MessageActionsMenu.swift`.
- **Milestone M7 (Image Actions, Export, and Full-Screen Viewer):** Depends on M5. Can execute concurrently with M6 and M8. Owns `Export/`, `Features/Viewer/`, and item action implementations in `Features/Chat/ImageContextMenu.swift`.
- **Milestone M8 (Settings, Model Availability, and Storage Management):** Depends on M5. Can execute concurrently with M6 and M7. Owns `Features/Settings/` and UI data bindings for `Pipeline/ModelAvailabilityService.swift`.
- **Milestone M9 (Hardening, Accessibility, Performance, and Regression):** Depends on M6, M7, and M8. Operates sequentially across the entire codebase focusing exclusively on quality, accessibility, performance bounds, and stability fixes without introducing new features.
- **Milestone M10 (Device Installation and On-Device Validation):** Depends on M9. Performs physical hardware validation and on-device execution checks.

**Activity log.** Its vocabulary is in M0, and its storage, facade, queries and formatter are in M2. The first code that logs is M2's Janitor. M1 and M3 are pure and don't log (section 2.8 rule 7). From M4 on, every milestone instruments its own actions under the section 2.8 contract. M5 adds the Developer menu and the log viewer. No new dependency edges are needed: everything that logs depends on M2 already.

**Parallel tracks within M1:** 1A (catalog consumers: `GenerationSettingsResolver` and `InputSelector`), 1B (`RequestBodyWriter`, `GeminiEndpoint`, the pipe fixtures), 1C (`ResponseModels`, `ResponseParser`, `Redactor`, `GeminiErrorBody`), 1D (`RetryPolicy`). They share only what M0 defines: the vocabulary and `Pipeline/SharedTypes.swift` (which includes `EffectiveSettings`, `Coercion` and the selector types). No track calls another track's code: 1B tests build `EffectiveSettings` and input lists by hand. Whatever needs two tracks together runs in the **M1 integration step** after all four have merged (see M1).

**Shared types rule.** Every `Sendable` DTO that crosses a milestone or layer boundary is defined in M0's `Pipeline/SharedTypes.swift`, with the full field lists given there. The one exception is the activity-log vocabulary, which is in M0's `Support/ActivityLogTypes.swift`, because every layer logs and `Support/` must not depend on `Pipeline/`. Later milestones add behavior (functions, extensions) but never redefine or move these types. If a milestone needs a new field, it adds it to `SharedTypes.swift` and notes it in the change log.

**Merge protocol for parallel development tracks.**
1. Each track works in its own worktree on branch `m<n>-<track>`.
2. Before merging, rebase on `main` and run `scripts/gen.sh && scripts/test.sh && scripts/lint.sh && scripts/check-warnings.sh`.
3. Merge in this order: M1 tracks A→D, then the M1 integration step, then M2, then M3; M6, then M7, then M8.
4. The shared files `MessageActionsMenu.swift` and `ImageContextMenu.swift` are created by M5 with clearly marked `// MARK: M6 items` and `// MARK: M7 items` sections, so later edits don't overlap.

---

## M0: Toolchain, scaffold and shared vocabulary

**Goal.** A buildable, testable, launchable empty app produced from `project.yml`. Scripts exist. The shared value types exist, so M1, M2 and M3 can run in parallel.

**Step 0: toolchain (needs the user).** Run `scripts/doctor.sh` (written first). If it fails, stop and ask the user to run these in Terminal, then re-run doctor:
```
mv ~/Downloads/Xcode.app /Applications/Xcode.app          # optional; env.sh also finds ~/Downloads/Xcode.app
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
brew install xcodegen
```

**Files and types**
- `project.yml`, `Config/Base.xcconfig`, `Config/Local.xcconfig.example`, `.gitignore`, and every script in section 1.2, made executable. `live-smoke.sh` and `device-install.sh` can be stubs that print "available from M4/M10".
- `ImageGen/App/ImageGenApp.swift`: `@main struct ImageGenApp: App` with a `NavigationStack { Text("Chats").navigationTitle("Chats") }`, plus `@UIApplicationDelegateAdaptor(AppDelegate.self)`.
- `ImageGen/App/AppDelegate.swift`: `final class AppDelegate: NSObject, UIApplicationDelegate`, with empty hooks for `didFinishLaunching` and `handleEventsForBackgroundURLSession` (filled in M4).
- `ImageGen/Resources/Assets.xcassets`: AppIcon (single 1024 image, a simple generated glyph) and AccentColor.
- **Vocabulary**, `ImageGen/Gemini/Vocabulary.swift` (pure, `Sendable`, `Codable`, `CaseIterable`):
  - `enum AspectRatio: String`: `r1x1="1:1"`, `r1x4="1:4"`, `r4x1="4:1"`, `r1x8="1:8"`, `r8x1="8:1"`, `r2x3="2:3"`, `r3x2="3:2"`, `r3x4="3:4"`, `r4x3="4:3"`, `r4x5="4:5"`, `r5x4="5:4"`, `r9x16="9:16"`, `r16x9="16:9"`, `r21x9="21:9"`. It has `var group: AspectGroup` (`.landscape/.square/.portrait/.extreme`, grouped as in D§3.5) and `var ratio: Double`.
  - `enum ImageSize: String`: `s512="512"`, `s1K="1K"`, `s2K="2K"`, `s4K="4K"`. It has `var nominalMegapixels: Double` (0.262 / 1.05 / 4.19 / 16.8) and `displayName` ("512 px", "1K (~1 MP)", and so on).
  - `enum SafetyThreshold: String`, every raw value spelled out: `blockNone = "BLOCK_NONE"`, `blockOnlyHigh = "BLOCK_ONLY_HIGH"`, `blockMediumAndAbove = "BLOCK_MEDIUM_AND_ABOVE"`, `blockLowAndAbove = "BLOCK_LOW_AND_ABOVE"`.
  - `enum HarmCategory: String`, in the pipe's order, which is also the `allCases` and wire order: `harassment = "HARM_CATEGORY_HARASSMENT"`, `hateSpeech = "HARM_CATEGORY_HATE_SPEECH"`, `sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"`, `dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"`, `civicIntegrity = "HARM_CATEGORY_CIVIC_INTEGRITY"`.
  - `enum SelectionReason: String`: `attachments`, `pinned`, `latest`, `noImage = "none"`. The case is deliberately not named `none`: in an optional context (`SelectionReason(rawValue:)` returns one) `.none` resolves to `Optional.none` with an "assuming you mean Optional.none" warning, which would break the zero-warnings rule and silently compare against nil. The stored value stays `"none"`.
  - `enum RequestState: String`: `preparing`, `inFlight`, `retryScheduled`, `parsing`, `succeeded`, `refused`, `failed`, `cancelled`, `interrupted`. It has `isTerminal` and `isLive`.
  - `struct ModelCapability`: `aspectRatios: [AspectRatio]`, `imageSizes: [ImageSize]` (empty means the `imageSize` key is omitted), `sendsImageConfig: Bool`, `highFidelityInputLimit: Int` (the soft tray-warning threshold from D§2.5; 14 means "no soft warning").
  - `struct ModelDescriptor: Identifiable`: `id`, `displayName`, `shortName` ("3.1 Flash"), `capability`, `role` (`.defaultMandatory`, `.optional(enabledByDefault:)`, `.legacyIfListed`, `.custom`).
  - `enum ModelCatalog`: `defaultModelID = "gemini-3.1-flash-image"`, `builtIns` (the D§2.5 table, exactly):

    | ID | shortName | role | ratios | sizes | `highFidelityInputLimit` |
    |---|---|---|---|---|---|
    | `gemini-3.1-flash-image` | 3.1 Flash | `.defaultMandatory` | 14 | 512, 1K, 2K, 4K | 10 |
    | `gemini-3-pro-image` | 3 Pro | `.optional(enabledByDefault: true)` | 10 standard | 1K, 2K, 4K | 5 |
    | `gemini-nano-banana-2.1` | 2.1 | `.optional(enabledByDefault: true)` | 14 | 1K, 2K, 4K | 10 |
    | `gemini-3.1-flash-lite-image` | 3.1 Flash Lite | `.optional(enabledByDefault: true)` | 10 standard | 1K | 14 |
    | `gemini-2.5-flash-image` | 2.5 Flash | `.optional(enabledByDefault: true)` | 10 standard | none (omit `imageSize`) | 3 |
    | `gemini-3-pro-image-preview` | 3 Pro (preview) | `.legacyIfListed` | as 3 Pro | as 3 Pro | 5 |

    `descriptor(for id: String) -> ModelDescriptor`: unknown IDs get the custom capability (all 14 ratios, 1K/2K/4K, `highFidelityInputLimit` 14). Every built-in has `sendsImageConfig = true`. `static let builtInIDs: Set<String>` holds every built-in ID; every one is enabled by default (D§11 Q1), and the availability filter in the model menu decides which are shown. The non-Flash IDs aren't all confirmed against a real key, so they stay validated at runtime (`models.list`, and the 404 card).
- **Shared types**, `ImageGen/Pipeline/SharedTypes.swift` (pure; `Sendable`; `Codable` where stored as JSON). These are the DTOs that cross milestones or layers, defined here with their full field lists so M1, M2 and M3 can compile in parallel (section 3, Shared types rule). Later milestones add behavior only.
  ```swift
  enum Role: String, Sendable, Codable { case user, model }
  enum ImageOrigin: String, Sendable, Codable { case photos, files, paste, model }

  // Settings resolution (behavior: M1 Track 1A)
  struct GenerationDefaults: Sendable, Equatable {        // snapshot of AppSettings
    var aspectRatio: AspectRatio = .r16x9; var imageSize: ImageSize = .s2K
    var threshold: SafetyThreshold = .blockNone; var omitCivicIntegrity = false
    var includeTextModality = true                         // flipped to false by M9 task 8 if R3's 1K cap is confirmed
    var enabledModelIDs: Set<String> = ModelCatalog.builtInIDs  // every catalog ID by default ∪ custom IDs; always has Flash
    var maxUploadLongEdge = 2048                           // 1536 / 2048 / 3072 / 4096
  }
  struct ChatOverrides: Sendable, Equatable { var modelID: String?; var aspectRatio: AspectRatio?; var imageSize: ImageSize? }
  enum CoercionField: String, Sendable, Codable { case model, aspectRatio, imageSize }
  struct Coercion: Sendable, Codable, Equatable { var field: CoercionField; var requested: String; var used: String?; var reason: String }  // used == nil: key omitted
  struct EffectiveSettings: Sendable, Codable, Equatable {
    var modelID: String; var aspectRatio: AspectRatio?; var imageSize: ImageSize?
    var threshold: SafetyThreshold; var categories: [HarmCategory]; var includeTextModality: Bool
    var coercions: [Coercion]                              // for the pill caution glyph; empty in recorded snapshots
  }

  // Input selection (behavior: M1 Track 1A)
  struct SelectorImage: Sendable, Equatable { let id: UUID; let ordinal: Int }
  struct SelectorMessage: Sendable, Equatable { let sequence: Int; let role: Role; let replyState: RequestState?; let images: [SelectorImage] }
  struct SelectionInput: Sendable { var attachments: [UUID]; var pinnedImageID: UUID?; var pinnedImageExists: Bool
                                    var history: [SelectorMessage] }   // no skip-the-image flag (D§2.2)
  struct Selection: Sendable, Equatable { let imageIDs: [UUID]; let reason: SelectionReason; let clearPin: Bool }

  // Images (behavior: M3)
  struct PreparedImage: Sendable, Equatable { let url: URL; let mimeType: String; let byteCount: Int
                                              let pixelWidth: Int; let pixelHeight: Int; let longEdgeSetting: Int }
  struct StagedAttachment: Sendable, Equatable { let id: UUID; let origin: ImageOrigin; let originalURL: URL; let originalMimeType: String
                                                 let originalByteCount: Int; let pixelWidth: Int; let pixelHeight: Int
                                                 let originalFilename: String?; let prepared: PreparedImage }

  // Stored JSON payloads (D§4.3)
  struct MessagePart: Sendable, Codable, Equatable { enum Kind: String, Sendable, Codable { case text, image }
                                                     var kind: Kind; var text: String?; var imageID: UUID? }
  struct RequestInput: Sendable, Codable, Equatable { var imageID: UUID; var preparedRelativePath: String   // the bytes actually sent
                                                      var mimeType: String; var byteCount: Int; var pixelWidth: Int; var pixelHeight: Int }

  // UI → GenerationService (behavior: M4)
  struct SendDraft: Sendable { var conversationID: UUID; var promptText: String; var attachments: [StagedAttachment]  // tray order
                               var settings: EffectiveSettings }

  // DataStore boundary (behavior: M2)
  struct SendRecordInput: Sendable { var conversationID: UUID; var promptText: String; var attachments: [StagedAttachment]  // index = ordinal
                                     var selection: Selection; var settings: EffectiveSettings
                                     var activityActionID: ActionID }      // the Send action (D§4.13)
  struct SendRecord: Sendable, Equatable { let requestID: UUID; let userMessageID: UUID; let replyMessageID: UUID }
  struct InputSnapshot: Sendable, Equatable { let imageID: UUID; let conversationID: UUID; let origin: ImageOrigin
                                              let originalRelativePath: String; let originalMimeType: String
                                              let prepared: RequestInput?          // uploads: the ImageAsset.prepared* fields; model outputs: nil
                                              let preparedLongEdgeSetting: Int? }
  struct RequestSnapshot: Sendable, Equatable {
    let id: UUID; let conversationID: UUID; let userMessageID: UUID?; let replyMessageID: UUID; let sourceRequestID: UUID?
    let settings: EffectiveSettings                        // as recorded
    let promptText: String; let inputs: [RequestInput]; let inputAssets: [InputSnapshot]; let selectionReason: SelectionReason
    let state: RequestState; let attempt: Int; let maxAutoRetries: Int; let autoRetriesUsed: Int; let civicFallbackUsed: Bool
    let nextAttemptCreatedInBackground: Bool; let taskIdentifier: Int?; let nextAttemptAt: Date?; let startedAt: Date?
    let activityActionID: ActionID?                        // the action following this request (D§4.3, D§4.13)
  }
  struct RequestPatch: Sendable {                          // nil = unchanged; for Int?? / Date??, .some(nil) clears
    var state: RequestState?; var attempt: Int?; var autoRetriesUsed: Int?; var civicFallbackUsed: Bool?
    var nextAttemptCreatedInBackground: Bool?; var taskIdentifier: Int??; var nextAttemptAt: Date??
    var startedAt: Date?; var completedAt: Date?; var categories: [HarmCategory]?; var inputs: [RequestInput]?
    var httpStatus: Int?; var errorStatus: String?; var errorMessage: String?; var details: String?; var notices: [String]?
    var finishReason: String?; var refusalReason: String?; var modelVersion: String?; var responseID: String?
    // A refusal writes refusalReason = reason and errorMessage = finishMessage (D§2.7); a Retry clears both (D§6).
    var outputWidth: Int?; var outputHeight: Int?
    var activityActionID: ActionID?                        // a manual Retry points the request at its Retry action
  }
  ```
- **Activity-log vocabulary**, `ImageGen/Support/ActivityLogTypes.swift` (pure; `Sendable`; `Codable`; behavior in M2; D§4.13):
  ```swift
  struct ActionID: Sendable, Codable, Hashable, CustomStringConvertible { let raw: String }   // 4 lowercase hex digits
  enum ActivityKind: String, Sendable, Codable { case begin, step, result }
  enum ActivityOrigin: String, Sendable, Codable { case user, system }
  enum ActivityOutcome: String, Sendable, Codable { case success, failed, refused, cancelled, interrupted }
  struct ActivityEntry: Sendable, Codable, Equatable {
    var timestamp: Date                                    // ISO 8601 with milliseconds in the file
    var actionID: ActionID; var parentID: ActionID?; var name: String; var kind: ActivityKind
    var origin: ActivityOrigin?                            // begin only; the store fills it for sub-actions
    var outcome: ActivityOutcome?                          // result only
    var relatedID: ActionID?                               // Late completion begin only: the original action
    var message: String
  }
  struct ActivityLogStatus: Sendable, Equatable {          // published by changes() (M2)
    var lastSequence: Int; var lastActionID: ActionID?; var lastErrorID: ActionID?
  }
  ```
  `ActivityOutcome` has no `empty` case on purpose: an empty reply's Send ends `failed` (D§4.13 Outcomes).
- `ImageGen/Support/Logging.swift`: `Logger` instances for the D§7 categories (`pipeline`, `transport`, `store`, `imaging`) plus `smoke`, with subsystem `<bundleID>`. From M2 on, the activity log mirrors every entry through these (D§4.13); later milestones log through `ActivityLog`, not `Logger` directly, except for DEBUG-only diagnostics (`DecodeTimer`, the `phys_footprint` lines) and the smoke test.
- `ImageGen/App/DebugHooks.swift`: the single entry point from non-DEBUG code into `DebugSupport/` (section 2.6). In M0 its DEBUG and Release branches are both empty stubs; M4 and M5 fill in the DEBUG branch.
- `ImageGen/Support/PlatformProbe.swift`: an unused view and function that touch `glassEffect`, `GlassEffectContainer`, `.safeAreaBar`, `.buttonStyle(.glassProminent)`, a `@concurrent` function, `Synchronization.Mutex` and a `@ModelActor`. It exists only so a missing or renamed iOS 26 API fails the M0 build (risk P8). Delete it in M9.
- `ImageGenTests/VocabularyTests.swift`.
- **Shared test support** (owned by M0, so the parallel M1, M2 and M3 tracks don't each write their own), in `ImageGenTests/Support/`:
  - `BundleToken.swift` (a `final class` for `Bundle(for:)`);
  - `TestFileRoot.swift` (a per-test temporary directory, removed in `deinit`);
  - `FixtureLoader.swift` (`url(_:)`, `data(_:)` from the bundled `Fixtures/` folder);
  - `ImageFactory.swift` (ImageIO-made JPEG, PNG with or without alpha, HEIC with or without alpha, and GIF, with orientation and GPS options);
  - `MockURLProtocol.swift` (section 2.2: the per-URL response queue, chunking, delay, the per-test token registry, and request plus body recording).
  M2 adds `InMemoryStore.swift`, because it needs the schema.
- `scripts/gen_image_fixtures.swift` and the four binaries it writes to `ImageGenTests/Fixtures/Images/` (section 2.2). With `--large <path>` it instead writes an 8064×6048 JPEG for manual simulator checks (never checked in).

**Implementation notes.** D§10, D§2.5. Add no logic beyond the tables and the shared types. The raw values are the exact API strings, all written out.

**Tests**
- `VocabularyTests`:
  - `allAspectRatioRawValues` (14 values, exact strings);
  - `imageSizeRawValuesUppercaseK` (`"512"`, `"1K"`, `"2K"`, `"4K"`);
  - `safetyThresholdRawValues` (the four `BLOCK_*` strings);
  - `harmCategoryRawValuesAndOrder` (the five `HARM_CATEGORY_*` strings, in the pipe's order);
  - `selectionReasonNoImageStoresNone`;
  - `flashSupportsAll14AndAllSizes`;
  - `proExcludesExtremeAndNo512`;
  - `nanoBanana21No512`;
  - `flashLiteOnly1KAndStandardRatios`;
  - `flash25OmitsImageSize`;
  - `highFidelityLimitsMatchDesign` (10, 5, 10, 14, 3, 5, and 14 for custom);
  - `unknownIDGetsCustomCapability`;
  - `defaultModelIsFlash`;
  - `everyBuiltInEnabledByDefault` (every `.optional` role has `enabledByDefault: true`, and `GenerationDefaults().enabledModelIDs == ModelCatalog.builtInIDs`).
- `TestSupportTests`: `mockURLProtocolServesQueueInOrder`; `testFileRootIsRemoved`; `fixtureImagesDecode` (the four binaries decode, and `rotated_exif6.jpg` has orientation 6).
- `ActivityLogTypesTests`: `entryJSONRoundTrip` (the keys are exactly `timestamp`, `actionID`, `parentID`, `name`, `kind`, `origin`, `outcome`, `relatedID`, `message`, with nil values omitted; the timestamp keeps milliseconds); `outcomeAndKindRawValues`.

**Simulator verification**
- `scripts/sim.sh ensure && scripts/build.sh && scripts/run-sim.sh`, then `scripts/shot.sh M0 01-launch`.

**Done when**
- [ ] `scripts/doctor.sh` exits 0, printing Xcode ≥ 26, an iOS ≥ 26 runtime and XcodeGen ≥ 2.46.
- [ ] `scripts/gen.sh` succeeds on a clean clone **without** `Config/Local.xcconfig`.
- [ ] `scripts/build.sh` and `scripts/build.sh --release` succeed; `scripts/check-warnings.sh` reports 0 warnings.
- [ ] `scripts/test.sh` passes, and `VocabularyTests` appears in the log with 13 or more passing tests, plus `TestSupportTests`.
- [ ] `Pipeline/SharedTypes.swift` and `Support/ActivityLogTypes.swift` compile with every type listed above, `ActivityLogTypesTests` passes, and the four fixture images exist (each within its size limit).
- [ ] `artifacts/M0/01-launch.png` shows a "Chats" large title on the iOS 26 simulator.
- [ ] `git status` shows no generated project or build output tracked.

---

## M1: Gemini wire format and pure policies

**Goal.** Every rule in D§2 that can be pure is implemented and proven by tests, including byte-level pipe parity.

### Track 1A: settings resolution and input selection
**Files and types**
The input and output types (`GenerationDefaults`, `ChatOverrides`, `EffectiveSettings`, `Coercion`, `SelectorImage`, `SelectorMessage`, `SelectionInput`, `Selection`) are already in M0's `SharedTypes.swift`; this track adds only the behavior.
- `Pipeline/GenerationSettingsResolver.swift`:
  ```swift
  enum GenerationSettingsResolver {
    static func resolve(_ o: ChatOverrides, _ d: GenerationDefaults, catalog: (String) -> ModelDescriptor) -> EffectiveSettings
  }
  ```
- `Pipeline/InputSelector.swift`:
  ```swift
  struct TrayCounts: Sendable, Equatable { var ready: Int; var pending: Int; var failed: Int }   // pending = importing or preparing
  enum InputSelector {
    static func select(_ input: SelectionInput) -> Selection
    static func implicitBase(history: [SelectorMessage]) -> UUID?   // drives the informational "Editing latest image" chip
    static func canSend(trimmedText: String, tray: TrayCounts, chatHasLiveRequest: Bool) -> Bool
  }
  ```

**Notes.** D§2.2 and D§2.5.
- Rule 3 skips **model** messages whose `replyState != .succeeded`. User messages are always eligible, matching the pipe (D§2.2, as clarified). Within the chosen message it takes the highest `ordinal` (D§4.3 defines how ordinals are assigned).
- There is no input that skips rule 3: `.noImage` is returned only when there are no attachments, no usable pin and no image in `history` (D§2.2, user decision 2026-10-16).
- `SelectionInput.attachments` holds only ready tray items. `canSend` is false while `tray.pending > 0` or `tray.failed > 0`, or while the chat has a live request; otherwise it's true when the trimmed text is non-empty or `tray.ready > 0` (D§2.2).
- Model: the override is used only if it's in `d.enabledModelIDs`; otherwise the result is Flash with a `Coercion(field: .model, …)` (D§2.5 step 1).
- Coercion: an unsupported aspect becomes 16:9 if supported, else 1:1. An unsupported size becomes the nearest supported size, preferring the larger. An empty `imageSizes` means `imageSize = nil`.
- `categories` holds all 5, or 4 when `omitCivicIntegrity` is set.

**Tests**
- `SettingsResolverTests`, parameterized:
  - `defaultsAre16x9And2K`;
  - `perChatOverridesWin`;
  - `clearingOverrideFallsBackToDefault`;
  - `proCoerces1x8To16x9`;
  - `proCoerces512To1K`;
  - `flashLiteCoerces2KTo1K` and `flashLiteCoerces1x8To16x9` (the real catalog entry);
  - `flash25OmitsImageSize`;
  - `oneKOnlyCapabilityCoercesAll`;
  - `customModelPassesThrough4K21x9`;
  - `disabledModelOverrideFallsBackToFlash` and `removedCustomIDOverrideFallsBackToFlash` (both reported as a `.model` coercion);
  - `coercionIsReported`;
  - `omitCivicGivesFourCategories`.
- `InputSelectorTests`, table-driven, one row per D§9 suite-1 bullet:
  - `attachmentsWinAndClearPin`;
  - `pinUsedWhenNoAttachmentsAndCleared`;
  - `pinnedUserUploadSelected`;
  - `pinnedAssetMissingFallsThroughToLatest`;
  - `latestSkipsFailedReplies` (failed and refused model replies are both skipped);
  - `latestTakesHighestOrdinal`;
  - `userUploadNewerThanModelOutputWins`;
  - `latestSkipsTextOnlySucceededReply`;
  - `noImagesGivesNoImage` (`.noImage` only when the history holds no image);
  - `canSendRules` (text only; ready attachments only; neither; live request; one item pending with text; one item failed with text; only a failed item and no text — all but the first two are false).

### Track 1B: request body and endpoint
**Files and types**
- `Gemini/GeminiEndpoint.swift`:
  - `static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!`;
  - `func generateContentRequest(modelID:apiKey:bodySize:) -> URLRequest` (POST; headers `Content-Type`, `Accept`, `x-goog-api-key`);
  - `listModels(pageToken:apiKey:)` with `pageSize=1000`;
  - `getModel(id:apiKey:)`.
  - Model IDs are percent-encoded as path segments.
- `Gemini/RequestBodyWriter.swift`:
  ```swift
  struct BodyImage: Sendable { let fileURL: URL; let mimeType: String; let byteCount: Int }
  struct RequestBodySpec: Sendable { let images: [BodyImage]; let promptText: String?; let settings: EffectiveSettings }
  enum RequestBodyWriter {
    static func predictedSize(_ spec: RequestBodySpec) throws -> Int
    @concurrent static func write(_ spec: RequestBodySpec, to url: URL) async throws -> Int   // returns bytes written
  }
  enum RequestBodyError: Error { case emptyParts                                   // no images and no text (D§2.2)
                                 case imageSizeMismatch(index: Int, expected: Int, actual: Int) }   // file changed since byteCount was read
  ```
  `EffectiveSettings` comes from M0's shared types; tests construct it by hand.
  - Build the envelope as `Encodable` structs whose image `data` values are unique placeholder strings (`"__IMG_<uuid>_<i>__"`).
  - Encode with `JSONEncoder` using `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`.
  - Split the encoded bytes at each placeholder (the quotes stay in the envelope). Write the envelope segments and stream base64 for each image from a `FileHandle` in 48 KiB (49,152-byte) reads, which is a multiple of 3, so only the last chunk gets padding.
  - `predictedSize` = envelope bytes − placeholder bytes + Σ `4*ceil(n/3)`.
- `scripts/gen_pipe_fixtures.py` and the `Fixtures/PipeReference/*` files it produces (all eight cases), built from M0's `Fixtures/Images/tiny_16x9.png` and `tiny_square.jpg`.

**Notes.**
- D§2.4. Key order in the body has no meaning to the API. `.sortedKeys` makes the bytes deterministic, and golden files compare structurally (D§2.4, as updated).
- The text part is omitted when the trimmed prompt is empty.

**Tests**
- `RequestBodyWriterTests`:
  - every golden case in section 2.3;
  - `imagesBeforeText`;
  - `emptyPartsThrows`;
  - `predictedSizeEqualsWrittenSize` (parameterized over 0, 1, 2 and 3 images, sizes n ≡ 0, 1, 2 mod 3, and a 5 MB image);
  - `noFullBodyInMemory`: write a 15 MB input and assert that `phys_footprint` growth stays under 8 MB, using `task_info`. This one is tagged `.io` and allows some tolerance.
- `PipeParityTests`: the eight cases in section 2.3, with hand-built inputs.
- `EndpointTests`:
  - `urlHasNoKeyQuery`;
  - `headerCarriesKey`;
  - `methodIsPost`;
  - `contentLengthMatchesBodySize`;
  - `modelIDPercentEncoded`;
  - `listModelsUsesPageSize1000AndToken`.

### Track 1C: response parsing and redaction
**Files and types**
- `Gemini/ResponseModels.swift`: `Decodable` structs with every field optional — `GenerateContentResponse`, `Candidate`, `Content`, `Part` (`text`, `inlineData{mimeType,data: String}`, `thought`, `thoughtSignature`), `PromptFeedback`, `UsageMetadata` (ignored).
- `Gemini/GeminiErrorBody.swift`: `{error:{code,message,status,details:[AnyJSON]}}`, plus helpers `retryDelay` (from `google.rpc.RetryInfo`) and `reason` (from `google.rpc.ErrorInfo`, for example `API_KEY_INVALID`).
- `Gemini/ResponseParser.swift`:
  ```swift
  struct StoredOutputImage: Sendable, Equatable { let fileURL: URL; let mimeType: String; let byteCount: Int; let pixelWidth: Int; let pixelHeight: Int }
  enum OutputPart: Sendable, Equatable { case text(String); case image(StoredOutputImage) }
  enum ParsedOutcome: Sendable { case success(parts: [OutputPart], finishReason: String?, notices: [String], modelVersion: String?, responseID: String?, details: String)
                                 case refused(reason: String, message: String?, notices: [String], details: String)   // reason verbatim, D§2.7 rules 3 and 6
                                 case empty(finishReason: String?, details: String)
                                 case apiError(httpStatus: Int, status: String?, message: String, details: String)
                                 case malformed(details: String) }
  enum ResponseParser { @concurrent static func parse(httpStatus: Int, bodyURL: URL, outputDirectory: URL) async throws -> ParsedOutcome }   // throws only when writing an image fails (D§6 #27)
  ```
  The parser writes each decoded image straight to `outputDirectory/<uuid>.<ext>`; in the app the caller always passes `Requests/<id>/out-<attempt>/` (D§4.4). `GenerationService` later moves the files into `Images/<conv>/` (D§2.7, as updated). Text parts follow D§2.7 rule 5 exactly: consecutive parts concatenated verbatim with no separator, each run trimmed only at its two ends, whitespace-only runs dropped. Refusals follow D§2.7 rules 3 and 6: `promptFeedback.blockReason`, or no surviving image with a `finishReason` outside {`STOP`, `MAX_TOKENS`, `FINISH_REASON_UNSPECIFIED`}, gives `.refused` with the reason verbatim (unknown reasons included, and `ESCALATION` and `PUP_LIMITED_DISABLED` too). Text parts of a refused candidate never become `OutputPart`s; they stay only in `details`. `.empty` is only for no candidates, or no parts with `STOP`/`MAX_TOKENS`/`FINISH_REASON_UNSPECIFIED`/missing. Rule 6 is tested on both sides: a decodable image with a refusing finish reason is `.success` with a footnote, an only-undecodable image with one is `.refused`, and each non-refusing reason (including a missing one) is checked on a no-parts and a text-only candidate. The refusal `message` (`finishMessage`) goes to `RequestPatch.errorMessage`.
- `Gemini/Redactor.swift`: pretty-prints JSON, replaces `inlineData.data` with `"<N bytes mime>"` and `thoughtSignature` with `"<redacted>"`, and caps the output at 64 KB. For the activity log (D§4.13) it also has:
  - `static func forLog(secrets: @escaping @Sendable () -> [String]) -> @Sendable (String) -> String`, which builds the sanitizer M4 injects into `ActivityLog` (M4 passes `{ secretRegistry.all }`, M2's `Security/SecretRegistry`; Track 1C takes only the closure, so it doesn't depend on M2). The sanitizer replaces every non-empty string the closure returns, and any text shaped like a Gemini key (`AIza[0-9A-Za-z_-]{35}`), with `<key removed>`, wherever it appears; replaces any `key=` query value with `key=<key removed>`; replaces `inlineData.data` and `thoughtSignature` values and any base64-like run of 100 or more characters (`[A-Za-z0-9+/]{100,}`, the same pattern as `redactedDetailsHaveNoLongBase64`) with `<N chars removed>`; and removes any text from `x-goog-api-key` to the end of its line. Secrets are replaced first, so a key inside a longer run is still caught. Everything else, including the prompt, is unchanged;
  - `static func errorBodyForLog(_ body: String) -> String`: the first 2 KB (cut at a UTF-8 boundary), then `… (+N bytes)`.
- `Gemini/MimeTypes.swift`: maps MIME types to extensions and `UTType` (D§4.4).

**Tests**
- `ResponseParserTests`: every row in section 2.4, plus:
  - `imagesWrittenByteIdenticalToDecodedBase64`;
  - `redactedDetailsHaveNoLongBase64` (regex `[A-Za-z0-9+/]{100,}` doesn't match);
  - `detailsCappedAt64KB`;
  - `errorBodyFirst2KBForNonJSON`;
  - `parsesFromMappedFileOfThirtyMB` (generated in the test).
- `RedactorTests`: nested arrays; thought signatures; no change to non-data strings; `forLogRemovesBase64Runs`; `forLogRemovesInlineDataAndThoughtSignature`; `forLogRedactsKeyQuery`; `forLogRemovesRegisteredSecretAnywhere` (a secret that isn't key-shaped, inside a prompt, a sentence and a URL path); `forLogRemovesKeyShapedText` (a 39-character `AIza…` value with no `key=` and no registration); `forLogDropsApiKeyHeaderText`; `forLogKeepsPromptText` (quotes, newlines and emoji unchanged); `errorBodyForLogCapsAt2KB`.

### Track 1D: retry policy
**Files and types.** `Pipeline/RetryPolicy.swift`:
```swift
enum AttemptResult: Sendable { case http(status: Int, headers: [String: String], bodyBytes: Int, error: GeminiErrorBody?)
                               case transport(URLError.Code, elapsed: Duration)   // since the attempt's task began
                               case cancelled }
enum RetryDecision: Sendable, Equatable { case retry(after: Duration); case rebuildWithoutCivicAndRetry; case finish }
struct RetryPolicy: Sendable {
  var maxAutoRetries = 2; var base: Duration = .seconds(2); var cap: Duration = .seconds(60)
  var resourceTimeout: Duration = .seconds(1800)   // = timeoutIntervalForResource (D§4.6)
  var jitter: @Sendable () -> Double            // 0..<1, injectable for tests
  func decide(_ r: AttemptResult, autoRetriesUsed: Int, civicWasSent: Bool, civicFallbackUsed: Bool) -> RetryDecision
}
```
**Notes.** This follows D§6's retry policy exactly:
- one shared budget: every retryable cause returns `.finish` once `autoRetriesUsed >= maxAutoRetries`;
- `.transport(.timedOut, elapsed)` is retryable only when `elapsed < resourceTimeout` (the idle timeout); at or beyond it, it's the resource timeout and the result is `.finish`;
- the delay is `base × 2^autoRetriesUsed` plus jitter, unless `RetryInfo` or `Retry-After` says otherwise (capped at 60 s);
- the CIVIC case returns `.rebuildWithoutCivicAndRetry` only when `civicWasSent && !civicFallbackUsed`, and doesn't use the budget;
- an empty 200 body is retryable (#33);
- a refusal is never retried: it arrives as a 2xx with a non-empty body, which always gives `.finish` (D§6, refusals are the user's choice to retry), and it never gives `.rebuildWithoutCivicAndRetry`.

The caller passes the persisted `autoRetriesUsed` and `civicFallbackUsed` from the request record (M2 schema), never in-memory counters.
**Tests.** `RetryPolicyTests`:
- `statusMatrix` (parameterized over 200 with a body, 200 empty, 400, 400 civic, 401, 402, 403, 404, 408, 429, 500, 502, 503 and 504);
- `urlErrorMatrix`: `.timedOut` at 299 s → retry; `.timedOut` at 1800 s → finish; `.networkConnectionLost`, `.notConnectedToInternet`, `.cannotConnectToHost` → retry; `.badURL`, `.secureConnectionFailed` → finish;
- `sharedBudgetAcrossCauses` (a 429, then a timeout, then an empty 200: the third finishes);
- `cancelledNeverRetries`;
- `budgetExhaustedFinishes`;
- `exponentialWithSeededJitter` (2 s + j, 4 s + j);
- `retryInfoHonoredAndCapped` (`"30s"` gives 30 s, `"90s"` gives 60 s);
- `retryAfterHeaderHonored`;
- `civicFallbackOnlyOnce` (`civicFallbackUsed == true` → finish);
- `refusalNeverRetried` (a 200 whose body is `resp_image_safety.json`, `resp_prompt_refused.json` or `resp_refused_with_text.json` → `.finish`, with `autoRetriesUsed` 0 and with `civicWasSent` true: never `.retry` or `.rebuildWithoutCivicAndRetry`).

### M1 integration step (after tracks A–D merge)
One small branch, `m1-integration`, adds the tests that need two tracks together. No production code changes.
- `PipeParitySelectionTests`: for each of the eight cases in section 2.3, build the equivalent `SelectionInput` (ordinals assigned as D§4.3 says), run `InputSelector.select`, and assert that the reason and the selected image match the table. This is where p7 and p8 prove that rule 3's "highest ordinal" equals the pipe's `images[-1]`.
- `CoercedGoldenTests.proOverride1x8_512ProducesCoercedGolden`: resolve 3 Pro with an override of 1:8 / 512 through `GenerationSettingsResolver`, write the body with `RequestBodyWriter`, and compare it with `pro_16x9_1k.json`.

**M1 done when**
- [ ] `scripts/test.sh` passes, with these suites green: `SettingsResolverTests`, `InputSelectorTests`, `RequestBodyWriterTests`, `PipeParityTests`, `PipeParitySelectionTests`, `CoercedGoldenTests`, `EndpointTests`, `ResponseParserTests`, `RedactorTests` and `RetryPolicyTests`.
- [ ] `PipeParityTests` covers all 8 cases, and the only allowed difference is `generationConfig.imageConfig` plus the removed `?key=`.
- [ ] The golden file `flash_text_only_16x9_2k.json` contains `"aspectRatio":"16:9"` and `"imageSize":"2K"`.
- [ ] `scripts/lint.sh`, `scripts/lint.sh --self-test` and `scripts/check-warnings.sh` pass.
- [ ] The files in `Gemini/` and `Pipeline/` import no SwiftUI or SwiftData (enforced by lint for SwiftUI; check SwiftData by grep).

---

## M2: Persistence, files, Keychain and settings

**Goal.** A durable model of chats, messages, images and requests, with the file layout of D§4.4, the Keychain store, `AppSettings`, and the activity log core (D§4.13) that every later milestone logs through.

**Files and types**
- `Persistence/SchemaV1.swift`:
  - `enum SchemaV1: VersionedSchema` with `nonisolated @Model final class Conversation`, `Message`, `ImageAsset` and `GenerationRequest`, exactly as in D§4.3, including `#Unique` and `#Index`. That includes the `ImageAsset.prepared*` fields and `GenerationRequest.autoRetriesUsed`, `civicFallbackUsed`, `nextAttemptCreatedInBackground`, `noticesData` and `activityActionID`.
  - Relationships use `.cascade`.
  - `Message.images` is ordered by `ordinal`, because SwiftData relationships are unordered and every read sorts by ordinal.
  - `partsData`, `inputsData`, `safetyCategoriesData` and `noticesData` are JSON `Data`, wrapped by typed computed accessors (`parts: [MessagePart]`, `inputs: [RequestInput]`, `categories: [HarmCategory]`, `notices: [String]`). `MessagePart` and `RequestInput` come from M0's `SharedTypes.swift`.
- `Persistence/MigrationPlan.swift`: `enum ImageGenMigrationPlan: SchemaMigrationPlan` with `[SchemaV1.self]` and no stages yet.
- `Persistence/StoreFactory.swift`: `makeContainer(root: URL, inMemory: Bool) -> ModelContainer`. The store is at `root/default.store`.
- `Persistence/FileStore.swift`: a `Sendable` struct with `root: URL` and path helpers:
  - `imageURL(conv:image:ext:)`, `preparedURL(conv:image:edge:ext:)`, `requestDir(_:)`, `bodyURL`, `partURL(attempt:)`, `completeMarkerURL(attempt:)`, `stagingURL`;
  - `moveStaged(_:to:)`, `cloneItem` (`FileManager.copyItem`, which is an APFS clone), `removeConversationFiles`, `sizes()`.
  - Directories are created with `.completeUntilFirstUserAuthentication` protection.
- `Persistence/DataStore.swift`: a `@ModelActor actor DataStore`. All its API uses UUIDs and Sendable snapshots:
  - `createConversation() -> UUID`; `rename(_:to:)` (empty → automatic title); `deleteConversation(_:) -> [UUID] liveRequestIDs`; `setPin(_:imageID:)`; `setOverrides(_:ChatOverrides)`; `setDraft(_:text:)`; `deleteIfEmpty(_:)`.
  - `createSend(_ draft: SendRecordInput) -> SendRecord`: creates the user `Message` and its `ImageAsset`s (moving staged files; `ordinal` = the attachment's index in `draft.attachments`, which is tray order; the `prepared*` fields copied from `StagedAttachment.prepared`), the reply placeholder and the `GenerationRequest` (state `.preparing`, `autoRetriesUsed = 0`, `civicFallbackUsed = false`, with the resolved settings, inputs and reason), clears the pin if the selection says so, bumps `nextSequence` and `updatedAt`, sets the automatic title on the first send, and stores `draft.activityActionID` on the request. For a `.pinned` or `.latest` selection it records the reused image IDs; `RequestPreparer` (M4) fills in their final `RequestInput`s through `updateRequest`.
  - `setPreparedFile(imageID:_ prepared: RequestInput, longEdgeSetting:)`: updates an upload's `ImageAsset.prepared*` fields after `RequestPreparer` re-prepares it (D§4.3).
  - `createRegenerate(sourceRequestID:activityActionID:) -> SendRecord?`: copies the recorded settings and inputs verbatim, and stores the Regenerate action's ID. It returns nil if any input file is missing.
  - `requestSnapshot(_:) -> RequestSnapshot?` (with `inputAssets` filled from the `ImageAsset`s); `updateRequest(_:_ mutate: @Sendable (inout RequestPatch) -> Void)`; `nonTerminalRequests() -> [RequestSnapshot]`.
  - `completeReply(requestID:parts:images:notices:outcomeFields:)`: `images` are in the order of the image parts, and each new `ImageAsset` gets `ordinal` = its index among the image parts (D§4.3); `notices` go to `noticesData`.
  - `selectorHistory(conv:) -> [SelectorMessage]`; `pinState(conv:) -> (UUID?, exists: Bool)`; `deleteMessage(_:) -> liveRequestIDs`; `deleteAll()`.
- `Persistence/Janitor.swift`: implements D§4.4 for a `FileStore` and a `DataStore`, at utility priority. Its orphan scan covers only `Images/`, counts both `relativePath` and `preparedRelativePath` as references, and skips files modified in the last 10 minutes; it never touches the folder of a non-terminal request. Its caller (M4's `AppEnvironment`) runs it only after the Reconciler has finished. It logs one Janitor action (origin `system`), whose Begin states the thresholds (1 h, 10 min, 300 MB) and whose Result states the files removed per folder, the MB freed and the duration; it ends `failed`, with those counts and the first error, if any removal failed (D§4.13 Outcomes). It never touches `Logs/`.
- `ImageGenTests/Support/InMemoryStore.swift`: builds an in-memory `ModelContainer`, a `DataStore` and a `TestFileRoot`-backed `FileStore` for tests (used from M2 on).
- **Activity log** (D§4.13; types from M0's `Support/ActivityLogTypes.swift`):
  - `Support/ActivityLog.swift`: the facade, `final class ActivityLog: Sendable`, with its state in a `Mutex`. Its synchronous calls never await and hold the lock only briefly:
    ```swift
    struct ActivityMessage: Sendable, ExpressibleByStringInterpolation { /* segments; private ones via \(private:) */ }
    init(fileURL: URL, sanitize: @escaping @Sendable (String) -> String,
         mirror: @escaping @Sendable (ActivityEntry, _ publicText: String, _ privateText: String) -> Void = ActivityLog.osLogMirror,
         clock: @escaping @Sendable () -> Date = { Date() })
    @discardableResult func begin(_ name: String, origin: ActivityOrigin, _ m: ActivityMessage) -> ActionID  // top level
    @discardableResult func begin(_ name: String, parent: ActionID, _ m: ActivityMessage) -> ActionID        // sub-action
    func step(_ id: ActionID, _ m: ActivityMessage)
    func result(_ id: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage)
    func result(ofOpenChild name: String, of parent: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage)  // resolved by the store
    func beginLateCompletion(of original: ActionID, _ m: ActivityMessage) -> ActionID  // origin system, relatedID = original
    // Control messages: yielded into the same ordered stream as entries, answered by the store in order.
    func flush() async                                   // returns once every earlier call is written to the file
    func entries(tree id: ActionID) async -> [ActivityEntry]   // that action's tree and its Late completions
    func entries(after sequence: Int) async -> [(Int, ActivityEntry)]  // only newer entries; 0 = all
    func openActionsAtLaunch() async -> [ActivityEntry]  // begins open in the index when the file was loaded (Reconciler, M4)
    func clear() async                                   // keeps open actions' begins; writes the Log cleared action
    func changes() -> AsyncStream<ActivityLogStatus>     // coalesced, one value after each write
    ```
    - `init` makes one synchronous, bounded pass over the file's tail: if the last line has no trailing newline it truncates the file back to the last newline, and it finds the newest begin entry and inverts its ID (× the inverse of the odd constant mod 2^16) to seed the in-memory counter; with no file the counter starts at 0. Nothing is kept in `UserDefaults`.
    - Every call first runs `sanitize` and renders its message (the file text, and the mirror's public and private parts) **before** taking the lock. Under the lock it only takes the next ID (for a begin), stamps `clock()` and yields into one unbounded `AsyncStream`. No `mirror` call, file I/O or defaults access happens under the lock.
    - A sub-action's begin carries no origin, and entries for an adopted ID carry no name; the store fills both in.
  - `Support/ActivityLogStore.swift`: the `actor` that is the stream's only consumer and the file's only writer.
    - It loads the file before consuming the stream and builds the **action index**: per action, name, origin, parent, open or closed, outcome, `relatedID`, and its first entry's sequence number and byte offset, plus a sparse sequence → offset table every 256 entries. It keeps the index, not the entries.
    - For each entry it fills in a missing `name` and origin from the index, appends one line with a single `write`, updates the index, calls `mirror` (so the OSLog mirror sees exactly the written entries, including those the store writes itself), and publishes a coalesced `ActivityLogStatus` (newest sequence; `ActivityLogQuery.lastAction` and `lastError` over the index).
    - It drops a second result (reporting it under OSLog `store`, unmirrored) and, before a parent's result, writes `interrupted · parent finished first` results for its open sub-actions.
    - Control messages are answered in stream order: `flush` resumes once everything before it is written; `entries(tree:)` reads from the action's first-entry offset to the end and keeps its tree and Late completions; `entries(after:)` reads from the nearest offset at or before that sequence.
    - It rotates past 4 MB to the newest whole entries within 2 MB plus the begin entries of every open action (in file order ahead of the window), through a temporary file and an atomic swap.
    - `clear` writes a new file holding the begins of open actions (oldest first) and then the Log cleared action (Begin: the size and entry count removed and the open actions kept; Result: success). The index keeps those actions open.
    - The folder `FileStore.root/Logs/` is created with `.completeUntilFirstUserAuthentication` and `isExcludedFromBackup`; the file and every temporary file are created with that protection passed explicitly (`FileManager.createFile(atPath:contents:attributes: [.protectionKey: …])`), and `isExcludedFromBackup` is set on `activity.jsonl` again after every create, rotation swap and clear.
  - `Support/ActivityLogQuery.swift` (pure): `lastAction(_ actions: [ActionRecord]) -> ActionID?` and `lastError(_:) -> ActionID?` over the index's records, exactly as D§3.10 defines them (Last Error judges an interrupted action by its newest Late completion); `tree(_ id: ActionID, in: [ActivityEntry])` and `all(_:)`, each returning an `ActivityView { entries; isInProgress; hasRotatedOutStart }`.
  - `Support/ActivityLogFormatter.swift` (pure): `lines(_ view: ActivityView, timeZone:) -> [String]` in the D§3.10 format (`HH:mm:ss.SSS [Name id] Begin|Step|Result: …`, two spaces per sub-action level after the timestamp, date lines between days, the rotated-out note, a Late completion after "(completed later)" one level in), plus `text(_:) -> String` for Copy and Share.
  - `Security/SecretRegistry.swift`: `final class SecretRegistry: Sendable` with a `Mutex<Set<String>>`, `register(_:)` and `all`. `KeychainStore` and `InMemoryKeyStore` take it and register the key on every `read()` that returns one and on `save(_:)`; nothing unregisters, so a removed key is still scrubbed for the life of the process (D§4.13).
  - `ImageGenTests/Support/ActivityLogProbe.swift`: makes an `ActivityLog` on a `TestFileRoot` file with a recording OSLog sink and an injectable `sanitize:` (default identity; section 2.2), and offers `action(named:)`, `lines()`, `osLogStrings` and `assertPaired()`, each awaiting `flush()` first.
- `Security/KeychainStore.swift`: as D§4.10, with an injectable service name. It also defines `protocol APIKeyStore: Sendable { func read() throws -> String?; func save(_ key: String) throws; func delete() throws }`, which `KeychainStore` conforms to, and `final class InMemoryKeyStore: APIKeyStore` (its state behind a `Mutex`), used by tests and DEBUG mock mode. Onboarding, Settings and `GenerationService` depend only on `APIKeyStore`.
- `Settings/AppSettings.swift`: `@Observable @MainActor final class AppSettings`, backed by an injectable `UserDefaults`:
  - `defaultAspectRatio` (default `.r16x9`), `defaultImageSize` (`.s2K`), `safetyThreshold` (`.blockNone`), `maxUploadLongEdge` (2048; allowed 1536/2048/3072/4096), `includeTextModality` (true until M9 task 8 settles R3; false if the 1K cap is confirmed), `omitCivicIntegrity` (false), `enabledModelIDs` (every catalog ID, `ModelCatalog.builtInIDs`; toggles can remove any but Flash), `customModelIDs` ([]), `notifyOnBackgroundCompletion` (true), `modelAvailabilityCache` (Codable blob plus a timestamp);
  - `func generationDefaults() -> GenerationDefaults`, a Sendable snapshot (`GenerationDefaults` is in M0's shared types). Its `enabledModelIDs` is the enabled catalog IDs plus `customModelIDs`, always including Flash.
  - It also provides a `nonisolated static func readDefaults(_ ud: UserDefaults) -> GenerationDefaults`, so actors can read the defaults in the background without the main actor (needed for background retries). Actors never **write** `UserDefaults` directly; the CIVIC flag is set through `AppSettings` on the main actor (M4, D§5). The activity log doesn't conflict with this rule: it keeps nothing in `UserDefaults` (its ID counter is seeded from the log file).

**Notes.** D§4.3, D§4.4, D§4.10 and D§5. Keep everything under `root`, which can be injected, so tests use `TestFileRoot`. The automatic title is the first 48 characters, cut at a word boundary (D§3.3).

**Tests**
- `DataStoreTests`, using an in-memory container and a temporary root:
  - `createSendMovesStagedFiles`;
  - `createSendRecordsSettingsAndReason` (and the activity action ID);
  - `createSendOrdinalsFollowTrayOrder` (including after a reorder) and `createSendCopiesPreparedFields`;
  - `completeReplyOrdinalsFollowImagePartOrder` (parts text, image, text, image → ordinals 0, 1) and `completeReplyStoresNotices`;
  - `setPreparedFileUpdatesAsset`;
  - `retryCountersPersisted` (`autoRetriesUsed` and `civicFallbackUsed` survive a new `DataStore` on the same container);
  - `firstSendSetsAutoTitle`;
  - `renameEmptyRevertsToAutoTitle`;
  - `pinClearedWhenSelectionSaysSo`;
  - `regenerateCopiesRecordedValuesAndAppendsReply`;
  - `regenerateNilWhenInputMissing`;
  - `deleteConversationRemovesFilesAndReturnsLiveRequests`;
  - `deleteUserMessageKeepsReplies`;
  - `deleteIfEmpty`;
  - `selectorHistoryOrderAndStates`;
  - `editAndResendClonesAssets` (the clone helper is in `FileStore`; the UI wiring comes in M6).
- `ActivityLogTests` (through `ActivityLogProbe`; an injected clock where times matter):
  - `orderPreservedUnderConcurrency` (8 tasks log 250 entries each, from different isolations, with a per-task sequence number: the file order equals the order the facade took its lock, each task's entries are in sequence, and timestamps never go backwards);
  - `controlMessagesOrderedAfterEarlierEntries` (log 1,000 entries without awaiting, then `entries(after: 0)`: all 1,000 are there; log 100 more, then `clear()` with no await between: none of the 100 appears after the Log cleared action; `flush()` returns only after a slowed-down store has written everything before it);
  - `exactlyOneBeginAndResult` (a second `result` for the same ID is dropped and not mirrored); `parentResultClosesOpenChildrenAsInterrupted` (the store-written result is mirrored);
  - `lastActionIsNewestUserTopLevelWithSubActions`; `lastActionInProgressMarked`; `lastActionSkipsNewerSystemActions`; `lastActionFallsBackToSystemWhenNoUserAction`; `lastActionShowsItsLateCompletion`;
  - `lastErrorIncludesRefused`; `lastErrorIncludesFailedAndInterrupted`; `lastErrorIncludesEmptyReplyAsFailed`; `lastErrorIgnoresCancelled`; `lastErrorIncludesSubActions`; `lastErrorSkipsInterruptedResolvedBySuccessfulLateCompletion`; `lastErrorNilWhenNone`;
  - `partialFailureEndsFailed` (scripted Attach with 3 children, one `failed`: `lastError` returns the Attach);
  - `rotationKeepsWholeEntries` (write past 4 MB: the file is at most 2 MB plus open begins, every line decodes, the newest entry is kept and the oldest are gone; a closed action whose begin was rotated out is flagged `hasRotatedOutStart`);
  - `rotationKeepsOpenActionBegins` (a Send begun first and still open when the file rotates: its begin survives, its later Result is named `Send` with origin `user`, and after a reload `openActionsAtLaunch()` still reports it);
  - `clearDeletesFileAndStartsWithLogCleared` (nothing open: afterwards `all` holds exactly one Log cleared Begin, whose message states the size and count removed, and its Result);
  - `clearKeepsOpenActionBegins` (a Send and its Attempt open during the clear: the new file holds their begins, then Log cleared; the Send's later step and Result are named and paired, and a reload still reports them open until then);
  - `persistsAcrossInstances` (a new `ActivityLog` on the same file reads every entry, and its next ID isn't one already in the file);
  - `idSeededFromFileNotDefaults` (instance 1 begins 50 actions and is dropped without any other state surviving; instance 2 on the same file hands out an ID equal to none of the 50, and one past the newest begin's counter; with no file it starts at the counter's first value);
  - `openActionsFromEarlierInstanceReportedAndClosable` (instance 1 begins A, and B with child B1, and stops; instance 2 reports A, B and B1 from `openActionsAtLaunch()`, and its own new actions aren't in that set; `result(A, .interrupted, …)` closes A; `result(ofOpenChild: "B1", of: B, …)` closes B1);
  - `adoptedEntriesGetNameAndOrigin` (instance 2 logs a step and a sub-action begin under B's ID: in the file and in the recorded mirror both carry `[B …]`'s name, the mirror category picked from it, and the sub-action has B's origin);
  - `truncatedLastLineRecovered` (a file ending in half a JSON line: instance 2 truncates it, its first entry is on its own line, and a third instance reads that entry back);
  - `fileProtectionAndBackupExclusion` (the protection class and `isExcludedFromBackup` read back on the file and on `Logs/`, after the first create, after a rotation and after a clear);
  - `osLogMirrorKeepsPrivateSegmentsPrivate` (the recorded public text has `<private>` where the prompt and a chat title were; the private text holds them; the file holds the full text);
  - `formatterLineFormat` (exact strings for a Begin, a Step and a Result, a sub-action indented two spaces after the timestamp, a date line between days, the rotated-out note).
- `JanitorTests`:
  - `emptiesStaging`;
  - `removesTerminalRequestDirsOlderThan1h`;
  - `keepsLiveRequestDirs` (including `out-<attempt>/` of a non-terminal request);
  - `removesOrphanImages`;
  - `keepsPreparedFilesReferencedByAssets`;
  - `skipsFreshUnreferencedImages` (modified under 10 minutes ago);
  - `scansOnlyImagesFolder`;
  - `trimsThumbnailCacheLRU`;
  - `neverTouchesLogs`;
  - `runLogged` (one Janitor action, origin `system`, whose Result has the per-folder counts and MB freed; paired).
- `KeychainStoreTests`: save/read/update/delete round trip; `accessibilityIsAfterFirstUnlockThisDeviceOnly` (read back through `kSecReturnAttributes`).
- `InMemoryKeyStoreTests`: save/read/delete round trip through `APIKeyStore`; `readAndSaveRegisterSecret` (after `save` and after `read`, `SecretRegistry.all` holds the key, and it stays after `delete`). `KeychainStoreTests` repeat the registration check.
- `AppSettingsTests`:
  - `defaultsAre16x9And2K`;
  - `defaultsBlockNoneAnd2048AndTextOn`;
  - `persistsAcrossInstances`;
  - `flashCannotBeDisabled`;
  - `allCatalogModelsEnabledByDefault` (a fresh `UserDefaults` gives `enabledModelIDs == ModelCatalog.builtInIDs`);
  - `enabledModelIDsIncludeCustomIDsAndFlash`;
  - `nonisolatedReadMatches`.

**Done when**
- [ ] All the suites above pass under `scripts/test.sh`, including `ActivityLogTests`.
- [ ] The `@ModelActor` `DataStore` and the `ActivityLog` facade and store compile with no concurrency warnings (`scripts/check-warnings.sh`).
- [ ] `grep -rn "nonisolated @Model\|@Model" ImageGen/Persistence` shows every model class marked `nonisolated`.
- [ ] No test writes outside its temporary root; for example, Application Support for the test host contains no `ImageGen/` folder after the run (`xcrun simctl get_app_container $UDID $BUNDLE_ID data`, then check).

---

## M3: Imaging and Markdown

**Goal.** Fast, memory-safe image inspection, preparation and thumbnails, plus the Markdown block renderer model.

**Files and types**
- `Imaging/ImageInspector.swift`:
  - `struct ImageInfo: Sendable { utType, mimeType, pixelWidth, pixelHeight, orientation, hasAlpha, frameCount }`;
  - `static func inspect(url:) throws -> ImageInfo` and `inspect(data:)`. These read properties only; they don't decode.
  - The error is "Unsupported or damaged image".
- `Imaging/ImagePreprocessor.swift`:
  - `@concurrent static func prepare(source: URL, maxLongEdge: Int, destinationDir: URL, id: UUID) async throws -> PreparedImage` (`PreparedImage` is in M0's shared types; `longEdgeSetting` records `maxLongEdge`);
  - `@concurrent static func shrink(_: PreparedImage, factor: 0.75, quality: 0.85, flattenAlpha: true) async throws -> PreparedImage`.
  - It uses `CGImageSourceCreateThumbnailAtIndex` with `FromImageAlways`, `WithTransform`, `MaxPixelSize: min(edge, longEdge)` and `ShouldCacheImmediately`, then a `CGImageDestination` with no metadata dictionary, so EXIF and GPS are stripped.
  - Output type (D§4.8 step 3): HEIC/HEIF always gives JPEG at 0.9, with any alpha flattened onto white; a PNG or WebP source with alpha gives PNG; everything else gives JPEG at 0.9.
  - In DEBUG it logs, under `imaging`, peak `phys_footprint` (through `task_info`) before and after each prepare (used by M9).
- `Imaging/DecodeTimer.swift`: a small helper that times an image decode and, in DEBUG, logs under `imaging` any decode that ran on the main thread and took more than 16 ms (D§8). `ThumbnailService` uses it here; M5's `ImageThumbnailView` and M7's viewer use it too.
- `Imaging/BudgetPlanner.swift`: pure `plan(inputs: [PreparedSize], envelopeBytes: Int, budget: 19_000_000, minLongEdge: 1024) -> BudgetPlan` (which inputs to shrink, or "can't fit"), plus an async driver that calls `shrink` until the body fits. Cancellation is checked between iterations (D§4.8 step 5, D§5).
- `Imaging/ThumbnailService.swift`: an `actor`, with 240 px and 1200 px JPEG thumbnails in `Caches/Thumbnails/<id>-<px>.jpg` and an `NSCache` (`totalCostLimit` 120 MB). `func thumbnail(for imageURL: URL, id: UUID, px: Int) async -> CGImage?` (the UI wraps it in `UIImage`, which is allowed from a `CGImage`).
- `Imaging/SizeClass.swift`: pure.
  - `classify(width:height:) -> ImageSize` by nearest nominal megapixels;
  - `isSizeHonored(requested:width:height:)`: within a factor of 1.5 of the nominal megapixels;
  - `isAspectHonored(requested:width:height:)`: within 3% (D§3.4, as updated).
- `Support/MarkdownBlocks.swift`: a pure parser, `parse(_ text: String) -> [MarkdownBlock]` (heading(level, inline), paragraph, bullet/numbered list items with nesting depth, code(lang, text), quote). `Support/MarkdownView.swift` is a SwiftUI view that renders blocks with `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)`. The view lives in `Support/`, which may import SwiftUI.

**Notes.** D§4.8, D§8 and D§4.12. Never use `UIImage(data:)` (lint).

**Tests**
- `ImagePreprocessorTests`:
  - `heicBecomesJpeg`;
  - `heicWithAlphaBecomesJpeg` (alpha flattened onto white; the output MIME type is `image/jpeg`);
  - `longEdgeCapped` (parameterized over 1536, 2048, 3072 and 4096, with an 8064×6048 source generated in the test); each case measures itself with `ContinuousClock` and asserts `#expect(duration < .seconds(3))`;
  - `neverUpscales`;
  - `orientationApplied` (using `rotated_exif6.jpg`; the output width and height are swapped and the orientation is 1);
  - `gpsAndExifStripped`;
  - `pngWithAlphaKeepsPNG`;
  - `gifToJpeg` (ImageIO can encode GIF, so the source is made in the test);
  - `webpToJpeg`, gated with `.enabled(if: (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.webP.identifier))`. iOS can't encode WebP, so in practice it doesn't run, and no WebP fixture is checked in. (Don't use `withKnownIssue` for this: it expects a failure rather than skipping.)
- `BudgetPlannerTests`:
  - `fitsWithoutShrink`;
  - `shrinksLargestFirst`;
  - `repeatsUntilFits`;
  - `failsBelow1024`;
  - `alphaFlattenedOnShrink`.
- `SizeClassTests`:
  - `flash16x9_2K_2752x1536_honored`;
  - `oneK1x8_384x3072_honored` (shows why megapixels are used rather than the long edge);
  - `returned1KFor2KFlagged`;
  - `aspect1x1For16x9Flagged`.
- `ThumbnailServiceTests`: makes 240 and 1200 px thumbnails; a cache hit makes no second file write; the thumbnail keeps the aspect ratio.
- `DecodeTimerTests`: a decode on the main thread over 16 ms is reported (with an injected clock); one off the main thread isn't.
- `MarkdownBlocksTests`: headings, nested lists, fenced code with a language, a quote, mixed paragraphs, a stray `#` without a space treated as a paragraph, and Markdown images ignored.

**Done when**
- [ ] All the suites above pass.
- [ ] `ImagePreprocessorTests.longEdgeCapped` on the 48 MP source passes its own `duration < 3 s` expectation for every case on the simulator.
- [ ] Lint passes (no `UIImage(data:)`).

---

## M4: Transport and generation pipeline (background)

**Goal.** End to end without UI: a `SendDraft` goes in, and the pipeline produces a persisted reply with byte-identical images. It works on the background session in production and on ephemeral plus `MockURLProtocol` in tests. Reconciliation, retries, cancellation and notifications all work, and every step is in the activity log (section 2.8, D§4.13).

**Files and types**
- `Networking/GenerationTransport.swift`:
  ```swift
  struct TransportJob: Sendable { let requestID: UUID; let attempt: Int; let modelID: String; let bodyURL: URL; let bodySize: Int
                                  let expectedReceiveBytes: Int; let earliestBegin: Date? }
  struct TransportCompletion: Sendable { let requestID: UUID; let attempt: Int; let taskIdentifier: Int
                                         let httpStatus: Int?; let headers: [String: String]
                                         let partURL: URL; let bytesReceived: Int; let error: URLError.Code?
                                         let cancelReason: Int?     // NSURLErrorBackgroundTaskCancelledReasonKey, if present
                                         let elapsed: Duration }    // since the task began (for RetryPolicy)
  enum TransportEvent: Sendable { case began(requestID: UUID, attempt: Int, taskIdentifier: Int)
                                  case completed(TransportCompletion)
                                  case finishedEvents(sessionIdentifier: String) }
  struct LiveTask: Sendable { let requestID: UUID; let attempt: Int; let taskIdentifier: Int; let countOfBytesSent: Int64 }
  protocol GenerationTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }                       // one consumer: GenerationService
    func start(_ job: TransportJob, apiKey: String) throws -> Int          // taskIdentifier
    func cancel(requestID: UUID) async
    func cancel(taskIdentifier: Int) async                                 // replacing a background-created retry
    func liveTasks() async -> [LiveTask]
  }
  ```
  There are no handler setters: the stream exists from `init`, so nothing can be delivered before it's wired (D§4.6, "The event stream").
- `Networking/URLSessionTransport.swift`:
  - `final class URLSessionTransport: NSObject, GenerationTransport, URLSessionDataDelegate, @unchecked Sendable` → **prefer** `Sendable` with all state in `Mutex`. If the `NSObject` subclass blocks `Sendable` checking, use `@unchecked Sendable`, with a comment explaining that all mutable state is behind `Mutex`.
  - `init(configuration: URLSessionConfiguration, fileStore: FileStore, sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }, requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil)`. In this order: make the stream with `AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)`, keep its continuation, **then** create the `URLSession` with `self` as delegate.
  - Every delegate callback that produces an event calls `continuation.yield(...)` synchronously on the delegate queue. There is no `Task { … }` per callback, so event order is delegate order.
  - The background configuration follows D§4.6 exactly (with `waitsForConnectivity` left unset). `taskDescription = "gen:<uuid>:<attempt>"`.
  - `uploadTask(with:fromFile:)`; `countOfBytesClientExpectsToSend` and `countOfBytesClientExpectsToReceive` are set.
  - **Delayed starts** (D§4.6, Retries): on a background configuration (`configuration.identifier != nil`) it sets `task.earliestBeginDate` and resumes at once, and `urlSession(_:task:willBeginDelayedRequest:completionHandler:)` answers `.continueLoading` and yields `.began`. On any other configuration it holds the task un-resumed, awaits `sleeper(earliestBegin − now)`, resumes, and yields `.began`.
  - `cancelReason` is read from `(error as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey]`.
  - `static func backgroundConfiguration(bundleID:) -> URLSessionConfiguration` builds the D§4.6 table.
- `Networking/ResponseAccumulator.swift`: a `Mutex<[Int: FileHandle]>` keyed by task identifier, with synchronous `write`. A lazy open (on the first chunk in this process, or on completion if no chunk arrived) **creates the file if it's missing, then `seekToEnd()`; it never truncates**, because part of the body may have been written by a previous process (D§4.6). `prepareNewAttempt(requestID:attempt:)`, called by `start`, is the only place that creates an empty `.part` file. On completion it closes the handle and writes `response-<attempt>.complete` (empty file) before the `.completed` event is yielded.
- `Networking/BackgroundEventsRelay.swift`: `@MainActor final class` that stores the system completion handler per session identifier, with the ID of the Background events action begun when it was stored, and has `func callAndClear(identifier:completionsHandled:) async`, which ends that action, awaits `log.flush()` (capped at 1 s), and only then calls the handler (section 2.8 rule 9), because the OS may suspend the app as soon as the handler runs.
- `Networking/ConnectivityMonitor.swift`: `protocol ConnectivityMonitoring: Sendable { var isSatisfied: AsyncStream<Bool> { get } }`; `NWPathConnectivityMonitor` wraps `NWPathMonitor` on a private queue. M5 publishes its value to `ChatScreenModel` (D§3.4 "Waiting for network"); it never affects tasks.
- `App/BackgroundTaskProvider.swift`: `protocol BackgroundTaskProviding: Sendable { func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken; func end(_ t: BackgroundTaskToken) async }`; `UIApplicationBackgroundTaskProvider` takes the `ActivityLog` and calls `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` / `endBackgroundTask` on the main actor. `end` awaits `log.flush()` (capped at 1 s) before `endBackgroundTask`. The expiry handler runs `onExpire` (which logs the result), then awaits the flush capped at 0.5 s, then ends the task. `AppEnvironment` also uses it to wrap a flush when the scene moves to the background (`scenePhase == .background`). Tests use `RecordingBackgroundTaskProvider`, which records begin/end (and whether a flush preceded each end) and can fire expiry.
- `Pipeline/RequestPreparer.swift`: given a `RequestSnapshot`, it resolves inputs to `BodyImage`s, runs the budget driver, writes `body.json`, and returns `(bodyURL, bodySize)`.
  - Uploads in the attachments use their recorded prepared file.
  - A **reused upload** (`.pinned`/`.latest`, `InputSnapshot.origin != .model`) uses its `ImageAsset.prepared*` file if that file exists and `preparedLongEdgeSetting` equals the current `maxUploadLongEdge` (from `AppSettings.readDefaults`); otherwise it calls `ImagePreprocessor.prepare` on the original at the current setting and stores the result with `DataStore.setPreparedFile` (D§4.3). The final `RequestInput`s are written back with `updateRequest`.
  - A reused model output uses its original bytes.
  - Its errors are typed: `tooLarge(mb)`, `inputMissing` (only when an **original** is gone), `diskFull`, `noAPIKey`, `emptyParts`.
- `Pipeline/GenerationService.swift`: `protocol GenerationServicing: Sendable { func send(_ d: SendDraft) async throws -> UUID; func regenerate(sourceRequestID: UUID) async throws -> UUID; func retry(requestID: UUID) async throws; func cancel(requestID: UUID) async }`, and `actor GenerationService: GenerationServicing`, implementing D§4.6 and D§6. M5's `ChatScreenModel` depends only on the protocol.
  - `init(…, transport:, store:, keyStore: any APIKeyStore, backgroundTasks: any BackgroundTaskProviding, setOmitCivicOnMain: @escaping @Sendable () async -> Void, onBackgroundEventsFinished: @escaping @Sendable (_ sessionID: String, _ completionsHandled: Int) async -> Void, …)`. The init starts the single consumer task over `transport.events`, which handles each event to the end before taking the next.
  - Also `appBecameActive() async` (re-creates retries made in the background, below).
  - **Background-task assertion** (D§4.6): `send`, `regenerate` and `retry` call `backgroundTasks.begin(name: "gen-prepare", onExpire:)` before `createSend` (or before rebuilding the body) and `end` right after `transport.start` returns or preparation fails. On expiry: cancel the preparation task, delete a partial `body.json`, mark the request `interrupted`.
  - The live-request set per conversation enforces one request in flight per chat.
  - It reads the API key through `APIKeyStore` each time it starts a task.
  - **Retries**: it calls `RetryPolicy.decide` with the persisted `autoRetriesUsed` and `civicFallbackUsed`, then increments `attempt` and `autoRetriesUsed`, records `nextAttemptAt`, sets `nextAttemptCreatedInBackground` from `AppActivity.isActive`, and starts a task with `earliestBegin`. `.began` moves `retryScheduled` → `inFlight`. `appBecameActive()` cancels (by `taskIdentifier`) every `retryScheduled` task with `nextAttemptCreatedInBackground` that hasn't begun, and starts a replacement for the same attempt with `earliestBegin = max(now, nextAttemptAt)` and the flag cleared; the replaced task's cancellation completion is recognized by its `taskIdentifier` and ignored. Manual `retry` sets `attempt += 1` and `autoRetriesUsed = 0`.
  - **CIVIC fallback**: rebuild the body with 4 categories, set `civicFallbackUsed`, call `setOmitCivicOnMain()` (which sets `AppSettings.omitCivicIntegrity = true` on the main actor; the actor never writes `UserDefaults` itself), record the categories sent, and start the next attempt.
  - **Cancels**: `cancel(requestID:)` inserts the ID into `userCancelledRequestIDs` before cancelling. A `NSURLErrorCancelled` completion becomes `cancelled` only for an ID in that set; any other cancel (force-quit, background updates disabled, low resources; `cancelReason` logged) becomes `interrupted`.
  - **Late completion wins**: a completion for an `interrupted` request is still parsed and applied.
  - It discards completions whose request record no longer exists, and deletes their files.
  - Parsing writes into `Requests/<id>/out-<attempt>/` (D§4.4). On success it moves the parsed images into `Images/<conv>/`, creates `ImageAsset`s (`origin: model`, `ordinal` = index among the image parts) and stores the notices through `completeReply`, sets `outputWidth` and `outputHeight` from the first image, warms the thumbnails, and saves.
  - On `.finishedEvents(id)` it calls `onBackgroundEventsFinished(id, n)`, where `n` is the number of completions handled while the app was not active since the previous `.finishedEvents` (reset when the app becomes active), which calls `BackgroundEventsRelay.callAndClear` on the main actor. Because events are handled in order, every earlier completion has been parsed and saved by then.
  - **Logging** (D§4.13, section 2.8). It takes an `ActivityLog` in `init`.
    - `send`, `regenerate` and `retry` each begin their top-level action (origin `user`) before the background-task assertion, with every operative parameter: the resolved settings and coercions, the selection and why, the inputs (each described by origin, D§4.13 Messages: an upload as `upload img …, <original> → sent <prepared>` or `→ prepare at <edge>`; a model output as `model output img …, <W×H MIME MB>, sent as original`), and the full prompt. It awaits `log.flush()` before the ID goes into `SendRecordInput.activityActionID`, `createRegenerate(…activityActionID:)` or, for a Retry, `RequestPatch.activityActionID` (section 2.8 rule 9).
    - Sub-actions: Prepare request (logged by `RequestPreparer`, which takes the parent ID), one Attempt *n* per task (begun at `transport.start`, with a step on the Attempt giving the task identifier; closed from the `.completed` event), and Parse (ending `success`, `refused`, or `failed` for the empty, API error and malformed classes).
    - Steps: each `RetryPolicy` decision with its reason and delay (a RetryInfo delay as given, `in 2.0 s … (RetryInfo 2s)`; jitter only on the exponential fallback, D§6); the CIVIC rebuild; a background-created retry re-created in `appBecameActive()`; "delivered while the app was in the background" (from `AppActivity`); the reply saved; the notification posted or not and why (from `NotificationPoster`'s return value). The first-send notification permission request is not a Send step: M5's `ChatScreenModel` asks for it and logs it as its own Notification permission action.
    - The action's result is written exactly once, when the request reaches a terminal state, mapped as D§4.13 Outcomes says: `succeeded` → success; `refused` → refused (with the reason); `failed` → failed (with the error status and message through `Redactor.errorBodyForLog`); `empty` → **failed** (`empty reply · finish <reason>`); `cancelled` → cancelled; `interrupted` → interrupted (including the assertion expiry).
    - It keeps the attempt sub-action IDs in memory. After a relaunch it adopts the request's `activityActionID` and closes the earlier process's attempt with `result(ofOpenChild: "Attempt <n>", of:, …)`; the store supplies the names and origins of adopted entries.
    - A completion for a request already `interrupted` is logged as a new Late completion action through `beginLateCompletion(of: <request's activityActionID>, …)`, ending with the request's real outcome.
    - `cancel(requestID:)` logs a Cancel action.
- `Pipeline/Reconciler.swift`: implements D§4.7, including the 5 s grace timer (with an injectable clock), the `.complete` marker re-parse, and `retryScheduled` → `inFlight` for live tasks with `countOfBytesSent > 0`. It logs a Reconcile action (origin `system`) with one step per request decision. Then, as D§4.7 step 5 says, it closes every action from `ActivityLog.openActionsAtLaunch()` as `interrupted`, except an action (or a sub-action of one) that is the `activityActionID` of a request still non-terminal; that action gets a step saying which request it follows. When the grace timer marks a request `interrupted`, the Reconciler closes that request's action with `interrupted` and the reason.
- (`SendDraft`, `StagedAttachment`, `RequestSnapshot`, `InputSnapshot`, `RequestInput` and `MessagePart` already exist in M0's `SharedTypes.swift`.)
- `App/AppActivity.swift`, `App/NotificationPoster.swift` (protocol plus the `UNUserNotificationCenter` implementation; tests use a recording fake; `post` returns what it did, posted with the body or suppressed with the reason, so `GenerationService` can log the step) and `App/NotificationRouter.swift`.
- `App/AppEnvironment.swift`:
  - `static let shared` is lazily created on first access, from `ImageGenApp.init` or `AppDelegate.didFinishLaunching`, whichever runs first.
  - First, `DebugHooks.resetBeforeLaunchIfRequested(root:)`: under `-ResetStore 1` (DEBUG) it deletes the store and every file under `Application Support/ImageGen/`, `Logs/` included (section 2.6); the Release stub does nothing. Then it builds, in this order: the `SecretRegistry`; the `ActivityLog` (on `Application Support/ImageGen/Logs/activity.jsonl`, with `sanitize: Redactor.forLog(secrets: { registry.all })`), after which it begins the Launch action (origin `system`; only what's known now: version and build, iOS version, mock mode); then `FileStore`, `ModelContainer`, `DataStore`, the `APIKeyStore` (`KeychainStore`), `AppSettings`, `ThumbnailService`, the transport (whose `init` creates the event stream and then the session), `GenerationService` (which starts consuming the stream), then `Reconciler`, `ModelsClient`, `ModelAvailabilityService` and the `ConnectivityMonitor`.
  - It passes the `ActivityLog` to every component that logs. In `didFinishLaunching` it logs a Launch step with `UIApplication.shared.applicationState` (`background` for a background relaunch, otherwise foreground), and at the end of `didFinishLaunching`, after the Reconciler has started, it ends the Launch action (duration; store opened; background session recreated; Reconciler started). Why a background relaunch happened is logged by the Background events action that follows, not by Launch.
  - It starts the **Reconciler immediately** after construction, in the same `didFinishLaunching` pass, on every launch including background relaunches. It starts the **Janitor** only after the first frame **and** after the Reconciler has finished (D§4.4, D§8).
  - It calls `generationService.appBecameActive()` on every `scenePhase == .active`.
  - It switches to mock mode under `-UITestMockGemini` (DEBUG) through `DebugHooks.mockEnvironment()` (which returns the ephemeral configuration and an `InMemoryKeyStore`, or nil; the Release stub always returns nil), and to inert mode under the unit-test host (section 2.2).
- `App/AppDelegate.swift`:
  - `handleEventsForBackgroundURLSession` stores the handler in `BackgroundEventsRelay` and begins a Background events action (origin `system`, the session identifier). `BackgroundEventsRelay.callAndClear` ends it with the number of completions handled and the time to the handler, flushes the log, then calls the handler.
  - It sets the `UNUserNotificationCenter` delegate (`willPresent`, `didReceive` → `NotificationRouter`).
- `Gemini/ModelsClient.swift` (async/await on an ephemeral session with a 20 s timeout; paging) and `Pipeline/ModelAvailabilityService.swift` (caches results in `AppSettings`; runs on key save, on foreground at most every 24 h, and on manual refresh). The service logs each run as a Models refresh action (origin `system` for the foreground check, `user` for a manual refresh, a sub-action of Save API key on key save) with the reason, path and page size, then pages, model count and per-model availability changes. Its `validateKey` logs a Validate key action the same way, for M5's onboarding and M8's Validate Now.
- `DebugSupport/MockGeminiURLProtocol.swift`, `DebugSupport/MockImageSizes.swift`, `DebugSupport/MockImageRenderer.swift` and `DebugSupport/LaunchOptions.swift` (the parser only; scenes are wired in M5).
- `scripts/live-smoke.sh` and `ImageGenTests/LiveSmokeTests.swift`.

**Notes**
- D§4.6, D§4.7, D§6, D§5 and D§9 (networking in tests).
- Events go from the delegate queue to the actor only through the ordered `AsyncStream`; don't hand completions over with per-callback `Task { … }`, because two such tasks have no guaranteed order of reaching the actor. With the stream, a `.finishedEvents` that follows a `.completed` back to back is always handled second.
- Compute the expected receive bytes as D§4.6 says.
- `countOfBytesClientExpectsToReceive` × the number of images is just an estimate.

**Tests**
- `TransportTests` (ephemeral + `MockURLProtocol`):
  - `chunkedBodyAccumulatesInOrder` (5 chunks);
  - `bodySplitAcrossRecreatedAccumulatorAppends` (deliver 2 chunks, make a new `ResponseAccumulator`, deliver 3 more: the file holds all 5 in order);
  - `newAttemptStartsEmptyPartFile`;
  - `statusAndHeadersCaptured`;
  - `completeMarkerWrittenBeforeCompletedEvent`;
  - `cancelReasonCarried` (a completion whose error has `NSURLErrorBackgroundTaskCancelledReasonKey` reports it);
  - `eventsBufferedBeforeConsumerStarts` (a completion delivered before anything iterates `events` is still received);
  - `finishedEventsAfterBackToBackCompletion` (yield `.completed` and `.finishedEvents` with no delay: they arrive in that order);
  - `deferredResumeHonorsEarliestBegin` (non-background config: the task isn't resumed until the injected sleeper returns; `.began` follows);
  - `emptyBody200Reported`;
  - `uploadBodyBytesEqualBodyFile` (the mock reads `httpBodyStream`);
  - `headerKeyPresentAndNoKeyInURL`.
- `BackgroundConfigTests`: every value in the D§4.6 table, plus `waitsForConnectivityNotSet`, without creating a session.
- `GenerationServiceTests` (in-memory store, temporary root, `MockURLProtocol`, `InMemoryKeyStore`, recording `NotificationPoster`):
  - `endToEndTextToImage` (reply parts, image bytes identical to the fixture, state `succeeded`, `outputWidth/Height`);
  - `recordsSentValues` (16:9/2K by default; overrides recorded);
  - `editLatestSendsOriginalBytes`;
  - `pinnedSendClearsPin`;
  - `pinnedUserUploadSendsPreparedBytes` and `latestUserUploadSendsPreparedBytes` (the body has the prepared JPEG, not the original HEIC);
  - `reusedUploadRepreparedAfterMaxEdgeChange` (prepared at 2048, setting changed to 3072, reused: re-prepared from the original at 3072 and the asset's `prepared*` fields updated; no `inputMissing`);
  - `reusedUploadRepreparedWhenPreparedFileMissing`;
  - `multipleAttachmentsInOrder`;
  - `modelImagesOrdinalFollowsPartsOrder` (a response with text, image, text, image: ordinals 0 and 1; the next `.latest` send uses ordinal 1);
  - `refusedOutcomeStoredNotAutoRetried` (`resp_image_safety.json`: state `refused`, `refusalReason == "IMAGE_SAFETY"`, `errorMessage` equal to the fixture's `finishMessage`, no reply parts, `details` stored; exactly one request recorded by the mock, `attempt == 1`, no CIVIC rebuild);
  - `refusedWithTextKeepsTextOutOfReply` (`resp_refused_with_text.json`: the reply has no parts; the text is only in `details`);
  - `userRetryAfterRefusalSucceeds` (`resp_image_safety.json`, then `retry(requestID:)` answered by `resp_text_image.json`: the same request runs in place, state `succeeded`, `attempt == 2`, the reply parts filled, and `refusalReason`, `errorMessage` and the refusal `details` cleared; a second case answers the retry with `resp_image_safety.json` again and ends `refused` with `attempt == 2`);
  - `apiErrorStoredWithDetails`;
  - `noticesPersistedAndReloaded`;
  - `undecodableImageKeepsPreviousEditBase` (turn 1 succeeds with a real image; turn 2's reply is `resp_bad_image.json`, whose only image part is undecodable: the notice is stored and no `ImageAsset` is created; turn 3, with no attachments or pin, selects the turn-1 image as `.latest` and sends its original bytes; D§2.6, D§11 Q3);
  - `rateLimitRetriesThenSucceeds` (429 then 200; `attempt == 2`, `autoRetriesUsed == 1`; the recorded `nextAttemptAt` and `TransportJob.earliestBegin` equal now + the RetryInfo delay; the sleeper is advanced by hand);
  - `retryCountersSurviveRelaunch` (429, then a new `GenerationService` and `DataStore` on the same container, then 429 again: the third result finishes, because the persisted `autoRetriesUsed` is used);
  - `manualRetryResetsAutoBudget`;
  - `civicFallbackRebuildsOnceAndPersistsFlag` (sets `civicFallbackUsed`; `setOmitCivicOnMain` is called once);
  - `nextSendAfterCivicFallbackHasFourCategories` (through a main-actor `AppSettings`: the next resolved send has 4 categories without relaunching);
  - `emptyBodyRetriedWithinSharedBudget`;
  - `resourceTimeoutNotRetried` (`.timedOut` with 1800 s elapsed finishes as "Timed out");
  - `backgroundCreatedRetryRecreatedOnActive` (`AppActivity` inactive when the retry is made → flag set; `appBecameActive()` cancels it by `taskIdentifier` and starts a replacement; the old task's cancel completion is ignored);
  - `beganEventMovesToInFlight`;
  - `systemCancelBecomesInterrupted` and `userCancelStaysCancelled`;
  - `preparationHoldsBackgroundAssertion` (begin before `createSend`, end after `start`, with `RecordingBackgroundTaskProvider`);
  - `assertionExpiryMarksInterrupted` (expiry fired mid-shrink: no task started, the request is `interrupted`, no partial `body.json` left);
  - `noKeyFailsPreparation`;
  - `tooLargeFailsBeforeNetwork` (no request is recorded by the mock);
  - `onePerChatEnforced`;
  - `parallelChatsAllowed`;
  - `regenerateUsesRecordedSettings` (change the defaults and overrides after the first send; the regenerate body still has the original values);
  - `regenerateKeepsPriorReply`;
  - `retryInPlaceIncrementsAttempt`;
  - `cancelInFlight`;
  - `deleteWhileInFlightDiscardsLateCompletion`;
  - `notificationPostedWhenInactive` (bodies: "Image ready"; "Request refused: IMAGE_SAFETY" for a refusal);
  - `notificationSuppressedWhenChatVisible`;
  - `notificationSuppressedWhenToggleOff` (`notifyOnBackgroundCompletion = false`: nothing posted);
  - `finishedEventsCallsRelayAfterParse` (a `.completed` and a `.finishedEvents` yielded back to back: the relay is called only after the reply is saved);
  - log assertions (through `ActivityLogProbe`; each also calls `assertPaired()`):
    - `logsSendBeginParametersAndResult` (a default text-to-image send: the Send Begin contains `gemini-3.1-flash-image · 16:9 · 2K · safety BLOCK_NONE · modalities TEXT+IMAGE`, `input none` and the full prompt in quotes; Prepare request, Attempt 1 and Parse are sub-actions of it; the Attempt 1 Begin has `POST /v1beta/models/gemini-3.1-flash-image:generateContent` and the body size equal to the written `body.json` size; the Send Result is `success` with `HTTP 200`, the image's pixel size and `finish STOP`);
    - `logsInputSelectionAndCoercion` (a `.latest` edit of a model output shows `input latest (model output img …, 2752×1536 JPEG …, sent as original)`, and its Prepare request Begin says `original bytes (model output)`; a `.latest` reuse of an upload shows `input latest (upload img …, <original> → sent <prepared>)`; a 3 Pro chat with a 1:8 / 512 override shows `aspect 1:8 → 16:9` and `size 512 → 1K`);
    - `logsRetryDecisionAndAttempts` (in `rateLimitRetriesThenSucceeds`: Attempt 1 ends with HTTP 429, then a step `auto-retry 1/2 in 2.0 s: HTTP 429 RESOURCE_EXHAUSTED (RetryInfo 2s)`, with the delay equal to the RetryInfo value, then Attempt 2 ends with HTTP 200; the task-identifier step is on each Attempt, not on the Send);
    - `logsRefusedResult` (`resp_image_safety.json`: the Send Result is `refused` with `IMAGE_SAFETY` and `HTTP 200`; `ActivityLogQuery.lastError` returns this Send);
    - `logsEmptyReplyAsFailed` (`resp_no_parts_max_tokens.json`: the request is `empty`, the Parse and Send Results are `failed` with `empty reply · finish MAX_TOKENS`, and `lastError` returns this Send);
    - `flushesBeforeStoringActionID` (a slowed-down store: `createSend` isn't called until the Send Begin is in the file);
    - `assertionEndFlushesFirst` (with `RecordingBackgroundTaskProvider`: every `end`, and the expiry path, follows a completed flush, and the expiry's `interrupted` Result is in the file);
    - `logsApiErrorTruncated` (`Errors/err_500_text.txt` padded to 5 KB: the failed Result holds at most 2 KB of the body and the cut note);
    - `logsCancelAndSystemCancel` (user Stop: a Cancel action and the Send ending `cancelled`; a force-quit cancel: the Send ends `interrupted` with the cancel reason);
    - `logsNotificationStep` (posted with the body "Image ready" when inactive; "not posted: chat is on screen" when visible);
    - `relaunchContinuesSendAction` (start a send, then build a new `ActivityLog`, `DataStore` and `GenerationService` on the same files before the completion is delivered: the completion, parse and Result are logged under the original Send ID; the old Attempt 1 is closed by name; nothing is marked interrupted);
    - `lateCompletionLoggedAsNewAction` (a completion for an `interrupted` request: a Late completion action names the request, its begin's `relatedID` is the original Send ID, it ends `success`, `ActivityLogQuery.tree` of the Send includes it, and `lastError` no longer returns the Send);
    - `retryPointsRequestAtRetryAction` (a manual Retry: a new Retry action whose Begin states the attempt and "auto-retry budget reset", and the request's `activityActionID` is the Retry's ID).
- `ReconcilerTests`:
  - `liveTaskKept`;
  - `liveDelayedTaskThatBeganMovesToInFlight`;
  - `orphanInterruptedAfterGrace`;
  - `lateCompletionOverridesInterrupted`;
  - `forceQuitCancelBecomesInterrupted` (late `NSURLErrorCancelled` with the force-quit reason);
  - `completeMarkerReparsed`;
  - `preparingMarkedInterrupted`;
  - `storedParsingStateReparsed` (state `parsing` with the `.complete` marker present is re-parsed, not interrupted);
  - `reconcileActionLogged` (a Reconcile action, origin `system`, with one step per request decision);
  - `orphanedLogActionsClosedAsInterrupted` (an earlier instance left a Save to Photos action open: it gets `Result: interrupted`);
  - `actionOfLiveRequestKeptOpen` (an earlier instance left a Send and its Attempt 1 open for a request that still has a live task: neither is closed, and the Send gets a step naming the request);
  - `graceExpiryClosesActionInterrupted` (an orphaned `inFlight` request is marked interrupted after the grace timer, and its Send is closed `interrupted` with the reason).
- `AppEnvironmentLaunchTests` (with fakes, not the test-host singleton): `reconcilerRunsWithoutFirstFrame`; `janitorWaitsForReconciler`; `launchActionIsFirstAndPaired` (on a fresh root, the first entry in the file is the Launch Begin with the version, build, iOS version and mock mode; a later step gives the application state, `background` when the fake says so; the Launch Result comes after `didFinishLaunching`'s Reconciler start); `resetDeletesLogBeforeLaunchBegin` (DEBUG: with a log file holding earlier entries and `-ResetStore 1`, the new file's first entry is this run's Launch Begin, there's no Log cleared action, and no Launch Result is orphaned).
- `BackgroundEventsRelayTests`: `backgroundEventsActionLogged` (the Begin has the session identifier; `callAndClear` writes the Result with the completion count); `flushesBeforeCompletionHandler` (with a slowed-down store, the handler is called only after the Background events Result and the preceding Send Result are in the file).
- `ActivityLogRedactionTests` (D§9 suite 15; the custom model ID route is checked in M8's `SettingsBindingsTests.customIDHoldingKeyIsScrubbed`), with the probe's `sanitize:` set to `Redactor.forLog(secrets: { registry.all })`: a key-shaped sentinel (`"AIzaSyD-SENTINEL-do-not-log-0123456789x"`, 39 characters) in the `InMemoryKeyStore`; a success; `rateLimitRetriesThenSucceeds`; an error whose body echoes `?key=<sentinel>` and is 5 KB long; an API error whose message holds the sentinel with no `key=`; a `URLError` whose description holds it; a send whose prompt holds it; `resp_thought_parts.json` with a `thoughtSignature`; and a `ModelAvailabilityService.validateKey`. The run is repeated with a stored key that isn't key-shaped (`"not-a-key-SENTINEL-42"`), so the registry is tested on its own. Neither the file bytes nor `probe.osLogStrings` contain either sentinel, `x-goog-api-key`, a match of `[A-Za-z0-9+/]{100,}`, or the fixture's thought signature; the logged error body is at most 2 KB plus the note.
- `ConnectivityMonitorTests`: the fake monitor's values reach subscribers in order.
- `ModelsClientTests`: paging; `flashMissingWarning`; `keyRejected400ApiKeyInvalid`; `403Rejected`; `networkErrorMapsToUnreachable`; `getModelForCustomID`. `ModelAvailabilityServiceTests` (M8 adds more): `refreshLogged` (the Begin has the reason and `GET /v1beta/models?pageSize=1000`; the Result has the model count and whether Flash is listed); `validateKeyLoggedWithoutKey`.

**Simulator verification (headless).** There's no UI yet. Check that the app launches with `-UITestMockGemini 1 -ResetStore 1`, that `log show --predicate 'subsystem == "com.andrewpurtell.imagegen"' --last 2m` (or `xcrun simctl spawn $UDID log show ...`) shows the mirrored `[Launch …] Result: success` line, with mock mode on, from the `store` category, and that it doesn't crash. Check that `"$(xcrun simctl get_app_container $UDID $BUNDLE_ID data)/Library/Application Support/ImageGen/Logs/activity.jsonl"` exists and that its first line is the Launch Begin (true because `-ResetStore 1` deleted the earlier log before the `ActivityLog` was created).

**Done when**
- [ ] `TransportTests`, `BackgroundConfigTests`, `GenerationServiceTests` (including the log assertions), `ReconcilerTests`, `AppEnvironmentLaunchTests`, `BackgroundEventsRelayTests`, `ActivityLogRedactionTests`, `ConnectivityMonitorTests`, `ModelsClientTests` and `ModelAvailabilityServiceTests` pass, along with every earlier suite.
- [ ] `GenerationServiceTests.endToEndTextToImage` asserts SHA-256 equality between the stored output file and the fixture's decoded bytes.
- [ ] `GenerationServiceTests.regenerateUsesRecordedSettings` passes.
- [ ] The production configuration (`URLSessionTransport.backgroundConfiguration(bundleID:)`) is unit-tested for every value in the D§4.6 table (`BackgroundConfigTests`), without creating a session.
- [ ] No warnings; lint passes, including `no-key-in-activity-log`. A grep for `apiKey` in `Logging` calls finds nothing.
- [ ] `scripts/build.sh --release` succeeds (the Release branch of `DebugHooks` compiles and nothing else references `DebugSupport/`).
- [ ] `scripts/live-smoke.sh` exists, and without a key it prints "skipped (no GEMINI_API_KEY)".

---

## M5: Core UI (onboarding, chat list, chat, composer, pills, pin)

**Goal.** The app can be used end to end with text prompts and image reuse in the simulator against the mock. All reply states render. The per-chat pills for model, aspect and resolution work. Edit from here works. The Developer menu shows the last action, the last error and the full log, and clears the log (D§3.10).

**Files and types**
- `Features/Onboarding/OnboardingView.swift` and `OnboardingModel.swift`: D§3.2, using `ModelsClient`. In mock mode, `-Scene onboarding` shows it, and validation succeeds against the mock models list. `OnboardingModel` registers the typed key with the `SecretRegistry` before validating it, then logs Save API key (where it came from, never the key or its length) with Validate key as a sub-action, ending saved, rejected (the API status and message) or unreachable, plus Save Anyway. The follow-up refresh, begun once the key is saved, is its own Models refresh action (origin `user`, reason `key saved`), so Save API key doesn't wait for it (D§4.13).
- `Features/ChatList/ChatListView.swift` and `ChatRow.swift`: D§3.3 (the toolbar: Settings leading; `DeveloperMenu` then New Chat trailing; `@Query` sorted by `updatedAt`; swipe Rename/Delete with confirmation; context menu; `ContentUnavailableView`; activity indicator and red dot from the latest request state: the dot for `failed` or `refused`, D§3.3).
- `Features/ChatList/RenameAlert.swift`, a modifier shared with the chat screen.
- `Features/Chat/ChatView.swift`: D§3.4 transcript (`ScrollView` + `LazyVStack`, `.defaultScrollAnchor(.bottom)`, a jump-to-latest glass button) and the navigation title, the `DeveloperMenu` and, next to it, the chat menu. `onAppear` and `onDisappear` update `AppActivity`; on disappear it calls `deleteIfEmpty`.
- `Features/Chat/ChatScreenModel.swift`: `@Observable @MainActor`, the only composer model (there is no separate `ComposerModel` type; M6 adds `ChatScreenModel+Attachments.swift`). It holds the composer text (draft debounced 500 ms), resolved pill values via `GenerationSettingsResolver`, chip state via `InputSelector.implicitBase` and the pin, send enablement via `InputSelector.canSend` (with `TrayCounts` all zero until M6), the `isNetworkUnavailable` flag from `ConnectivityMonitoring`, and the `send()`, `stop()`, `regenerate`, `retry`, `delete`, `pin`, `editAndResend(userMessageID:)` and `newChat()` actions. `editAndResend` (D§3.4, D§3.6) loads the message text (with the non-empty-draft confirmation), restores the pin for `.pinned`/`.latest`, and sets `isTextFieldFocused`; M6 adds the attachment cloning to the same function in `ChatScreenModel+Attachments.swift`. `newChat()` creates an empty conversation through `DataStore` and replaces the current chat on the navigation path with it (D§3.4). The refused card's Edit and New Chat buttons call these; from M6 the Edit and Resend menu item calls `editAndResend` too. It forwards to `any GenerationServicing` (M4) and `DataStore`, so tests inject a fake. It logs (section 2.8) New chat, Rename chat, Delete chat, Delete message, Pin, Unpin, Copy (prompt or reply text, with the character count), Edit and Resend, and a Chat setting change for every per-chat override change: a Model, Aspect or Resolution pill choice, choosing "Default" (which clears the override), and each picker in "Chat settings…" (the chat, the setting, old → new or `Default`, where; the Result has the effective value with any coercion). Titles, message text and copied text are `\(private:)` segments. It also asks for notification permission on the first send (unless `-SkipNotificationPrompt`) and logs that as a Notification permission action (origin `system`, so Last Action still shows the Send; Result granted or denied with the authorization status). Send, Regenerate, Retry and Cancel are logged by `GenerationService`. The chat list's Rename and Delete go through the same logged functions.
- `Features/Chat/MessageRow.swift`, `UserBubble.swift`, `ModelReplyView.swift` (text runs through `MarkdownView`; the "No image returned" badge derived from the stored parts; notices from `noticesData`), `ReplyMetadataLine.swift` (D§3.4 metadata, with ⚠︎ from `SizeClass`), `PendingReplyCard.swift` (`TimelineView`, the D§3.4 state labels including "Waiting for network" and "Retry scheduled", Cancel), `ReplyStatusCard.swift` (glyph, title, message and buttons straight from a `ReplyPresentation` mapping that implements the D§3.4 card table; a refused reply shows only the title "Request refused: <reason>" and the buttons Retry, Edit, New Chat, or Edit, New Chat plus the one-line note for `PUP_LIMITED_DISABLED`, with Edit left out when the originating user message was deleted), `DetailsSheet.swift` and `ReplyInfoSheet.swift`.
- `Features/Chat/ImageThumbnailView.swift`: async thumbnail with a placeholder frame sized from the stored pixel dimensions; decodes go through M3's `DecodeTimer`.
- `Features/Chat/MessageActionsMenu.swift`: Copy Prompt, Delete (user), Copy Text, Regenerate (disabled with the reason), Info and Delete (model), plus an empty `// MARK: M6 items` section.
- `Features/Chat/ImageContextMenu.swift`: **Edit from here** and **View** (View opens a placeholder until M7), plus a `// MARK: M7 items` section.
- `Features/Chat/Composer/ComposerView.swift`: the D§3.5 layout in `.safeAreaBar(edge: .bottom)` and `GlassEffectContainer`, with `ContextChips.swift` (the pin chip with ✕ to unpin, and the informational implicit-base chip "Editing latest image", which has no ✕ and no dismiss action, D§3.5), `SettingsPills.swift` (Model, Aspect, Resolution `Menu`s, grouped as in D§3.5, filtered by capability; the first item of each is "Default (<current global default>)" built from `AppSettings.defaultAspectRatio` / `defaultImageSize`, showing the coerced value with ⚠︎ when the model doesn't support it, so "Default (16:9)" and "Default (2K)" out of the box; an accent dot on overrides, a caution glyph on coercion), and `ComposerInputRow.swift` (the **+** menu placeholder disabled until M6, the text field, Send/Stop).
- `Features/Chat/ChatSettingsSheet.swift`: "Chat settings…", the same three pickers as the pills.
- `Features/Settings/SettingsView.swift` stub: the API Key section only (status, Remove Key → onboarding, through `APIKeyStore.delete()`, logged as Remove API key by its `APIKeySectionModel`). M8 expands it. Onboarding saves through `APIKeyStore.save(_:)`.
- `Features/Developer/` (D§3.10):
  - `DeveloperMenuModel.swift`: `@Observable @MainActor final class`, one instance created by `AppEnvironment` and passed to both toolbars through `.environment`. At launch it subscribes to `ActivityLog.changes()` (the first value comes from the index once it's loaded) and keeps the latest `ActivityLogStatus`. It exposes `hasError` (`lastErrorID != nil`), `lastActionID` and `lastErrorID`, so the menu's state is current without opening a sheet;
  - `DeveloperMenu.swift`: a toolbar `Menu` with `Image(systemName: "hammer")` and `.accessibilityLabel("Developer")`, shown in Release too. Items: Last Action, Last Error (`.disabled(!menuModel.hasError)`), Full Log, a divider, and Clear Log… (`role: .destructive`) with its `confirmationDialog`. The same view, reading the same `DeveloperMenuModel`, is used on the chat list and the chat screen;
  - `LogViewerModel.swift`: `@Observable @MainActor`. On open it fixes the action to show (`lastActionID` or `lastErrorID` from `DeveloperMenuModel`, or none for Full Log), loads `ActivityLog.entries(tree:)` or `entries(after: 0)` off the main actor, and applies `ActivityLogQuery` and `ActivityLogFormatter`. While the sheet is open it subscribes to `changes()`, refreshing at most every 250 ms with `entries(after: lastSeenSequence)`: it formats only the new entries, appends those that belong to the shown tree (or all, for Full Log), and never re-runs the selection, so the sheet stays on the action it opened with. It exposes `content` (an attributed string for `LogTextView`, with the range appended by the last refresh), `isInProgress`, `plainText` for Copy, and `shareFile`;
  - `LogTextView.swift`: a `UIViewRepresentable` around a read-only `UITextView` (TextKit 2, `isEditable = false`, `isSelectable = true`, the monospaced caption font; it does its own scrolling), which appends new text to its text storage instead of replacing it, and keeps the bottom pinned when the user is already at the bottom. It allows selecting any range, within a line or across lines (D§3.10);
  - `LogViewerSheet.swift`: a `NavigationStack` with the view's title; `LogTextView`; the "In progress" label; a Done button and toolbar Copy and Share. Full Log scrolls to the bottom on open and stays pinned while at the bottom. "No log entries" when empty;
  - `LogTextFile.swift`: `struct LogTextFile: Transferable` with a `FileRepresentation(exportedContentType: .plainText)` that writes the view's text to a temporary `ImageGen-log-<yyyy-MM-dd-HHmm>.txt` when shared.
  
  Opening, copying and sharing the log are not logged (D§4.13).
- `App/RootView.swift`: switches between onboarding and the chat list, sheets, the notification-router path binding, and `-Scene` handling through `DebugHooks.initialScene()` (the Release stub returns nil).
- `DebugSupport/DemoSeeder.swift`; `LaunchOptions` scene routing (`SceneRoute`), reached only through `App/DebugHooks.swift`.
- Haptics with `.sensoryFeedback` (impact on send; success on completion while visible); the notification permission request on first send.

**Notes.** D§3.1–3.6 and D§3.9. Custom glass is used only in the composer and on the jump button. Every icon button has an `accessibilityLabel`. The pill labels use `ModelDescriptor.shortName`, `AspectRatio.rawValue` and `ImageSize.rawValue`.

**Tests (unit, view-model level)**
- `ChatScreenModelTests` (`@MainActor`, with a fake `GenerationServicing`):
  - `sendEnablement`;
  - `pillsShowDefaults16x9And2K`;
  - `defaultItemLabelFollowsGlobalDefault` (out of the box "Default (16:9)" / "Default (2K)"; after `AppSettings` is set to 1:1 / 1K, "Default (1:1)" / "Default (1K)"; with 3 Pro and a default of 1:8, "Default (16:9 ⚠︎)");
  - `overrideSetsDotAndPersists`;
  - `chooseDefaultClearsOverride`;
  - `proHidesExtremeRatiosAnd512`;
  - `coercionShowsCaution`;
  - `disabledModelOverrideShowsFlashWithCaution`;
  - `implicitChipIsInformational` (shown when rule 3 applies, with the latest image's thumbnail; it exposes no dismiss action, and the send's selection is `.latest`);
  - `pinChipDimmedWithAttachments` (stub tray count);
  - `waitingForNetworkLabel` (fake `ConnectivityMonitoring` unsatisfied while a request is `inFlight` → the label shows; satisfied → it doesn't; never for `preparing`);
  - `stopCancels`;
  - `draftDebounced`;
  - `refusedCardEditLoadsComposerAndFocuses` (on a refused reply whose request used `.latest`: the composer holds the user message's text, the pin is set to that request's input image, `isTextFieldFocused` is true, and nothing is sent; a non-empty draft asks for confirmation first);
  - `refusedCardEditOnRegeneratedReplyTargetsSourceMessage` (a refused reply made by Regenerate: Edit loads the text of the user message of the source request);
  - `refusedCardNewChatCreatesAndNavigates` (a new empty conversation exists and is on the navigation path in place of the refused chat, which is unchanged);
  - `chatActionsLogged` (New chat, Rename chat, Delete chat, Delete message, Pin, Unpin and Copy each log a Begin with its parameters (for example `chat 08d1 · "Lighthouse" → "Harbor"`, or `img 7f3a`) and a `success` Result, and each pair is complete; in the recorded OSLog public text both titles are `<private>`);
  - `chatSettingChangesLogged` (choosing 1:1 on the Aspect pill logs `aspect ratio 16:9 → 1:1 · pill`; "Default" logs `… → Default`; a 3 Pro chat set to 512 through "Chat settings…" logs the change and a Result with `effective 1K (coerced)`; each paired);
  - `notificationPermissionLogged` (with a fake notification center, the first send logs one Notification permission action, origin `system`, ending `granted`; a second send logs none; `lastAction` still returns the Send).
- `APIKeySectionTests`: `removeKeyLogged` (Remove Key in the M5 stub logs Remove API key with the Keychain status, `success`, paired; the key's characters appear nowhere in the file).
- `OnboardingModelTests`: `saveKeyLogged` (with `InMemoryKeyStore` and the mock models list: a Save API key action with a Validate key sub-action ending with `HTTP 200` and the model count, followed by a separate top-level Models refresh with reason `key saved`; no backstop `parent finished first` result anywhere; the typed key's characters appear nowhere in the file); `rejectedKeyLoggedAsFailed` (`err_400_api_key_invalid.json`: Save API key ends `failed` with `API_KEY_INVALID`, and `lastError` returns it).
- `LogViewerModelTests` (with a probe log holding scripted entries):
  - `lastActionShowsNewestUserActionWithSubActions` (and skips a newer Janitor); `lastActionInProgressWhileOpen` (then not in progress once the Result arrives, without reopening);
  - `lastErrorIncludesRefused`;
  - `fullLogChronologicalNewestLast`; `liveUpdatesWhileOpen` (a refresh fetches only entries after the last seen sequence and appends them);
  - `openSheetStaysOnItsAction` (Last Action open on Send A; a new Send B begins: the sheet keeps showing A and doesn't add B's lines; reopening shows B);
  - `clearRequiresConfirmationThenStartsWithLogCleared` (cancelling the dialog keeps every entry; with a Send still running, the cleared log holds its begin before Log cleared, and its Result appears with its name when it arrives);
  - `shareFileIsPlainTextEqualToView`; `copyPutsViewTextOnPasteboard`;
  - `viewingIsNotLogged` (opening each view, Copy and Share add no entries).
- `DeveloperMenuModelTests`: `lastErrorDisabledWhenNone` (with no error in the log, `hasError` is false before any sheet opens); `hasErrorTurnsOnWithoutOpeningASheet` (a refused Send logged while no sheet is open sets `hasError` through `changes()`); `clearResetsHasError`; `bothToolbarsShareOneModel`.
- `AutoTitleTests`: the 48-character word-boundary cut.
- `ReplyPresentationTests`: one parameterized test with a row per line of the D§3.4 card table, plus each pending state (preparing, waiting for network, retrying with countdown, retry scheduled without countdown). Each row asserts the SF Symbol, the title, the message line and the buttons exactly. The refusal rows assert the title "Request refused: <reason>" for `IMAGE_SAFETY`, `IMAGE_OTHER`, `PROHIBITED_CONTENT` (prompt-level) and an unrecognized reason (verbatim), no message line, and the buttons `[Retry, Edit, New Chat]` in that order; `PUP_LIMITED_DISABLED` asserts "Request refused: PUP_LIMITED_DISABLED", the note "This API account is limited by Google; retrying won't help." and `[Edit, New Chat]`. With the originating user message deleted, a refusal asserts `[Retry, New Chat]` and `PUP_LIMITED_DISABLED` asserts `[New Chat]` (the D§3.4 "originating user message deleted" rows). The notification body for a refusal is "Request refused: <reason>". A second parameterized test covers the D§3.3 chat-row status: a red dot when the latest request is `failed` or `refused`, none for `succeeded`, `empty`, `cancelled` or `interrupted`, and the activity indicator for in-flight states.

**Simulator verification.** Execute `scripts/build.sh`, then capture verification states using `scripts/run-sim.sh <args>` followed by `scripts/shot.sh M5 <name>`, utilizing the simulator tool for user interactions. Each scenario specifies complete launch arguments independently, where `$BASE` denotes `-UITestMockGemini 1 -SkipNotificationPrompt 1` to isolate screens and suppress permission dialogs:

- `01-onboarding`: Launch with `$BASE -ResetStore 1 -Scene onboarding`. Displays "Connect Gemini", a secure key input field, and a prominent "Validate and Save" glass button.
- `02-chat-list-empty`: Launch with `$BASE -ResetStore 1`. Displays the "No chats yet" empty state message alongside a New Chat button.
- `03-chat-list-seeded`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1`. Displays five chat rows containing titles, message snippets, and timestamps; thumbnails for `lighthouse`, `uploads`, and `refused`; placeholder glyphs for `textonly` and `empty-overrides`; a red status indicator on `refused` reflecting an HTTP 429 error; and a toolbar configured with a leading Settings gear, a trailing Developer hammer, and a New Chat button.
- `04-chat-lighthouse`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse`. Displays the Developer hammer adjacent to the chat menu in the navigation bar, trailing user bubbles, leading model replies, metadata indicating `3.1 Flash · 16:9 · 2K · 2752×1536`, the "↻ Regenerated" header, composer pills for `3.1 Flash`, `16:9`, and `2K`, and the pin chip referencing turn 1.
- `05-aspect-menu`: From the 04 state, activate the Aspect pill. Displays "Default (16:9)" as the first option followed by Landscape, Square, Portrait, and Extreme sections.
- `06-resolution-menu`: From the 04 state, activate the Resolution pill. Displays "Default (2K)" as the first option followed by 512 px, 1K, 2K, and 4K options.
- `07-pro-menus`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:empty-overrides` and activate Aspect. Omits extreme ratios (1:4, 4:1, 1:8, 8:1) and displays accent indicators on overridden pills (9:16, 4K, 3 Pro).
- `08-pending`: Launch with `$BASE -ResetStore 1 -MockLatency 15`, initiate a new chat, send "a red fox", and capture within 5 seconds. Displays an aspect-shaped shimmer card, "Generating… 0:0x" timer, and Cancel button; Send transitions to Stop, while system permission alerts remain suppressed.
- `09-success`: Continue from 08 through request completion. Displays the generated reply image, full metadata line, and the composer informational chip "Editing latest image" without a dismiss control.
- `10-refused-and-error`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:refused`. Displays a "Request refused: IMAGE_SAFETY" card without a message line, offering Retry, Edit, and New Chat buttons; displays an "Error 429 RESOURCE_EXHAUSTED" card offering Retry and Details buttons.
- `11-retrying`: Launch with `$BASE -ResetStore 1 -MockScenario rateLimitThenSuccess -MockLatency 1`, initiate a new chat, and send "a red fox". Displays "Retrying in 2 s (attempt 2/3)" during deferred transport pause, culminating in successful generation.
- `12-lowres-warning`: Launch with `$BASE -ResetStore 1 -MockScenario lowRes`, initiate a new chat, and send "a red fox". Displays a warning reading "returned 1K" within the metadata line.
- `13-edit-from-here`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse`. Dismissing the pin chip (`13a-unpinned`) leaves the informational "Editing latest image" chip. Activating "Edit from here" on the turn 2 reply displays the context menu preview and pins turn 2 with an "Editing from pinned image" thumbnail chip (`13`).
- `14-dark`: Configure dark appearance via `xcrun simctl ui $UDID appearance dark` with 04 launch arguments. Verifies legible contrast and styling across dark interface components.
- `18-markdown`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:textonly`. Displays reply rendered as Markdown with a heading, bulleted list, and monospaced code block, accompanied by a "No image returned" badge.
- `20-developer-menu`: Launch with `$BASE -ResetStore 1 -SeedDemoData 1` and tap the hammer on the chat list. Displays menu items for Last Action, Last Error (disabled when the reset log contains no error), Full Log, and destructive Clear Log… in red.
- `21-log-last-action`: Launch with `$BASE -ResetStore 1`, create a new chat, send "a red fox", wait for completion, then select Developer menu > Last Action. Displays monospaced lines detailing Begin parameters (model, aspect, resolution, safety threshold, modalities, input selector, prompt), indented sub-actions for preparation, attempt, and parsing, followed by paired Result stating duration, HTTP 200, and image dimensions, with Copy and Share toolbar items.
- `22-log-last-error`: Launch with `$BASE -ResetStore 1 -MockScenario imageOther`, send "a red fox", and open Last Error after card renders. Displays the Send action with sub-actions and refusal Result detailing `IMAGE_OTHER` and HTTP status.
- `23-log-full`: Launch with `$BASE -ResetStore 1 -MockScenario rateLimitThenSuccess -MockLatency 1`, send "a red fox", wait for success, and select Full Log. Displays log scrolled to bottom with final success Result, preceding 429 attempt, retry countdown step, and second attempt; scrolling to the top (`23a-log-full-top`) reveals initial Launch and Reconcile actions.
- `24-clear-log`: Continuing from 23, open Clear Log… dialog (`24`), confirm deletion, and inspect Full Log (`24b-log-after-clear`). Displays confirmation dialog, followed by a cleared log containing only the `Log cleared` Begin event and success Result.

**Done when**
- [ ] All unit suites pass. No warnings; lint passes. `scripts/build.sh --release` succeeds.
- [ ] All 20 verification screenshots (including `13a-unpinned`, `23a-log-full-top`, and `24b-log-after-clear`) exist in `artifacts/M5/`, and `REVIEW.txt` marks each PASS against the verification requirements.
- [ ] After the screenshot runs, `grep -c 'mock-key' "$(xcrun simctl get_app_container $UDID $BUNDLE_ID data)/Library/Application Support/ImageGen/Logs/activity.jsonl"` prints 0 (the mock key never reaches the log).
- [ ] A manual flow in the simulator works (launched with `$BASE -ResetStore 1`): send in a new chat, wait for the success, send "make it night" with no attachment, and the second request's input is the first output. Check with the reply Info sheet, which shows "Input: Edited latest image" and its thumbnail.
- [ ] A live refusal flow works (launched with `$BASE -ResetStore 1 -MockScenario imageSafetyThenSuccess`): New Chat, send "a red fox"; the reply is the "Request refused: IMAGE_SAFETY" card with only Retry, Edit, New Chat (capture `19-live-refused`). Long-press the reply → Info shows "Message: Mock: image blocked by safety filter" and the Details JSON; the card itself shows neither. Tap Edit: the composer holds "a red fox", the text field is focused, nothing is sent; clear the composer. Tap New Chat: an empty chat opens; Back shows the chat list with a red dot on the refused chat. Reopen it and tap Retry: the same reply card becomes a success with an image (attempt 2) and the red dot is gone. The notification body is covered by `GenerationServiceTests.notificationPostedWhenInactive`.
- [ ] Rename, delete with confirmation, and the automatic deletion of an empty chat on back navigation all work (launched with `$BASE -ResetStore 1 -SeedDemoData 1`; spot-check screenshots `15-rename`, `16-delete-confirm`). For the automatic deletion, tap New Chat and go straight back: the new row is gone, and the seeded `empty-overrides` chat (which has one turn) is still there.
- [ ] The Regenerate check (the 04 arguments): in `lighthouse`, change Aspect to 1:1, then Regenerate an earlier reply. The new reply's metadata still shows `16:9 · 2K` (screenshot `17-regenerate-recorded`).

---

## M6: Attachments, paste, and Edit and Resend

**Goal.** Multiple attachments from Photos, Files and the clipboard, with preparation, the tray, budget display, reordering, and Edit and Resend.

**Files and types**
- `Features/Chat/Composer/AttachmentTray.swift`: 56 pt thumbnails, ✕, a spinner while importing or preparing, ⚠︎ with the reason and a Remove button, a long-press menu (Move Left, Move Right, Remove), and the caption "N images · X MB of 19 MB", or "Preparing images…" / "Remove the image that couldn't be prepared" while Send is blocked, plus the high-fidelity soft warning ("Best results with up to N images on <model>", from `ModelCapability.highFidelityInputLimit`).
- `Features/Chat/ChatScreenModel+Attachments.swift` (an extension of M5's `ChatScreenModel`; there is no separate composer model): `TrayItem { id, state(.importing/.preparing/.ready(PreparedImage, original: URL, info)/.failed(String)), origin }`. It handles import entry points and the 14-item cap with a toast, starts `ImagePreprocessor.prepare` per item using `AppSettings.maxUploadLongEdge`, computes the projected body size with `RequestBodyWriter.predictedSize`, feeds `TrayCounts(ready:pending:failed:)` to `InputSelector.canSend` (so Send is disabled while anything is importing, preparing or failed; D§2.2), exposes `canAddAttachments` (`trayCount < 14`), and sends a `SendDraft` whose `StagedAttachment`s are the ready items in tray order. It logs (section 2.8) each pick, paste or import as an Attach action (source, item count, tray count, max long edge), with a Prepare attachment sub-action per item (source type, pixel size, bytes, orientation, alpha → output MIME type, pixel size, bytes and duration, or the error; `cancelled` if the item is removed while preparing), and a step for extras dropped over the cap. The Attach is one async function that imports the items and then awaits every Prepare attachment in a task group; its `defer`-based Result is written after the last child ends, with the imported and prepared counts, each failure (import or preparation) with its reason, and the dropped count. It ends `failed` if any item failed and `success` otherwise (items dropped over the cap don't count as failures; D§4.13 Outcomes). Reordering and removing tray items log a Tray change (the image, the old → new position or "removed" with its state, and the tray count).
- `Features/Chat/Composer/AttachmentImporters.swift`:
  - PhotosPicker binding (`maxSelectionCount: max(1, 14 - trayCount)`, `.ordered`, `.images`, `.current`) and `loadTransferable(type: Data.self)` writing to `Staging/`. Never pass 0, which PhotosPicker treats as unlimited;
  - `.fileImporter([.image], multiple)` with security-scoped copying (no count limit, so the drop-extras toast still applies);
  - the + menu's "Photo Library" and "Files" items are `.disabled(!canAddAttachments)`, with the hint "Up to 14 images per message".
- `Features/Chat/Composer/PasteSupport.swift`: `struct PastedImage: Transferable` with `DataRepresentation(importedContentType: .image)` (plus explicit `.png`, `.jpeg` and `.heic` representations); a `PasteButton(payloadType: PastedImage.self)` that is shown only while `UIPasteboard.general.hasImages` and `canAddAttachments`, re-checked on `scenePhase == .active` and on `UIPasteboard.changedNotification`.
- The Edit and Resend item in `MessageActionsMenu.swift` (`// MARK: M6 items`), which calls M5's `ChatScreenModel.editAndResend` (the same function as the refused card's Edit button, D§3.4); this milestone extends that function: a confirmation if the draft isn't empty; clone the originals and prepared files into `Staging/` with `FileStore.cloneItem`; a clone whose prepared file is missing or whose `preparedLongEdgeSetting` differs from the current `AppSettings.maxUploadLongEdge` enters the tray as `.preparing` and is re-prepared from the cloned original through `ImagePreprocessor.prepare` (the same rule as pin and latest reuse, D§3.6, D§4.3); restore the pin to the image the request used (for reason `.pinned` or `.latest`). The Edit and Resend action's Begin states the message, the text length, the attachments to clone and the pin to restore. Clones that are re-prepared are Prepare attachment sub-actions, and Edit and Resend awaits them, like Attach, before its Result, which counts the clones made and re-prepared (and ends `failed` if a clone or re-prepare failed).
- The user bubble attachment grid (D§3.4: 1 / 2–4 / 5+ layouts) and the caption "Edited from pinned image" / "Edited latest image".

**Notes.** D§3.5, D§3.6, D§4.8 and D§6 #19–#22. The **+** menu items become active. Draft attachments live only in memory and in `Staging/`.

**Tests**
- `ComposerAttachmentsTests`:
  - `capAt14WithToast` (from Files: extras dropped with the toast);
  - `fullTrayDisablesAttachEntryPoints` (at 14: `canAddAttachments == false`, so Photo Library, Files and the PasteButton are off);
  - `pickerLimitNeverZero` (`max(1, 14 - trayCount)` for 0, 13 and 14 items);
  - `reorderMoves`;
  - `removeDeletesStagedFiles`;
  - `projectedSizeMatchesWriter`;
  - `failedItemBlocksSendUntilRemoved`;
  - `preparingItemBlocksSend`;
  - `attachmentsOnlyEnablesSend`;
  - `sendDraftKeepsTrayOrder`.
- `FileImportTests`: the security-scoped copy helper with a temporary file URL keeps the bytes (the SHA matches).
- `PasteSupportTests`: `PastedImage` imports PNG, JPEG and HEIC `Data`; the type is detected with `CGImageSourceGetType`.
- `EditAndResendTests` (DataStore + model): `clonesAttachmentsIntoTray`; `clonesKeepOrderAndGetNewOrdinals` (the resend's `ImageAsset`s get the tray index of the new send); `clonesRepreparedAfterMaxEdgeChange` (an upload prepared at 2048, the setting changed to 3072, then Edit and Resend: the cloned tray item is re-prepared from its original at 3072, becomes ready with `longEdgeSetting == 3072`, and the sent `RequestInput` uses the 3072 file; a clone made at the current setting is reused without re-preparing); `restoresPinForLatestReason`; `confirmationWhenDraftNonEmpty`; `refusedCardEditClonesAttachments` (the refused card's Edit on the `refused` seed's turn clones its upload into the tray, like the menu item).
- `GenerationServiceTests.multipleAttachmentsInOrder` (already exists) and a new `heicUploadSentAsJpeg` (the body's `mimeType` is `image/jpeg`; the original kept on disk is HEIC).
- Log assertions: `ComposerAttachmentsTests.attachLogsSourceAndPreparation` (3 Photos items: an Attach Begin with `Photos · 3 items · tray 0 · max long edge 2048`, and three Prepare attachment sub-actions, for example `HEIC 4032×3024 2.1 MB` → `success … JPEG 2048×1536 …`; the Attach Result comes after all three children's Results, and no `parent finished first` result is written); `attachPartialFailureEndsFailed` (3 items, one unsupported: an Attach step `import failed: …` gives the reason, no Prepare attachment is begun for it, the Attach ends `failed · 2 of 3 imported and prepared · 1 failed: …`, and `lastError` returns the Attach); `attachCapDropIsNotFailure` (the Files cap logs a step `dropped 2 over the 14-image cap` and the Attach ends `success` with the dropped count); `removeWhilePreparingCancelsChild` (removing a preparing item ends its Prepare attachment `cancelled` and logs a Tray change); `trayReorderLogged` (Move Left logs `img … · position 2 → 1 · tray 3`); `EditAndResendTests.editAndResendLogged` (clones and re-prepares counted in the Result, which follows the re-prepare children; paired).

**Simulator verification.** Verification scenarios default to launch arguments `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse` unless specified otherwise:

- `01-plus-menu`: Tap the plus button in the composer. Must display actions for "Photo Library" and "Files".
- `02-photos-picker`: Provision test media using `simctl addmedia` with `sample.heic` and two generated JPEGs, then select Photo Library from the plus menu. Must display the system photo picker supporting ordered multi-selection.
- `03-tray`: Select three images from the picker. Must display three attachment tray thumbnails, accompanied by size status reading "3 images · x.x MB of 19 MB", with the composer pin chip transitioning to a dimmed state ("Pinned image replaced by attachments").
- `04-tray-menu`: Perform a long-press gesture on any tray item. Must display contextual operations: Move Left, Move Right, and Remove.
- `05-sent-grid`: Dispatch message via Send. Must display the user message bubble rendering a 2-column grid of three image thumbnails, followed by the model reply.
- `06-paste`: Launch with default arguments augmented with `-SeedPasteboardImage 1`. The `PasteButton` must be visible, and activating it must add a tray item without displaying a system pasteboard prompt.
- `07-files-importer`: Select Files from the plus menu. Must display the system document picker interface.
- `08-edit-resend`: Long-press a previously sent user message and select Edit and Resend. Must populate the composer with the original prompt text and restore cloned tray items in order.

**Done when**
- [ ] All unit suites pass. No warnings; lint passes.
- [ ] The screenshots exist and pass review.
- [ ] Through the mock, the recorded request for `05-sent-grid` has `selectionReason == attachments` and 3 inputs in tray order, as shown by the Info sheet (screenshot `09-info-inputs`).

---

## M7: Image actions, export and the full-screen viewer

**Goal.** Save to Photos, Save to Files, Share and Copy, all with the original bytes, plus the zoomable viewer with paging.

**Files and types**
- `Export/ImageFile.swift`: `struct ImageFile: Transferable { url, utType, suggestedName }` and `static func suggestedName(date:id:ext:)`. `transferRepresentation` is static, so it can't read the instance's `utType`; it declares one representation per stored type (D§4.9):
  ```swift
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .jpeg) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .jpeg }
    FileRepresentation(exportedContentType: .png)  { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .png }
    // … the same for .webP, .heic, .heif, .gif and the AVIF type (UTType(importedAs: "public.avif") if no constant exists)
  }
  ```
  So exactly one representation applies to any instance, and it carries the real type. `.fileExporter(... contentTypes: [utType])` and the share sheet's item provider therefore see PNG as PNG, JPEG as JPEG, and so on.
- `Export/PhotoLibrarySaver.swift`: `requestAuthorization(for: .addOnly)`; `PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL:, options:)` with `originalFilename` set and `shouldMoveFile = false`. Typed results (`saved`, `denied`, `failed(Error)`).
- `Export/PasteboardWriter.swift`: `UIPasteboard.general.setItems([[utType.identifier: data]])`.
- `Features/Chat/ImageContextMenu.swift` (`// MARK: M7 items`): Save to Photos, Save to Files… (`.fileExporter`), Share… (a `Button` that presents `ActivityShareSheet`), Copy, View.
- `Export/ActivityShareSheet.swift`: a `UIViewControllerRepresentable` around `UIActivityViewController`, presented with `.sheet` from a `Button` (not `ShareLink`, which gives no tap or completion callback, D§4.9). Its one item is an `NSItemProvider` with the `ImageFile` registered through `register(_:)`, so the type and bytes are the original's. It takes `onComplete: (UIActivity.ActivityType?, Bool, Error?) -> Void`, wired to `completionWithItemsHandler`.
- `Features/Viewer/ImageViewer.swift` (`fullScreenCover`, a `TabView(.page)` over the message's images, chrome toggle, swipe down to dismiss at minimum zoom), `ZoomableImageView.swift` (`UIViewRepresentable` around `UIScrollView`, using the D§3.7 zoom math and double-tap to 2.5× at the tap point; the full decode happens off the main actor with `CGImageSourceCreateImageAtIndex`, timed through `DecodeTimer`, and the 1200 px thumbnail shows first; in DEBUG it logs `phys_footprint` under `imaging` after each full decode), and `ViewerToolbar.swift` (a bottom glass toolbar: Share, Save to Photos, Save to Files, Copy, Edit from here, Info).
- `Export/ExportLog.swift`: the logging for Save to Photos, Save to Files, Share and Copy (section 2.8, D§4.13). `PhotoLibrarySaver` and `PasteboardWriter` take the `ActivityLog` and log their own actions. The `.fileExporter` presentation and completion, and the Share buttons in `ImageContextMenu` and `ViewerToolbar`, call this file's helpers: `beginShare(_:)` in the Share button's action, before the sheet is presented, and `endShare(_:activityType:completed:error:)` from `ActivityShareSheet`'s `onComplete`, so each Share has exactly one Begin and one Result. Begin: the image ID, MIME type, bytes and pixel size (and the suggested name for Files). Result: the authorization status and saved, denied or failed for Photos; saved (the file name), cancelled or failed for Files; for Share, `success` with the activity type when completed, `cancelled` when dismissed, or `failed` with the error; the pasteboard item and type for Copy. A share sheet torn down without calling its completion (the view disappearing) ends the Share `cancelled` from `onDisappear`, at most once.
- `Support/Toast.swift`: a lightweight toast overlay for "Saved to Photos", errors and the 14-image cap. This can be shared with M6; if M6 lands first, reuse its version.

**Notes.** D§3.6, D§3.7, D§4.9 and D§6 #31. No `UIImage` conversion appears on any export path (lint).

**Tests**
- `ExportTests`:
  - `imageFileExportsByteIdentical`, parameterized over JPEG, PNG, WebP and HEIC originals (export through `FileRepresentation` to a temporary directory; exactly one representation applies and its content type matches the original's type; the SHA-256 matches);
  - `suggestedNameFormat`;
  - `pasteboardHoldsOriginalBytesOnlyOneType` (in the simulator host);
  - `utTypeFromMime` for jpg/png/heic/webp.
- `PhotoLibrarySaverTests`: authorization mapping, through a protocol around `PHPhotoLibrary` (a fake), plus one test tagged `.integration` that saves to the simulator library when `photos-add` has been granted. That test is skipped unless the env `IMAGEGEN_PHOTOS_GRANTED=1` is set.
- `ZoomMathTests`: fit scale, maximum scale (the larger of 1:1×2 and 4× fit), and the double-tap target rect.
- Log assertions in `ExportTests`: `saveToPhotosLogged` (with the fake library: the Begin has `img …`, the MIME type, bytes and pixel size of the original; the Result is `success` with `authorization authorized`; a denied fake gives `failed` with `authorization denied`); `saveToFilesLogged` (saved with the file name; cancelled gives `cancelled`); `copyLogged` (bytes and type equal to the original); `shareLogged` (calling the Share button's action begins Share with the image's MIME type and bytes; driving `ActivityShareSheet`'s `onComplete` with `(.airDrop, true, nil)` ends it `success · via com.apple.UIKit.activity.AirDrop`, with `(nil, false, nil)` ends it `cancelled`, and a second completion call writes nothing); `shareProviderCarriesOriginalType` (the item provider's registered type identifiers are exactly the original's UTType); each paired.

**Simulator verification.** Grant Photos add permission prior to testing via `xcrun simctl privacy $UDID grant photos-add com.andrewpurtell.imagegen`. Scenarios execute with `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse` unless specified otherwise:

- `01-image-menu`: Perform a long-press gesture on a model reply image. Must display contextual menu items: Edit from here, Save to Photos, Save to Files…, Share…, Copy, and View.
- `02-saved-toast`: Select Save to Photos. Must present the "Saved to Photos" confirmation toast overlay.
- `03-photos-app`: Launch the Photos application via `xcrun simctl launch $UDID com.apple.mobileslideshow`. The saved asset must appear in the library with metadata matching 2752×1536 JPEG.
- `04-files-exporter`: Select Save to Files… from the context menu. Must present the system document exporter displaying the structured filename format `ImageGen-YYYY-MM-DD-HHMM-xxxxxx.jpg`.
- `05-share-sheet`: Select Share… from the context menu. Must display the system share sheet complete with image preview thumbnail.
- `06-viewer`: Select View from the context menu. Must present the full-screen image viewer with the liquid glass toolbar.
- `07-viewer-zoomed`: Double-tap within the image viewer. Must zoom into the image centered at the tap coordinate.
- `08-viewer-landscape`: Trigger device orientation change to landscape. Image presentation must fit smoothly within landscape bounds.
- `09-viewer-paging`: Launch with the `uploads` seed, invoke View on the first image, and swipe horizontally. Must paginate to page 2 of 3.

- **Byte check in the simulator.**
  1. `APP=$(xcrun simctl get_app_container $UDID $BUNDLE_ID data)`.
  2. Compare `shasum -a 256 "$APP/Library/Application Support/ImageGen/Images/<conv>/<id>.jpg"` with the file exported to Files (On My iPhone), found under `$(xcrun simctl get_app_container $UDID com.apple.DocumentsApp groups)` or a search: `find ~/Library/Developer/CoreSimulator/Devices/$UDID -name 'ImageGen-*.jpg'`. The hashes must be equal.
  3. Record the result in `REVIEW.txt`.

**Done when**
- [ ] All unit suites pass; lint passes (no `jpegData`, `pngData` or `UIImageWriteToSavedPhotosAlbum` in Export/Features).
- [ ] The screenshots pass review, and the byte check of the exported file passes in the simulator.
- [ ] Viewer memory: open a 4K (5504×3072) mock image. Measure on the Mac, where simulator apps are ordinary host processes: `footprint -p $(pgrep -x ImageGen)` (its "phys_footprint" line), or read the DEBUG `imaging` log line with `phys_footprint` from `task_info` that the viewer writes after its full decode. It stays under 300 MB. Record the value in `REVIEW.txt`.

---

## M8: Settings, model availability and storage

**Goal.** The full Settings sheet of D§3.8. The global defaults for aspect ratio (16:9) and resolution (2K) can be edited and drive new chats. The models screen has availability and custom IDs.

**Files and types**
- `Features/Settings/SettingsView.swift`, with sections:
  - `APIKeySection` (status "Saved (…a1B2)", Replace, Validate Now, Remove);
  - `ModelsSettingsView` (fixed default, toggles for every catalog model other than Flash (3 Pro, 2.1, Flash Lite, 2.5 Flash Image and the `.legacyIfListed` 3 Pro preview alias), all on by default, where turning one off hides it from the model menu; availability labels, custom IDs validated through `GET models/{id}`, pull to refresh, "Last checked …", and the D§3.8 footnote about chats falling back to Flash);
  - `GenerationDefaultsSection` (aspect picker over the 14 Flash ratios, default 16:9; resolution 512/1K/2K/4K, default 2K; footnote; safety threshold with its four values, default Block none);
  - `UploadsSection` (1536 / 2048 / 3072 / 4096);
  - `AdvancedSection` (two toggles);
  - `NotificationsSection` (status, Open Settings, the toggle);
  - `StorageSection` (sizes, Clear thumbnail cache, Delete All Chats with a double confirmation);
  - `AboutSection` (version, build, model IDs, the SynthID note).
- The model availability banner in the chat when Flash isn't listed; the 404 card's "Open Models" button routes to `settings:models`.
- Logging (section 2.8): every Settings control logs a Settings change (the setting, old → new). Replace Key and Remove Key reuse M5's Save API key and Remove API key; Validate Now logs Validate key. Pull to refresh logs Models refresh (origin `user`). Add custom model logs the ID and the `GET models/{id}` result. Delete All Chats and Clear thumbnail cache log their counts and MB freed.

**Notes.**
- D§3.8, D§2.5 (runtime validation) and D§6 #7.
- Changing the global defaults affects chats with no override, and only for future sends. Recorded requests are never changed.

**Tests**
- `SettingsBindingsTests`:
  - `changingDefaultAspectAffectsNonOverriddenChatPills`;
  - `doesNotAffectOverriddenChat`;
  - `doesNotChangeRecordedRequests`;
  - `flashToggleDisabled`;
  - `customIDValidatedBeforeAdd` (mock 404 rejects it);
  - `removeKeyReturnsToOnboarding` (through an `InMemoryKeyStore` as the `APIKeyStore`);
  - `deleteAllChatsWipesStoreAndFiles`;
  - `storageSizesComputed`;
  - `changingMaxLongEdgeAffectsNewAttachments` (set 3072, attach an 8064×6048 image through `ChatScreenModel`: the prepared long edge is 3072, the recorded `longEdgeSetting` is 3072, and the projected size uses the 3072 file);
  - `disablingModelMakesOverriddenChatFallBackToFlash`;
  - `modelMenuOffersEnabledAvailableModels` (out of the box, with the mock list of Flash, 3 Pro and 2.1: the menu shows exactly those three; turning 2.1 off removes it);
  - `defaultMenuLabelsFollowChangedDefaults` ("Default (1:1)" / "Default (1K)");
  - `settingChangesLogged` (for example `default aspect ratio 16:9 → 1:1` and `max long edge 2048 → 3072`, each a paired Settings change);
  - `customIDValidationLogged` (`HTTP 404` → `failed`, not added); `customIDHoldingKeyIsScrubbed` (with `Redactor.forLog(secrets:)` as the probe's sanitizer, the key-shaped sentinel of `ActivityLogRedactionTests` typed into the custom ID field appears nowhere in the file or the OSLog strings);
  - `removeKeyLogged` (from the full Settings sheet, alongside Replace Key; no key characters in the file; M5's `APIKeySectionTests.removeKeyLogged` already covers the stub);
  - `deleteAllChatsLogged` (chat and image counts, MB freed; a fake `FileStore` that fails one removal makes the action end `failed` with the counts).
- `ModelAvailabilityServiceTests`: `refreshesAtMostEvery24h` (injectable clock; the foreground check logs a `system` Models refresh, pull to refresh a `user` one); `unlistedModelLeftOutOfMenuButFlashSelectable`; `uncheckedModelsOfferedUntilFirstCheck` (before the first check every enabled model is offered except the `.legacyIfListed` preview alias, which is offered only once `models.list` lists it).

**Simulator verification.** Verification scenarios execute with baseline launch arguments `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1` combined with scenario-specific arguments:

- `01-settings-top`: Launch with `-Scene settings`. Displays the API Key status as "Saved (…-key)" (mock mode), followed by navigation links to Models and Generation defaults.
- `02-models`: Launch with `-Scene settings:models`. Gemini 3.1 Flash Image displays as the fixed non-toggleable default. Catalog toggles for Gemini 3 Pro, 2.1, Flash Lite, 2.5 Flash, and the 3 Pro preview alias default to enabled. Unlisted models (Flash Lite, 2.5 Flash, 3 Pro preview) display the "Not listed for this key" status label, accompanied by the "Last checked" timestamp.
- `03-generation-defaults`: Scroll within settings. Displays default Aspect ratio set to 16:9, Resolution set to 2K, Safety threshold set to "Block none", and explanatory footnotes.
- `04-defaults-changed`: Update global defaults to 1:1 aspect ratio and 1K resolution, open a new chat, and inspect the Aspect and Resolution menus. Composer pills display `1:1` and `1K` without override accent indicators; the leading menu items reflect "Default (1:1)" and "Default (1K)".
- `05-uploads-advanced`: Scroll to upload settings. Displays 2048 px selected for max long edge, with both Advanced toggles visible (including "Request text alongside images" enabled by default).
- `05b-max-edge-4096`: Select 4096 px max long edge. In a new chat, attach an 8064×6048 image generated via test fixture scripts and provisioned via `simctl addmedia`. Send the message and verify the reply Info sheet records the input as `image/jpeg` with a 4096 px long edge, then restore the setting to 2048 px.
- `06-storage`: Scroll to storage settings. Displays local storage disk usage broken down by category, accompanied by destructive wipe actions.
- `07-notifications-denied`: Launch with `-ForceNotificationState denied`. Displays notification status as denied alongside an Open Settings action button.

**Done when**
- [ ] All unit suites pass. No warnings; lint passes.
- [ ] The screenshots pass review. In `04-defaults-changed`, a send records `1:1`/`1K` (Info sheet), and an earlier chat with an override keeps its own values.
- [ ] Changing the defaults back to 16:9 / 2K brings the new-chat pills back to `16:9` / `2K`.

---

## M9: Hardening, accessibility, performance and the regression pass

**Goal.** Ship quality. No new features.

**Tasks**
1. **Accessibility.**
   - Every icon button has a label. Check with `xcrun simctl spawn $UDID defaults write com.apple.Accessibility ...`, or with the Accessibility Inspector on the simulator if it's available, or by grepping that every `Button` with an `Image` only has an `.accessibilityLabel`.
   - Capture the chat and composer at `accessibility-extra-extra-extra-large`. The pills wrap, with no clipping.
2. **Dark mode** for the list, chat, viewer and settings.
3. **Landscape** for the chat and viewer.
4. **Performance.**
   - Seed a chat with 60 messages and 40 images (`-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedLargeChat 1`). Scroll from top to bottom and back with the simulator tool's swipes. The check is the log, not the eye: `xcrun simctl spawn $UDID log show --predicate 'subsystem == "com.andrewpurtell.imagegen" AND category == "imaging"' --last 5m` must contain **no** "main-thread decode" lines from M3's `DecodeTimer` (decodes over 16 ms on the main thread).
   - The 48 MP preparation peak memory, logged by `ImagePreprocessor` in DEBUG through `task_info` before and after (M3), is under 150 MB. Cross-check once on the host with `footprint -p $(pgrep -x ImageGen)`.
5. **Janitor at launch.** Plant orphan files and a stale request dir under the app's container, relaunch, and confirm they're gone.
6. **Reconciler in the simulator.** With `-MockLatency 30`, send, then kill the app with `xcrun simctl terminate` (this simulates termination, and the mock transport isn't background). Relaunch: the card shows "Interrupted…" with Retry, and Retry succeeds. Screenshot `M9/05-interrupted`.
7. **The full regression screenshot set.** Re-run every M5–M8 screenshot, including the M5 Developer menu and log viewer set (`20`–`24`), into `artifacts/M9/regression/` and review them.
8. **Live smoke and the R3 decision**, if the user provides `GEMINI_API_KEY` (otherwise R3 is settled in M10 D3):
   1. **Measure.** Run `scripts/live-smoke.sh`. Record the dimensions for R3 and R4 in `REVIEW.txt`, with the size class of the 16:9/2K edit sent with `["TEXT","IMAGE"]`.
   2. **Decide** (the user has already decided, D§11 R3; no further approval is needed). If that edit is in the 2K class, keep the default and record "R3: not capped". If it comes back in the 1K class, the cap is confirmed: flip the default.
   3. **Flip, if capped.** Set the `includeTextModality` default to `false` in `AppSettings` and in `GenerationDefaults` (M0 shared types); rename and update `AppSettingsTests.defaultsBlockNoneAnd2048AndTextOn` to `…TextOff`; update any test or golden that relies on the default modality (goldens built with explicit `EffectiveSettings` are unaffected; `flash_image_modality_only.json` already covers `["IMAGE"]`); check that `flash_text_only_16x9_2k.json` still passes unchanged (it sets `includeTextModality = true` explicitly); update D§2.4, D§2.6 (the response-modalities deviation row: the app now defaults to `["IMAGE"]` while the pipe always sends TEXT+IMAGE), D§3.8, D§6 #18, D§9 (the live smoke test paragraph), D§11 R3, plan R-24b and M8 `05-uploads-advanced`, and the D§12 and plan change logs, to say the cap was confirmed and the default is now `["IMAGE"]`. The Advanced toggle still turns text back on. Then re-run the smoke test with the new default and record that the 2K edit comes back in the 2K class.
9. **Code review checklist.**
   - Run `scripts/lint.sh`.
   - Grep that the key never appears in logs.
   - Every `try?` on a file operation must be justified.
   - Look for `@unchecked Sendable` and justify each one with a comment.
   - Every `Task {}` in views must be tied to `.task` or cancellation.
   - Every `log.begin` has a `result` on every exit path, throws and cancellation included (section 2.8 rule 3). The store's pairing backstop isn't a substitute.
10. **Log coverage review** (D§4.13, section 2.8). It runs as three launches on one log, so only the first uses `-ResetStore 1`; each launch lists its complete arguments.
    - **Before starting:** `xcrun simctl addmedia $UDID` with three generated images (for example `ImageGenTests/Fixtures/Images/sample.heic`, `rotated_exif6.jpg` and `tiny_16x9.png`), and `xcrun simctl privacy $UDID grant photos-add com.andrewpurtell.imagegen`.
    - **Launch 1:** `scripts/run-sim.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1 -SeedPasteboardImage 1`, then exercise:
      - a send, a `.latest` edit and a Regenerate;
      - a Retry on the `refused` seed;
      - an attach of the 3 photos, then a paste, then a reorder and a removal in the tray;
      - a per-chat pill change and "Default" on the same pill;
      - Edit and Resend;
      - Save to Photos, Save to Files, Share (complete one, dismiss one) and Copy;
      - pin and unpin;
      - rename and delete a chat;
      - two Settings changes and a pull to refresh on Models.
    - **Launch 2** (the M9 task 6 kill, without wiping the log): `scripts/run-sim.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -MockLatency 30`, New Chat, send "a red fox", then `xcrun simctl terminate $UDID $BUNDLE_ID` within 10 s.
    - **Launch 3:** `scripts/run-sim.sh -UITestMockGemini 1 -SkipNotificationPrompt 1`, and wait at least 5 s for the Reconciler's grace timer.
    
    Then open Full Log and check that every action in the D§4.13 table that the run touched appears with its Begin parameters and a Result, and that sub-actions are indented under their parents. Check that Last Action and Last Error pick what D§3.10 says. Check that `grep -c 'mock-key'` on the log file prints 0, and that no line holds a base64 run. Record one line per table row in `REVIEW.txt` (`log <action>: PASS|FAIL <note>`). Screenshot `M9/06-log-after-relaunch`: Last Error shows the Send killed in launch 2 ending `interrupted`, and Full Log shows launch 3's Launch and Reconcile actions after it.

**Done when**
- [ ] `scripts/test.sh` passes with all suites. Coverage of `Gemini/`, `Pipeline/` and `Imaging/` is at least 85% lines (`xcrun xccov view --report build/logs/<latest>.xcresult`).
- [ ] No warnings; lint passes, including `scripts/lint.sh --self-test`.
- [ ] `scripts/build.sh --release` succeeds for the simulator, so the M10 Release device build has already compiled once.
- [ ] `artifacts/M9/` holds the accessibility, dark, landscape, interrupted and `06-log-after-relaunch` screenshots and the regression set, all PASS in `REVIEW.txt`, and the task 10 log coverage lines are all PASS.
- [ ] The performance numbers are recorded and within limits.
- [ ] If the live smoke ran: the R3 measurement is in `REVIEW.txt`, and the `includeTextModality` default matches it (on if 2K was honored, off if capped), with the tests and docs updated as task 8 says.

---

## M10: Device install and on-device validation

**Goal.** The app is installed on the user's iPhone from Xcode with their paid Apple Developer Program team, and passes the manual device script.

**Prerequisites (needs the user)**
1. Xcode › Settings › Accounts: signed in, with the team visible. Copy the team ID into `Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`). Then run `scripts/gen.sh`.
2. On the iPhone: Settings › Privacy & Security › Developer Mode **on**, then reboot. Connect it by cable (or the same Wi-Fi with pairing) and trust the Mac.
3. The first time, install from the Xcode GUI: open `ImageGen.xcodeproj`, choose the iPhone as the run destination, then Product › Run. This registers the device and creates the provisioning profile, which lasts a year with the paid team. This one-time install is all that's needed.

**Subsequent device deployments (automated once the device is paired)**
```
scripts/device-install.sh --release          # resolves DEVICE_UDID itself if it isn't set
# which runs:
DEVICE_UDID=${DEVICE_UDID:-$(xcrun devicectl list devices --json-output - 2>/dev/null \
  | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["result"]["devices"]; \
    print(next(x["hardwareProperties"]["udid"] for x in d if x["hardwareProperties"].get("platform")=="iOS"))')}
xcodebuild -project ImageGen.xcodeproj -scheme ImageGen -configuration Release \
  -destination "platform=iOS,id=$DEVICE_UDID" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVICE_UDID" build/DerivedData/Build/Products/Release-iphoneos/ImageGen.app
xcrun devicectl device process launch --device "$DEVICE_UDID" com.andrewpurtell.imagegen
```
Notes:
- `DEVICE_UDID` must be the **hardware** UDID (`hardwareProperties.udid`, in the `00008…-…` form), which is what `xcodebuild -destination id=` matches. The `Identifier` column of `xcrun devicectl list devices` is a CoreDevice UUID in a different format and won't match. `xcodebuild -project ImageGen.xcodeproj -scheme ImageGen -showdestinations` lists the valid `id=` values as a cross-check. `devicectl --device` accepts the hardware UDID too, so one value serves both commands. If more than one iPhone is connected, the script lists them and asks for `DEVICE_UDID`.
- With the paid team the profile lasts a year, so no periodic reinstall is needed; `device-install.sh` is for installing new builds. Data persists across reinstalls of the same bundle ID. (The free personal team's 7-day profiles don't apply.)
- Release builds exclude `DebugSupport/`.

### Manual on-device test script
Record each result in `artifacts/M10/DEVICE_RESULTS.txt` (`D<n>: PASS|FAIL notes`). Where a screenshot is useful, capture on the device:

- **D1 (Installation):** Install application via device installation script and launch. Confirms presentation of the onboarding "Connect Gemini" interface.
- **D2 (API Key Configuration):** Input user API key and trigger Validate and Save. Confirms key saved, navigation to chat list, Settings showing masked key "Saved (…last4)", and absence of Flash fallback warning.
- **D3 (Default Aspect Ratio and Resolution Parity):** In a new chat, send "a lighthouse at dusk, cinematic". Confirms reply generated within 10–60 seconds, metadata reading `3.1 Flash · 16:9 · 2K · 2752×1536` without resolution warnings. If a 1K fallback warning appears under dual text and image modalities, disable "Request text alongside images" in Advanced Settings and verify full resolution.
- **D4 (Per-Chat Override):** Adjust composer pills to 9:16 aspect ratio and 4K resolution, then send "same scene, vertical". Confirms portrait output with metadata `9:16 · 4K` at approximately 3072×5504 pixels.
- **D5 (Global Settings Defaults):** Set global defaults to 1:1 and 1K in Settings, initiate a new chat, and send prompt. Confirms composer pills display 1:1 and 1K, output rendered at 1024×1024, followed by restoring 16:9 and 2K defaults.
- **D6 (Edit Latest Reference Pipeline):** Within D3 chat, send "make it night" without attachments. Confirms informational chip and caption indicate "Edited latest image", with output derived directly from the D3 image.
- **D7 (Edit From Here Pinning):** Long-press the initial turn image, select "Edit from here", and send "add a boat". Confirms pin chip activates, clears upon transmission, and applies edits directly to the pinned image.
- **D8 (Regeneration Settings Reproduction):** Change composer aspect pill to 1:1, then select Regenerate on the D3 reply. Confirms the regenerated reply preserves original `16:9 · 2K` settings alongside previous output.
- **D9 (Multiple Attachments and HEIC Ingestion):** Attach two iPhone camera HEIC photos and one screenshot via Photo Library. Confirms attachment tray displays three items under the 19 MB total payload limit, send succeeds, and request inputs are recorded as `image/jpeg` at 2048 px max edge.
- **D9b (Configurable Maximum Long Edge):** Configure Uploads max long edge to 4096 px, attach a camera photo, and send. Confirms input recorded as `image/jpeg` at 4096 px long edge, followed by resetting to 2048 px.
- **D10 (Files Document Importer):** Attach an image via Files picker from local or iCloud storage. Confirms staged attachment joins tray and sends successfully.
- **D11 (System Pasteboard Ingestion):** Copy a photo in Photos and switch to the application. Confirms `PasteButton` displays and ingests image into attachment tray without triggering a system security alert.
- **D12 (Background Processing Under Device Lock):** Request a 4K generation and lock the device immediately. Confirms local notification "Image ready" arrives on the lock screen within two minutes, navigating directly to the completed chat turn upon activation.
- **D12b (Background Processing During Attachment Preparation):** With max edge set to 4096 px, attach five camera photos, send, and lock device immediately. Confirms background assertion sustains upload preparation and transmission to completion while locked.
- **D13 (Background Processing Under Application Switch):** Send prompt and transition to another application for two minutes. Confirms local notification fires and result is present upon returning to foreground.
- **D13b (Application Switch During Attachment Preparation):** Attach multiple images, send, and transition immediately to another application. Confirms preparation assertion completes processing and notification fires.
- **D14 (Foreground Notification Suppression):** Send generation prompt while remaining active in chat. Confirms system notification banner is suppressed while haptic feedback acknowledges completion.
- **D15 (Process Termination and Reconciliation):** Dispatch 4K request, terminate application immediately via app switcher, and relaunch after one minute. Confirms card renders "Interrupted…" status and user-triggered Retry recovers generation.
- **D16 (Offline Queuing and Reconnection):** Enable Airplane mode, dispatch message, hold in chat for 30 seconds, then disable Airplane mode. Confirms interface displays "Waiting for network" until connectivity restores and transmission succeeds.
- **D17 (Photos Library Export Fidelity):** Long-press generated image, select Save to Photos, and grant Add Only permission. Confirms toast confirmation and verifies saved asset in Photos matches original MIME type, pixel dimensions, and file byte size.
- **D18 (Files Export Byte Identical Verification):** Export image to Files on device, extract stored sandbox asset via `devicectl`, and verify SHA-256 hash equivalence against exported file.
- **D19 (Sharing and System Clipboard):** Trigger Share to Messages or AirDrop, and Copy to Notes. Confirms full-resolution image data transfers without transcoding.
- **D20 (Interactive Full-Screen Viewer):** Open image in viewer, perform pan, pinch, double-tap zoom, rotation, and swipe dismissal. Confirms smooth scaling, landscape container fit, and gesture handling.
- **D21 (Multimodal Markdown Output):** Request textual description on an existing image. Confirms model response renders formatted Markdown elements, or presents "No image returned" badge if text only.
- **D22 (Model Switching Parity):** Open model selector, switch to Gemini 3 Pro, verify unsupported extreme aspect ratios and 512 px resolution are hidden, and execute generation. Confirms reply metadata indicates Gemini 3 Pro.
- **D23 (Credential Rejection Handling):** Enter invalid API key in Settings and execute Validate. Confirms key is rejected, unsaved, and prior active key remains preserved.
- **D24 (Message Action Lifecycle):** Exercise Copy Prompt, Edit and Resend, Delete user message, and Delete reply. Confirms UI and persistence states match design specifications.
- **D25 (Chat Session Management):** Rename and delete chats, verifying modal confirmation details image counts, with disk storage reflecting reclaimed space.
- **D26 (Memory Footprint Validation):** Monitor resident memory in Debug Navigator during high-resolution multi-attachment workflows. Confirms peak memory remains under 300 MB without jetsam events.
- **D27 (Accessibility and Dark Mode Compliance):** Verify layout stability and readability under dark mode and accessibility Dynamic Type sizes.
- **D28 (Activity Log Background Traceability):** Open Developer menu > Last Action immediately following background completion (D12). Confirms Begin line details 4K parameters, nested preparation and attempt sub-actions, background arrival event, local notification step, and success Result.
- **D29 (Activity Log Error Inspection):** Inspect Developer menu > Last Error following forced termination (D15) and invalid credentials (D23). Confirms interrupted and failed states record appropriate diagnostic contexts while completely omitting API key material.
- **D30 (Activity Log Export and Clearing):** Share log as plaintext file and clear log history via Developer menu. Confirms zero occurrences of API keys in exported text and verifies cleared log resets to initial clear event.

**Done when**
- [x] D1–D25, including D9b, D12b and D13b, and D28–D30 are PASS in `DEVICE_RESULTS.txt` (D26 and D27 are recommended). Any FAIL has a filed fix, or is accepted by the user.
- [x] The result of R3 (TEXT+IMAGE honors 2K, yes or no) is recorded and reported to the user, and the shipped `includeTextModality` default follows the user's decision (off if capped, on otherwise).

---

## 4. Risks and mitigations (plan-level; product risks are in D§11)

## 4. Risks and mitigations

The engineering plan identifies key technical and execution risks across development milestones, establishing explicit architectural mitigations:

- **P1: Toolchain and Environment Readiness (Milestone M0):** Unaccepted Xcode licenses, missing iOS simulator runtimes, or uninstalled XcodeGen binaries block initial compilation. Mitigation relies on `scripts/doctor.sh` diagnosing pre-conditions and providing manual setup instructions, while `scripts/env.sh` targets `DEVELOPER_DIR` directly without requiring privileged `xcode-select` overrides.
- **P2: Provisioning Profile Expiration (Milestone M10):** Expired development profiles can prevent device launching. Mitigated by using an active Apple Developer Program team with standard one-year provisioning profiles. In addition, `scripts/device-install.sh` enables direct single-command re-installation while preserving persistent container data.
- **P3: Background URLSession Protocol Interception (Milestones M4, M10):** Foundation `URLProtocol` subclasses cannot intercept system background `URLSession` instances directly. Mitigated by parameterizing session configurations across transport components to support mock injection during testing, validating production configuration semantics in unit suites, and confirming background lifecycle behaviors on physical hardware (scenarios D12–D16).
- **P4: Swift 6 Concurrency Strictness Across Legacy Frameworks (Milestones M2, M4):** Concurrency isolation conflicts with `NSObject` delegate protocols, SwiftData models, and `@ModelActor` boundaries risk compiler failures. Mitigated by declaring non-isolated default boundaries, keeping persistence models nonisolated, transferring immutable snapshots across actors, protecting shared mutable state with `Mutex`, and restricting `@unchecked Sendable` strictly to audited boundaries.
- **P5: Parallel Test Execution State Contention (Milestones M1, M4):** Concurrent test execution contending on shared `MockURLProtocol` handlers produces flaky suites. Mitigated by tagging HTTP requests with unique per-test token headers registered in a thread-safe `Mutex` registry, with `.serialized` execution available as a fallback.
- **P6: Test Host Process Lifecycle Side Effects (Milestones M0, M4):** Unit tests running inside the application host can inadvertently launch background sessions, database reconcilers, or cleanup janitors. Mitigated by `AppEnvironment` detecting test-runner execution environments early during launch and disabling background tasks.
- **P7: System Pasteboard Type Incompatibilities (Milestone M6):** Standard `PasteButton` bindings expecting generic data may fail to match varied image pasteboard representations. Mitigated by defining a custom `Transferable` conformance (`PastedImage`) supporting explicit uniform type representations for JPEG, PNG, and HEIC, verified through unit tests and device scenario D11.
- **P8: Operating System API Name Drift (Milestones M0, M5):** Pre-release platform SDKs risk introducing breaking naming discrepancies in glass effect and concurrency APIs. Mitigated by `Support/PlatformProbe.swift` validating each platform API symbol during M0 compilation, catching discrepancies prior to feature development.
- **P9: Simulator Media Interaction Limitations (Milestones M6, M7, M10):** Simulator limitations handling photo library assets, security-scoped files, and camera formats risk verification gaps. Mitigated by automating media injection via `simctl addmedia`, granting privacy entitlements via command-line flags, and validating edge cases on physical hardware.
- **P10: Document Exporter File Inspection in Simulator (Milestone M7):** Locating files exported through system picker sheets within the simulator sandbox can be cumbersome. Mitigated by unit test verification asserting SHA-256 byte parity and on-device test scenario D18 verifying exact file hashes.
- **P11: Merge Contention Across Concurrent Tracks (Milestones M6–M8):** Parallel feature development on shared UI files creates source conflicts. Mitigated by strict subsystem folder ownership, modular menu extensions demarcated by clear source comments, and sequential integration merging.
- **P12: High-Resolution Test Fixture Performance Overhead (Milestones M1, M3):** Parsing 48 MP images and massive JSON payloads slows local automated test cycles. Mitigated by generating large fixtures once per test session into a local cache directory, gating heavy tests behind `.io` tags, and applying explicit execution timeouts.
- **P13: Simulator Keychain Security Entitlements (Milestone M2):** Unsigned test host processes encountering Keychain error -34018 fail credential persistence tests. Mitigated by configuring ad-hoc simulator signing (`CODE_SIGN_IDENTITY[sdk=iphonesimulator*] = -`) and executing tests within the application host process.
- **P14: Live API Generation Costs (Milestones M9, M10):** Live validation runs risk incurring unnecessary API billing charges. Mitigated by restricting smoke tests to 512 px and 2K resolutions, limiting total live hardware test iterations to approximately 15 requests.
- **P15: Accidental API Key Exposure in Artifacts (All Milestones):** Automated screenshot capture risks exposing API keys in documentation artifacts. Mitigated by enforcing `SecureField` entry, masking keys to their trailing four characters in Settings, utilizing dummy mock keys during automated runs, and prohibiting real credentials in automation scripts.
- **P16: Notification System Dialogs Blocking Automation (Milestone M5):** Unattended simulator runs can be blocked by modal notification permission prompts. Mitigated by requesting permission only upon first send, providing a `-SkipNotificationPrompt 1` debug flag to defer prompts, and incorporating the flag into all automated verification runs.
- **P17: Release Configuration Compilation Discrepancies (Milestones M0–M9):** Debug-only constructs leaking into production paths cause Release builds to fail late in development. Mitigated by routing all debug hooks through `App/DebugHooks.swift` enforced by linting rules, and validating `scripts/build.sh --release` at every milestone exit gate.
- **P18: Untestable Background Session Behaviors (Milestones M4, M10):** Complex background URLSession lifecycles, app relaunch deliveries, and forced termination cannot be simulated through standard unit tests. Mitigated by an append-only event stream architecture with persisted retry state and faked transport engines in unit tests, confirmed through hardware scenarios D12–D16.
- **P19: Incomplete Activity Log Instrumentation (Milestones M2, M4–M9):** Incomplete instrumentation or missing Result entries on error paths undermine diagnostic observability. Mitigated by strict activity log protocol enforcement, test suite assertion helpers (`assertPaired()`), automatic launch-time reconciliation of orphaned entries, and static analysis checks.

---

## 5. Traceability matrix

Engineering requirements correlate directly to design specifications, milestone delivery scopes, and validation criteria:

- **R-01: Deployment Target and Distribution Model.** The application is built as a personal iPhone application installed directly via Xcode using an active Apple Developer Program team profile, bypassing App Store and TestFlight distribution (Design §1.4, §10, §11 R9). Addressed in milestones M0 and M10. Verified through `project.yml` configuration and on-device test D1.
- **R-02: Platform Architecture and Visual Language.** The system targets iOS 26 minimum deployment, Swift 6 strict concurrency, SwiftData persistence, and the Liquid Glass visual hierarchy for iPhone exclusively (Design §1.4, §3.1, §5). Addressed in milestones M0, M2, and M5. Verified via build configuration, `check-warnings.sh` compiler passes, and M5 simulator review.
- **R-03: Reference Pipeline Parity.** The core generation pipeline replicates the OpenWebUI Gemini filter reference implementation, integrating chat conversational flows with Gemini REST image generation and iterative editing (Design §2). Addressed in milestones M1, M4, and M5. Verified through `PipeParityTests`, end-to-end `GenerationServiceTests`, and device tests D3 and D6.
- **R-04: Secure Credential Management.** API credentials are stored securely in the iOS Keychain (Design §3.2, §4.10). Addressed in milestones M2, M5, and M8. Verified via `KeychainStoreTests`, onboarding verification screenshot `01-onboarding`, and device tests D2 and D23.
- **R-05: Default Model Assignment.** Gemini 3.1 Flash Image serves as the mandatory, non-disableable default model for all sessions (Design §2.5, §3.8). Addressed in milestones M0, M1, and M8. Verified through `VocabularyTests.defaultModelIsFlash`, `AppSettingsTests.flashCannotBeDisabled`, and settings screenshot `02-models`.
- **R-06: Dynamic Model Catalog and Availability Filtering.** Provides an expandable catalog of available image generation models (Gemini 3 Pro, 2.1, Flash Lite, 2.5 Flash, and legacy aliases) selectable per chat, dynamically filtered against API key availability and user settings preferences (Design §2.5, §3.5, §3.8, §11 Q1). Addressed in milestones M0, M1, M2, M5, and M8. Verified via `VocabularyTests`, `SettingsResolverTests`, `ModelAvailabilityServiceTests`, M5 screenshot `07-pro-menus`, M8 screenshot `02-models`, and device test D22.
- **R-07: Stateless Context Framing.** Requests operate statelessly, transmitting only the selected image inputs alongside the latest user instruction as a single prompt turn (Design §2.1–§2.4). Addressed in milestones M1 and M4. Verified by `RequestBodyWriterTests` and single-contents assertions in `PipeParityTests`.
- **R-08: Multi-Image Attachment Ingestion.** Supports selecting and transmitting multiple image attachments per prompt turn within total request byte budgets (Design §2.2, §3.5). Addressed in milestones M1 and M6. Verified via `InputSelectorTests`, `ComposerAttachmentsTests`, `GenerationServiceTests.multipleAttachmentsInOrder`, screenshot `05-sent-grid`, and device test D9.
- **R-09: Turn-to-Turn Image Inheritance and Edit Chaining.** In the absence of an explicit pin or fresh attachments, the pipeline automatically inherits the latest generated or uploaded image as the transformation base; the composer displays a non-dismissible informational chip indicating this state (Design §2.2, §3.5, §4.3). Addressed in milestones M1, M2, M4, and M5. Verified via `InputSelectorTests`, `PipeParitySelectionTests`, M5 screenshot `09-success`, and device test D6.
- **R-10: Explicit Source Pinning via Edit From Here.** Users can pin any earlier image turn as the edit reference using the context menu action "Edit from here", setting a one-shot pin chip in the composer that clears upon dispatch (Design §2.2, §3.5, §3.6, §11 Q2). Addressed in milestones M5 and M7. Verified via `pinnedSendClearsPin`, screenshots `13a-unpinned` and `13-edit-from-here`, and device test D7.
- **R-11: Conversation Session Persistence.** Chat sessions persist across app launches with capabilities for reopening, inline renaming, and deletion with cascading asset cleanup (Design §3.3, §4.3, §4.4). Addressed in milestones M2 and M5. Verified through `DataStoreTests`, M5 screenshots `03`, `15`, `16`, and device test D25.
- **R-12: Configurable Aspect Ratio Selection.** Aspect ratios are configurable globally and on a per-chat basis, defaulting to 16:9 and persisting within message metadata (Design §2.4, §2.5, §3.5, §3.8). Addressed in milestones M0, M1, M2, M5, and M8. Verified via `SettingsResolverTests`, golden fixture `flash_text_only_16x9_2k.json`, screenshots `05`, `03`, `04`, and device tests D3–D5.
- **R-13: Configurable Resolution Selection.** Output resolutions (512 px, 1K, 2K, 4K) are configurable globally and per chat, defaulting to 2K (Design §2.4, §2.5, §3.5, §3.8). Addressed in milestones M0, M1, M2, M5, and M8. Verified via resolution unit tests, golden fixture `flash_512_9x16.json`, screenshots `06`, `03`, `04`, and device tests D3–D5.
- **R-14: Immutable Settings Reproduction on Regeneration.** Regenerating a response reproduces the exact generation parameters and input images recorded on the original turn (Design §4.3, §6). Addressed in milestones M2, M4, and M5. Verified via `regenerateUsesRecordedSettings`, screenshot `17-regenerate-recorded`, and device test D8.
- **R-15: Content Safety Threshold Configuration.** Content filtering thresholds are configured globally across four severity levels, defaulting to `BLOCK_NONE` (Design §2.4, §3.8). Addressed in milestones M1, M2, and M8. Verified via golden fixture `flash_threshold_low.json`, `AppSettingsTests`, and screenshot `03-generation-defaults`.
- **R-16: Lossless Photo Library Export.** Generated assets export to the iOS Photos library preserving original returned file bytes, MIME types, and dimensions (Design §4.9). Addressed in milestone M7. Verified via `PhotoLibrarySaverTests`, screenshot `03-photos-app`, and device test D17.
- **R-17: Lossless Files System Export.** Generated images export to the iOS Files document system byte-for-byte identical to stored artifacts (Design §4.9). Addressed in milestone M7. Verified via `ExportTests.imageFileExportsByteIdentical`, simulator byte comparisons, and device test D18.
- **R-18: System Share Sheet and Pasteboard Integration.** Images integrate with standard iOS Share sheets and system copy pasteboard without recompression (Design §4.9). Addressed in milestone M7. Verified via `ExportTests.pasteboard*`, screenshot `05-share-sheet`, and device test D19.
- **R-19: Flexible Ingestion Sources.** Ingestion supports PhotosPicker, system document file importers, and direct system clipboard pasting (Design §3.5, §4.8). Addressed in milestone M6. Verified via `FileImportTests`, `PasteSupportTests`, screenshots `02`, `06`, `07`, and device tests D9–D11.
- **R-20: Deliberate Scope Exclusions.** Feature set deliberately omits in-app camera capture, system share sheet extensions, and drag-and-drop interactions in v1 (Design §1.3). Verified by code and entitlements review confirming complete absence of excluded frameworks.
- **R-21: Client-Side Upload Preprocessing and Downscaling.** Input images are automatically preprocessed, downscaling to a user-configured maximum long edge (1536–4096 px, defaulting to 2048 px), converting HEIC to JPEG while retaining original files on disk, and enforcing total payload budget limits (Design §3.8, §4.3, §4.8). Addressed in milestones M3, M4, M6, and M8. Verified via `ImagePreprocessorTests`, `BudgetPlannerTests`, screenshots `05`, `05b-max-edge-4096`, and device tests D9 and D9b.
- **R-22: Resilient Background Execution.** Requests transition to background sessions with task assertions, allowing network transfer and processing to complete while the app is suspended or locked (Design §4.6, §4.7). Addressed in milestones M4 and M10. Verified via `TransportTests`, `ReconcilerTests`, `BackgroundConfigTests`, and device tests D12, D12b, D13, D13b, D15, and D16.
- **R-23: Local Background Completion Notifications.** The system posts local push notifications upon request completion whenever the application is inactive or in the background (Design §4.11). Addressed in milestones M4, M5, and M10. Verified via `notificationPostedWhenInactive` tests and device tests D12–D14.
- **R-24: Structured Markdown Parsing.** Returned text parts render natively as formatted Markdown blocks (Design §2.7, §4.12). Addressed in milestones M1, M3, and M5. Verified via `ResponseParserTests`, `MarkdownBlocksTests`, screenshot `18-markdown`, and device test D21.
- **R-24a: Corrupt Part Fault Tolerance.** Undecodable image parts are safely discarded with user notification, retaining the previous valid image as the editing anchor (Design §2.6, §2.7, §11 Q3). Addressed in milestones M1 and M4. Verified via `ResponseParserTests` (`resp_bad_image.json`) and `GenerationServiceTests.undecodableImageKeepsPreviousEditBase`.
- **R-24b: Dual-Modality Response Configuration.** Response modalities request both text and image (`["TEXT","IMAGE"]`) by default, with an Advanced settings toggle and smoke test verification determining fallback to image-only (`["IMAGE"]`) if resolution caps occur (Design §2.4, §3.8, §11 R3). Addressed in milestones M1, M2, M8, M9, and M10. Verified via golden fixtures, `AppSettingsTests`, M9 task 8, and device test D3.
- **R-24c: Safety and Policy Refusal Handling.** Safety, policy, and account limitation refusals present clean diagnostic status cards without echoing unfiltered response messages, exposing Retry, Edit, and New Chat actions where permissible, flagging chat rows with red status indicators, and never retrying automatically (Design §2.6, §2.7, §3.3, §3.4, §3.6, §4.6, §4.11, §6, §11 Q4). Addressed in milestones M1, M4, M5, and M6. Verified via comprehensive response parsing suites, `RetryPolicyTests`, `ReplyPresentationTests`, screenshots `10-refused-and-error` and `19-live-refused`.
- **R-25: Advanced Feature Exclusions.** Omits thinking configurations, tool grounding, and token usage readouts in v1 (Design §1.3, §2.4). Addressed in milestone M1. Verified by golden fixtures omitting `thinkingConfig` and parser tests dropping thought parts.
- **R-26: Message Bubble Action Capabilities.** Each message bubble exposes contextual actions for Regenerate, Edit and Resend, Delete, and Copy Prompt (Design §3.6). Addressed in milestones M5 and M6. Verified via `ChatScreenModelTests`, `EditAndResendTests`, screenshot `08-edit-resend`, and device test D24.
- **R-27: Contextual Image Operations.** Image cards expose actions to Save to Photos, Save to Files, Share, Copy, and Edit from here (Design §3.6). Addressed in milestones M5 and M7. Verified via screenshot `01-image-menu` and device tests D7, D17, D18, and D19.
- **R-28: Interactive Full-Screen Image Viewer.** Provides a dedicated modal image viewer supporting pinch-to-zoom, pan gestures, double-tap zoom targets, rotation, and multi-image swipe pagination (Design §3.7). Addressed in milestone M7. Verified via `ZoomMathTests`, screenshots `06`–`09`, and device test D20.
- **R-29: Deterministic Build and Test Automation.** Utilizes XcodeGen for reproducible project generation, Swift Testing with custom `URLProtocol` mocking for network independence, structured simulator verification across all milestones, and physical device test validation (Design §9, §10). Addressed across all milestones. Verified via milestone review checklists and test suite logs.
- **R-30: Documentation Architecture.** Design specifications and detailed implementation planning are maintained as foundational documents in the repository alongside reference pipelines (Design §1.4). Verified by file presence and maintenance in the project root.
- **R-31: Deterministic Activity Log Traceability.** Maintains an append-only local activity log recording natural-language descriptions of every action before invocation with complete operative parameters, followed by exact results upon completion; guarantees paired begin and result records across terminations while strictly excluding API credentials, secret headers, and image payloads (Design §1.2, §4.7, §4.13, §5, §7, §11 R14). Addressed across milestones M0, M1, M2, M4–M9, and M10. Verified via `ActivityLogTypesTests`, `ActivityLogRedactionTests`, `GenerationServiceTests`, sanitization lint passes, and device tests D28–D30.
- **R-32: Integrated Developer Diagnostic Interface.** A dedicated developer menu accessible from chat list and conversation toolbars presents immediate inspection of Last Action, Last Error, Full Log, and log clearing, backed by a monospaced, selectable, exportable log viewer (Design §3.3, §3.4, §3.10, §11 Q5). Addressed in milestones M5, M9, and M10. Verified via `LogViewerModelTests`, `DeveloperMenuModelTests`, screenshots `20`–`24`, regression suites, and device tests D28–D30.

---

## 6. Definition of done (v1)
- [ ] M0–M10 checklists complete.
- [ ] `scripts/test.sh`, `scripts/lint.sh` and `scripts/check-warnings.sh` pass on `main`.
- [ ] Device results D1–D25 (with D9b, D12b, D13b) and D28–D30 PASS. The R3 outcome is reported, and the `includeTextModality` default follows it (D§11 R3).
- [ ] DESIGN.md and this plan reflect the build that shipped (change log updated).

## 7. Milestone Verification Guidelines
- **Milestone Implementation:** Ensure all deliverables specified in the milestone scope adhere to the normative specifications in `doc/DESIGN.md`. Validate changes with `scripts/gen.sh && scripts/test.sh && scripts/lint.sh && scripts/check-warnings.sh`, followed by scenario-specific simulator verification, archiving generated artifacts under `artifacts/M<n>/`.
- **Milestone Verification Review:** Evaluate each milestone against its explicit acceptance criteria and corresponding architectural specifications. Re-execute test and static analysis suites, confirm zero-warning compilation, and inspect captured output artifacts.
