# ImageGen for iPhone: Implementation Plan

Status: v1 plan, ready for execution by Claude Code agents
Date: 2026-10-15
Companion: `doc/DESIGN.md` (the normative spec). Section references such as "D§2.4" point to DESIGN.md.
Reference behavior: `doc/openwebui_gemini_filter.py` (the "pipe"). This plan, DESIGN.md and the pipe all live in `doc/`.

This plan says **what to build, in what order, how to verify it, and when a milestone is done**. When this plan and DESIGN.md disagree, DESIGN.md wins; fix whichever is wrong and note it in the change log at the end of this file.

---

## 0. How to use this plan (for executing agents)

1. Work milestone by milestone, in dependency order (section 3). Tracks marked parallel can be run by separate agents in separate git worktrees.
2. Each milestone has: **Goal**, **Files and types**, **Implementation notes**, **Tests**, **Simulator verification** (if any) and **Done when**. A milestone is done only when every "Done when" box can be shown true by running the listed commands or by reviewing the listed screenshots.
3. Before starting any milestone, run `scripts/doctor.sh`. It must exit 0.
4. Never put the Gemini API key in a file in the repo, in a command line that is logged, in a URL or in a screenshot. Mock mode (section 2.6) needs no key. The only live test reads the key from the environment (section 2.5).
5. Keep DESIGN.md as the source of truth. If a design decision has to change during implementation, update the DESIGN section and add a line to the change log (section 8).
6. Commit at the end of each milestone (if the orchestrator allows commits) with the message `M<n>: <title>`. Never commit `Config/Local.xcconfig`, `build/`, `artifacts/` or `ImageGen.xcodeproj`.

### 0.1 Cross-cutting requirement: aspect ratio and resolution
Aspect ratio and output resolution are **configurable**, with defaults of **16:9** and **2K**. This shows up in several milestones, so it is spelled out once here:

| Layer | Where | Milestone | Proof |
|---|---|---|---|
| Vocabulary | `AspectRatio` (14 cases), `ImageSize` (`512`, `1K`, `2K`, `4K`) with exact API strings | M0 | compiles; `VocabularyTests` |
| Defaults | `AppSettings.defaultAspectRatio = .r16x9`, `defaultImageSize = .s2K` | M2 | `AppSettingsTests.defaultsAre16x9And2K` |
| Resolution order + coercion | `GenerationSettingsResolver` (D§2.5) | M1 | `SettingsResolverTests` |
| Wire format | `generationConfig.imageConfig = {"aspectRatio":"16:9","imageSize":"2K"}` always sent | M1 | golden `flash_text_only_16x9_2k.json`; `PipeParityTests` |
| Recorded per request | `GenerationRequest.aspectRatio` / `.imageSize` are the values sent | M2, M4 | `DataStoreTests`, `GenerationServiceTests.recordsSentValues` |
| Regenerate reproduces | Regenerate reuses the recorded values, not the current settings | M4, M5 | `GenerationServiceTests.regenerateUsesRecordedSettings` |
| Per-chat override | Composer pills: Model, Aspect, Resolution; each menu's first item is "Default (<current global default>)" | M5 | screenshots `M5/05-aspect-menu.png`, `M5/06-resolution-menu.png`; `ChatScreenModelTests.defaultItemLabelFollowsGlobalDefault` |
| Global defaults UI | Settings › Generation defaults | M8 | screenshot `M8/03-generation-defaults.png`; `M8/04-defaults-changed.png` (menus read "Default (1:1)" / "Default (1K)") |
| Honored by the API | metadata line shows actual pixels; ⚠︎ when the class or ratio is off | M5, M10 | mock scenario `lowRes`; device test D3 |

---

## 1. Toolchain and repository

### 1.1 Toolchain prerequisites (checked by `scripts/doctor.sh`)

What was found on this Mac on 2026-10-15:
- macOS 26.5.2.
- `xcode-select -p` points at `/Library/Developer/CommandLineTools`, so `xcodebuild` doesn't run.
- **Xcode 26.6** is at `~/Downloads/Xcode.app`. Its license hasn't been accepted yet.
- There are no iOS simulator runtimes, and XcodeGen isn't installed.

| Requirement | Minimum | Check | How to install | Needs the user? |
|---|---|---|---|---|
| Xcode | 26.0 (26.6 is present) | `xcodebuild -version` → `Xcode 26.x` or later | Move `~/Downloads/Xcode.app` to `/Applications/Xcode.app` (optional but recommended) | yes (drag in Finder, or `mv`) |
| Active developer dir | that Xcode | `xcode-select -p` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, **or** export `DEVELOPER_DIR` (scripts do this automatically, see `scripts/env.sh`) | `sudo` needs the user |
| License + first launch | accepted | `xcodebuild -checkFirstLaunchStatus` exits 0 | `sudo xcodebuild -license accept` then `xcodebuild -runFirstLaunch` | yes (`sudo`) |
| iOS simulator runtime | iOS 26.0+ | `xcrun simctl list runtimes` shows `iOS 26.x` | `xcodebuild -downloadPlatform iOS` (several GB) | no, but slow |
| XcodeGen | 2.46.0 | `xcodegen --version` | `brew install xcodegen` | no |
| Python 3 | any 3.9+ | `python3 --version` | already present (miniconda) | no; only for `scripts/gen_pipe_fixtures.py` |
| Apple developer account in Xcode | the user's paid Apple Developer Program team | Xcode › Settings › Accounts shows the team | sign in in Xcode | yes (M10 only) |

Agents can't run `sudo` or sign in to an Apple account. M0 lists the exact commands for the user and waits until `scripts/doctor.sh` passes.

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
    check-warnings.sh                 clean build into its own log; fails on any warning in ImageGen/ sources
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
    TARGETED_DEVICE_FAMILY: "1"
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

### 1.4 Standard commands

All scripts `source scripts/env.sh`, which:
- picks `DEVELOPER_DIR`: `$IMAGEGEN_XCODE`, then `/Applications/Xcode.app`, then `~/Downloads/Xcode.app`, keeping the first whose version is 26 or later;
- sets `SIM_NAME=ImageGen-Sim` (or `$IMAGEGEN_SIM`, a simulator name or UDID, to use an already-booted simulator instead), `BUNDLE_ID=com.andrewpurtell.imagegen`, `DERIVED=build/DerivedData`, `LOGS=build/logs`.

| Purpose | Command | Underlying invocation |
|---|---|---|
| Doctor | `scripts/doctor.sh` | version checks of section 1.1 |
| Simulator | `scripts/sim.sh ensure` | `xcrun simctl create ImageGen-Sim "iPhone 17 Pro" <newest iOS ≥ 26 runtime>` if missing (falls back to the newest iPhone Pro device type the runtime supports), then `simctl boot` and `open -a Simulator` |
| Generate | `scripts/gen.sh` | `xcodegen generate --spec project.yml` |
| Build (sim) | `scripts/build.sh` | `xcodebuild -project ImageGen.xcodeproj -scheme ImageGen -configuration Debug -destination "id=$SIM_UDID" -derivedDataPath build/DerivedData build \| tee build/logs/build.log` |
| Build (sim, Release) | `scripts/build.sh --release` | the same with `-configuration Release`, logging to `build/logs/build-release.log`. This catches DEBUG-only references long before M10 |
| Test (all) | `scripts/test.sh` | `xcodebuild ... -destination "id=$SIM_UDID" -resultBundlePath build/logs/Test-<timestamp>.xcresult test \| tee build/logs/test.log` |
| Test (one suite) | `scripts/test.sh -only-testing:ImageGenTests/ResponseParserTests` | the same, with arguments passed through |
| Warnings | `scripts/check-warnings.sh` | runs its own **clean** build (`xcodebuild ... -derivedDataPath build/DerivedData-warnings clean build`, so every file is recompiled and re-emits its warnings) into `build/logs/warnings.log`, then `grep -E '/ImageGen/.*: warning:' build/logs/warnings.log` must be empty. It never reads the incremental `build.log` |
| Lint | `scripts/lint.sh` | section 2.7 |
| Run (sim) | `scripts/run-sim.sh -UITestMockGemini 1 -SeedDemoData 1 -Scene chatList` | `simctl terminate`; `simctl install $UDID build/DerivedData/Build/Products/Debug-iphonesimulator/ImageGen.app`; `simctl launch $UDID $BUNDLE_ID <args>` |
| Screenshot | `scripts/shot.sh M5 01-chat-list` | `xcrun simctl io $UDID screenshot artifacts/M5/01-chat-list.png` (status bar overridden to 9:41, full battery) |
| Appearance | `xcrun simctl ui $UDID appearance dark` / `light` | |
| Dynamic Type | `xcrun simctl ui $UDID content_size accessibility-extra-extra-extra-large` / `large` | |
| Photos permission | `xcrun simctl privacy $UDID grant photos-add $BUNDLE_ID` | for unattended Save to Photos checks |
| Add test photos | `xcrun simctl addmedia $UDID ImageGenTests/Fixtures/Images/sample.heic` | for PhotosPicker checks |
| Device | `scripts/device-install.sh [--release]` | section 9 |

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
Location: `ImageGenTests/Fixtures/Requests/`. Each golden file holds the full request body with base64 data replaced by the token `"<b64:FILENAME>"`. The test expands the token from `Fixtures/Images/` or `ImageFactory` output, then compares with `JSONSerialization`, structurally (key order doesn't matter, array order does).

| Fixture | Inputs | Asserts |
|---|---|---|
| `flash_text_only_16x9_2k.json` | defaults, but with `includeTextModality = true` set explicitly (pipe parity, so the R3 flip in M9 task 8 doesn't change this golden), prompt "a lighthouse at dusk" | one text part; `imageConfig` 16:9/2K; 5 safety categories at BLOCK_NONE; `["TEXT","IMAGE"]` |
| `flash_three_images.json` | 3 inputs (jpeg, png, jpeg), prompt | 3 `inlineData` parts in order, then text |
| `flash_image_only.json` | 1 attachment, empty prompt | no text part |
| `flash_512_9x16.json` | override 9:16 / 512 | `"imageSize":"512"` exactly |
| `pro_16x9_1k.json` | a hand-built `EffectiveSettings` for 3 Pro at 16:9 / 1K (what the resolver produces for an override of 1:8 / 512; that coercion is proven in `SettingsResolverTests` and, end to end, in the M1 integration step) | the URL path uses `gemini-3-pro-image`; `imageConfig` 16:9 / 1K |
| `flash25_no_image_size.json` | 2.5 Flash Image at 16:9 (capability with no `imageSize`) | `imageConfig` has `aspectRatio` and no `imageSize` key |
| `flash_no_civic.json` | `omitCivicIntegrity = true` | 4 categories |
| `flash_image_modality_only.json` | "Request text alongside images" off | `["IMAGE"]` |
| `flash_threshold_only_high.json`, `flash_threshold_medium.json`, `flash_threshold_low.json` | one parameterized test over BLOCK_ONLY_HIGH, BLOCK_MEDIUM_AND_ABOVE and BLOCK_LOW_AND_ABOVE (BLOCK_NONE is covered by `flash_text_only_16x9_2k.json`) | every category at that exact threshold string |
| `flash_escaping.json` | prompt with `"`, `\`, newlines, tab, emoji, and U+2028 | round-trips exactly |
| `custom_model_4k.json` | custom ID `gemini-x-test`, 21:9 / 4K | the URL path uses the custom ID; the values are passed through |

**Pipe parity fixtures** (`Fixtures/PipeReference/`). These are generated once by `scripts/gen_pipe_fixtures.py` and checked in. The script:
- imports `doc/openwebui_gemini_filter.py` with stub `pydantic` and `requests` modules injected into `sys.modules` (so it needs no third-party packages);
- calls `Pipe().pipe(body)` with OpenAI-style `messages` built from `Fixtures/Images/tiny_16x9.png`, `tiny_square.jpg` and text;
- captures `json=payload`, `url` and `headers` from the stubbed `requests.post`, and writes `<case>.payload.json` plus `<case>.url.txt` with the key replaced by `<KEY>`.

Run it as `python3 -I scripts/gen_pipe_fixtures.py --pipe doc/openwebui_gemini_filter.py --out ImageGenTests/Fixtures/PipeReference`.

| Case | Pipe input | App-side equivalent (built by hand in Track 1B) | Selection check (M1 integration step) |
|---|---|---|---|
| `p1_text_only` | one user message, text | prompt, no images | `.noImage` |
| `p2_upload_and_text` | user message with one image_url + text | one input whose prepared file **is the same PNG bytes** (the writer is tested directly, without the preprocessor) | `.attachments` |
| `p3_edit_latest` | user, then an assistant reply with a Markdown data-URI image, then user text | one input: that model image's original bytes | `.latest` picks the model image |
| `p4_image_only` | user message with an image and no text | one input, empty prompt | `.attachments` |
| `p5_threshold_only_high` | valve `SAFETY_THRESHOLD=BLOCK_ONLY_HIGH` | threshold `.blockOnlyHigh` | `.noImage` |
| `p6_latest_is_user_upload` | a user upload, an assistant text-only reply, then user text | one input: the user's upload | `.latest` picks the upload |
| `p7_latest_of_two_outputs` | user, then an assistant reply with **two** Markdown data-URI images (`tiny_16x9.png`, then `tiny_square.jpg`), then user text | one input: the **second** image (the pipe's `images[-1]`) | `.latest` picks ordinal 1 of the model message |
| `p8_latest_of_two_uploads` | a user message with **two** uploads, an assistant text-only reply, then user text | one input: the **last** upload | `.latest` picks ordinal 1 of the user message |

`PipeParityTests` (Track 1B) asserts: `appBody` with `generationConfig.imageConfig` removed **deep-equals** `pipeBody`, and the app URL equals the pipe URL with `?key=<KEY>` removed. Every other difference fails the test. That is the proof of D§1.2 goal 1, with only the D§2.6 deviations allowed. Track 1B builds each app-side input list by hand, so it doesn't depend on Track 1A. `PipeParitySelectionTests` (M1 integration step, after all tracks merge) builds the equivalent `SelectionInput` history for each case, with ordinals assigned as D§4.3 says, runs `InputSelector.select`, and asserts that the selected image is the one the pipe sent.

### 2.4 Response fixtures (parsing)
Location: `ImageGenTests/Fixtures/Responses/` and `Errors/`. The images inside them are small real PNG/JPEG files (16×9 or 8×8 px) so they decode for real.

| Fixture | Expected `ParsedOutcome` |
|---|---|
| `resp_text_image.json` | `.success([.text, .image(png)])`, finish STOP |
| `resp_image_text.json` | `.success([.image, .text])` (order kept) |
| `resp_two_images.json` | `.success([.image, .image])` |
| `resp_adjacent_text.json` | two text parts concatenated verbatim with no separator into one `.text`; only the run's two ends trimmed |
| `resp_split_sentence.json` | parts `"The lighthouse stands "` + `"on a rocky point."` + an image + `"- item 1\n"` + `"- item 2"` → `.success([.text("The lighthouse stands on a rocky point."), .image, .text("- item 1\n- item 2")])`: text inside each run unchanged, no inserted breaks |
| `resp_whitespace_run.json` | text `"  "`, then an image → the whitespace-only run dropped: `.success([.image])` |
| `resp_thought_parts.json` | `thought:true` text and image dropped; the final image kept |
| `resp_no_mime.json` | image with MIME type defaulted to `image/jpeg` |
| `resp_bad_image.json` | image part dropped; notice "1 image could not be decoded"; the text kept |
| `resp_text_only.json` | `.success([.text])` with no image part, finish `STOP` (the UI derives the "No image returned" badge from that, D§2.7 rule 8) |
| `resp_finish_no_image.json` | text + finish `NO_IMAGE` → `.refused(NO_IMAGE)`; the text is only in `details`, not in any part (D§2.7 rule 6) |
| `resp_prompt_refused.json` | `promptFeedback.blockReason = PROHIBITED_CONTENT` → `.refused(PROHIBITED_CONTENT)` |
| `resp_image_safety.json` | candidate with no parts, `IMAGE_SAFETY`, `finishMessage` → `.refused(IMAGE_SAFETY, message)` (the message is stored as `errorMessage`) |
| `resp_image_other.json` | candidate with no parts, finish `IMAGE_OTHER` → `.refused(IMAGE_OTHER)` |
| `resp_no_image_no_parts.json` | candidate with no parts, finish `NO_IMAGE` → `.refused(NO_IMAGE)` |
| `resp_refused_with_text.json` | finish `IMAGE_SAFETY` with a text part and no image → `.refused(IMAGE_SAFETY)`; the text is kept only in `details` |
| `resp_unknown_finish_reason.json` | no parts, finish `IMAGE_SOMETHING_NEW` (not a known value) → `.refused("IMAGE_SOMETHING_NEW")`, verbatim |
| `resp_escalation.json` | no parts, finish `ESCALATION` → `.refused(ESCALATION)` |
| `resp_pup_limited.json` | no parts, finish `PUP_LIMITED_DISABLED` → `.refused(PUP_LIMITED_DISABLED)` (card without Retry) |
| `resp_empty_candidates.json` | `.empty(nil)` |
| `resp_no_parts_other.json` | no parts, finish `OTHER` → `.refused(OTHER)` |
| `resp_no_parts_stop.json` | no parts, finish `STOP` → `.empty(STOP)` |
| `resp_no_parts_max_tokens.json` | no parts, finish `MAX_TOKENS` → `.empty(MAX_TOKENS)` (not a refusal) |
| `resp_no_parts_unspecified.json` | no parts, finish `FINISH_REASON_UNSPECIFIED` → `.empty(FINISH_REASON_UNSPECIFIED)` (not a refusal) |
| `resp_no_parts_no_finish.json` | no parts, no `finishReason` → `.empty(nil)` (not a refusal) |
| `resp_text_only_max_tokens.json` | text part, finish `MAX_TOKENS` → `.success([.text])`, footnote "Finished: MAX_TOKENS", badge derived (D§2.7 rule 8) |
| `resp_text_only_unspecified.json` | text part, finish `FINISH_REASON_UNSPECIFIED` → `.success([.text])` with the badge |
| `resp_text_only_no_finish.json` | text part, no `finishReason` → `.success([.text])` with the badge |
| `resp_image_with_safety_finish.json` | a decodable image (and a text part) with finish `IMAGE_SAFETY` → `.success([.text, .image])`, footnote "Finished: IMAGE_SAFETY": a surviving image is never a refusal (D§2.7 rule 6) |
| `resp_bad_image_refused.json` | only an undecodable image part, finish `IMAGE_SAFETY` → `.refused(IMAGE_SAFETY)`, with the "1 image could not be decoded" notice kept |
| `resp_malformed.txt` | truncated JSON → `.malformed` |
| `resp_html.html` | captive-portal HTML with status 200 → `.malformed` |
| `resp_unexpected_shape.json` | valid JSON `{"foo":1}` → `.empty(nil)` (decodes with every field optional; no candidates) |
| `Errors/err_400_invalid_argument.json` | `.apiError(400, INVALID_ARGUMENT, msg)` |
| `Errors/err_400_civic.json` | `.apiError(400, INVALID_ARGUMENT)` whose message mentions `HARM_CATEGORY_CIVIC_INTEGRITY` |
| `Errors/err_400_api_key_invalid.json` | `.apiError(400, INVALID_ARGUMENT)` with reason `API_KEY_INVALID` in `details` |
| `Errors/err_402.json` | `.apiError(402, ...)` |
| `Errors/err_403.json` | `.apiError(403, PERMISSION_DENIED)` |
| `Errors/err_404.json` | `.apiError(404, NOT_FOUND)` |
| `Errors/err_429_retryinfo.json` | `.apiError(429, RESOURCE_EXHAUSTED)`; `RetryPolicy` reads `retryDelay "30s"` |
| `Errors/err_500_text.txt` | non-JSON body → message is the first 2 KB of the text |
| `Errors/err_503.json` | `.apiError(503, UNAVAILABLE)` |
| `Models/models_page1.json`, `models_page2.json` | paging via `nextPageToken`; Flash present on page 2 |
| `Models/models_no_flash.json` | triggers the "doesn't list Gemini 3.1 Flash Image" warning |
| `Models/model_get_custom.json` | single-model GET for custom-ID validation |

### 2.5 Live smoke test (opt-in)
- `LiveSmokeTests` is tagged `.live` and enabled only when `GEMINI_API_KEY` is in the test process environment.
- Run it with `TEST_RUNNER_GEMINI_API_KEY="$GEMINI_API_KEY" scripts/live-smoke.sh`. xcodebuild forwards `TEST_RUNNER_`-prefixed variables to the test runner without the prefix. The script runs `-only-testing:ImageGenTests/LiveSmokeTests` and never echoes the key.
- It runs through the real `URLSessionTransport` using an ephemeral configuration, plus the real parser:
  1. a text-to-image request with Flash at 1:1/512 (cheap);
  2. an edit of that output, sent as original bytes, at 16:9/2K;
  3. it asserts both are `.success` with an image, and logs the actual pixel sizes for R3/R4 under the OSLog category `smoke`. The 2K edit's size class is the R3 measurement that M9 task 8 acts on.
- The user runs it, or an agent runs it only if the user supplies the key in the environment. It is never part of the default `scripts/test.sh`, because it is filtered out by the enable condition.

### 2.6 DEBUG harness (`ImageGen/DebugSupport/`, all `#if DEBUG`)
This makes simulator verification deterministic without a key or network.

| Option (launch argument or persisted default) | Effect |
|---|---|
| `-UITestMockGemini 1` | `AppEnvironment` builds `URLSessionTransport` and `ModelsClient` on an **ephemeral** configuration with `MockGeminiURLProtocol` (retry delays then come from the transport's deferred resume, D§4.6), and uses an `InMemoryKeyStore` holding `"mock-key"` as its `APIKeyStore` (the Keychain isn't touched, not even by onboarding Save or Remove Key; onboarding is skipped) |
| `-MockScenario <name>` | `success` (default, finish `STOP`), `textOnly` (one text part, finish `STOP`), `twoImages` (finish `STOP`), `promptRefused` (`promptFeedback.blockReason = PROHIBITED_CONTENT`), `imageSafety` (no parts, finish `IMAGE_SAFETY`, `finishMessage` "Mock: image blocked by safety filter"), `imageSafetyThenSuccess` (the first request as `imageSafety`, every later one as `success`), `imageOther` (no parts, finish `IMAGE_OTHER`), `empty` (no candidates), `malformed`, `rateLimitThenSuccess` (429 with RetryInfo 2s, then 200), `badRequest`, `notFound`, `keyRejected`, `civicRejectedOnce`, `lowRes` (returns 1K pixels for any request), `wrongAspect` (returns 1:1) |
| `-MockLatency <seconds>` | response delay (default 2; use 15 to capture pending cards) |
| `-SeedDemoData 1` | on launch, if the store is empty, `DemoSeeder` creates the chats below |
| `-ResetStore 1` | deletes the store, the files and the `Logs/` folder at the very start of `AppEnvironment.init`, through `DebugHooks.resetBeforeLaunchIfRequested(root:)`, **before** the `ActivityLog` is created (M4). It doesn't use Clear Log, so no Log cleared action is written; the run's log file starts with its own Launch Begin (D§4.13). Seeding (`-SeedDemoData`) runs later, on the empty store. To keep a log across runs (M9 task 10), relaunch without this option |
| `-Scene <name>` | after launch, navigate to `chatList`, `chat:<seedKey>`, `settings`, `settings:models`, `viewer:<seedKey>`, `onboarding` (forces onboarding even with a key) |
| `-SeedPasteboardImage 1` | writes a generated JPEG to `UIPasteboard.general` at launch (writing never prompts), so `PasteButton` appears |
| `-ForceNotificationState denied` | shows the denied state in Settings without changing the system |
| `-SkipNotificationPrompt 1` | defers the first-send notification permission request, so unattended runs aren't blocked by the system alert |
| `-SeedLargeChat 1` | adds a chat with 60 messages and 40 images, for scrolling and performance checks (M9) |

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
no-key-in-urls                         '\?key=|&key='                                           ImageGen/
no-full-decode                         'UIImage\(data:|UIImage\(contentsOfFile:'                ImageGen/ except DebugSupport/
no-reencoding-exports                  'UIImageWriteToSavedPhotosAlbum|jpegData\(|pngData\('    ImageGen/Export/ ImageGen/Features/
no-swiftui-in-pure-layers              '^import SwiftUI'                                        ImageGen/{Gemini,Imaging,Pipeline,Security,Networking}/
no-print                               '\bprint\('                                              ImageGen/ except DebugSupport/
no-async-urlsession-for-generation     '\.data\(for:|\.upload\(for:'                            ImageGen/Networking/ ImageGen/Pipeline/
debug-names-only-via-hooks             '\bLaunchOptions\b|MockGeminiURLProtocol|DemoSeeder|SceneRoute'   ImageGen/ except DebugSupport/ and App/DebugHooks.swift
no-key-in-activity-log                 (multiline, perl; see below)                             ImageGen/
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

| Milestone | Depends on | Can run in parallel with | Owner folders (to avoid merge conflicts) |
|---|---|---|---|
| M0 | none | none (gate) | everything (scaffold), including `Pipeline/SharedTypes.swift`, `Support/ActivityLogTypes.swift`, `Support/Logging.swift`, `App/DebugHooks.swift` (stubs; M4 and M5 fill in its DEBUG branch) and the shared test support files |
| M1 | M0 | M2, M3 | `Gemini/`, `Pipeline/{InputSelector,GenerationSettingsResolver,RetryPolicy}.swift`, its tests and fixtures |
| M2 | M0 | M1, M3 | `Persistence/`, `Security/`, `Settings/`, `Support/ActivityLog{,Store,Query,Formatter}.swift`, `ImageGenTests/Support/ActivityLogProbe.swift`, their tests |
| M3 | M0 | M1, M2 | `Imaging/`, `Support/MarkdownBlocks*.swift`, their tests |
| M4 | M1, M2, M3 | none | `Networking/`, `Pipeline/` (the rest), `App/`, `DebugSupport/MockGemini*` |
| M5 | M4 | none (M5 can begin views against `-SeedDemoData` once M2 lands, but it merges after M4) | `Features/ChatList`, `Features/Chat`, `Features/Onboarding`, `Features/Developer`, `DebugSupport/DemoSeeder`, `DebugSupport/LaunchOptions` |
| M6 | M5 | M7, M8 | `Features/Chat/Composer/*Attachment*`, `AttachmentTray.swift`, `PasteSupport.swift`, `Features/Chat/ChatScreenModel+Attachments.swift`, the Edit and Resend item in `MessageActionsMenu.swift` |
| M7 | M5 | M6, M8 | `Export/`, `Features/Viewer/`, the item bodies in `Features/Chat/ImageContextMenu.swift` |
| M8 | M5 | M6, M7 | `Features/Settings/`, `Pipeline/ModelAvailabilityService.swift` UI bindings |
| M9 | M6, M7, M8 | none | fixes anywhere; no new features |
| M10 | M9 | none | none (device) |

**Activity log.** Its vocabulary is in M0, and its storage, facade, queries and formatter are in M2. The first code that logs is M2's Janitor. M1 and M3 are pure and don't log (section 2.8 rule 7). From M4 on, every milestone instruments its own actions under the section 2.8 contract. M5 adds the Developer menu and the log viewer. No new dependency edges are needed: everything that logs depends on M2 already.

**Parallel tracks within M1:** 1A (catalog consumers: `GenerationSettingsResolver` and `InputSelector`), 1B (`RequestBodyWriter`, `GeminiEndpoint`, the pipe fixtures), 1C (`ResponseModels`, `ResponseParser`, `Redactor`, `GeminiErrorBody`), 1D (`RetryPolicy`). They share only what M0 defines: the vocabulary and `Pipeline/SharedTypes.swift` (which includes `EffectiveSettings`, `Coercion` and the selector types). No track calls another track's code: 1B tests build `EffectiveSettings` and input lists by hand. Whatever needs two tracks together runs in the **M1 integration step** after all four have merged (see M1).

**Shared types rule.** Every `Sendable` DTO that crosses a milestone or layer boundary is defined in M0's `Pipeline/SharedTypes.swift`, with the full field lists given there. The one exception is the activity-log vocabulary, which is in M0's `Support/ActivityLogTypes.swift`, because every layer logs and `Support/` must not depend on `Pipeline/`. Later milestones add behavior (functions, extensions) but never redefine or move these types. If a milestone needs a new field, it adds it to `SharedTypes.swift` and notes it in the change log.

**Merge protocol for parallel agents.**
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
  - On `.finishedEvents(id)` it calls `onBackgroundEventsFinished(id, n)`, where `n` is the number of completions handled since the previous `.finishedEvents`, which calls `BackgroundEventsRelay.callAndClear` on the main actor. Because events are handled in order, every earlier completion has been parsed and saved by then.
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

**Simulator verification.** Run `scripts/build.sh`, then capture these with `scripts/run-sim.sh <args>` followed by `scripts/shot.sh M5 <name>`. Use the simulator tool for the taps. Every row lists its **complete** launch arguments; nothing carries over from an earlier row. `$BASE` stands for `-UITestMockGemini 1 -SkipNotificationPrompt 1`, so no row reaches onboarding by accident and the notification permission alert never covers a capture.

| Screenshot | Launch args / steps | Must show |
|---|---|---|
| `01-onboarding` | `$BASE -ResetStore 1 -Scene onboarding` | "Connect Gemini", a secure field, a "Validate and Save" prominent glass button |
| `02-chat-list-empty` | `$BASE -ResetStore 1` | "No chats yet" and a New Chat button |
| `03-chat-list-seeded` | `$BASE -ResetStore 1 -SeedDemoData 1` | 5 rows with titles, snippets and times; thumbnails on `lighthouse`, `uploads` and `refused`, the placeholder glyph on `textonly` and `empty-overrides`; a red dot on "refused" (its latest request failed with 429); the toolbar with the gear leading and the hammer then New Chat trailing |
| `04-chat-lighthouse` | `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse` | the hammer next to the chat menu in the navigation bar; user bubbles right, replies left, the metadata line `3.1 Flash · 16:9 · 2K · 2752×1536`, the "↻ Regenerated" header, the composer with pills `3.1 Flash`, `16:9`, `2K` and the pin chip (turn 1 is pinned by the seed) |
| `05-aspect-menu` | as 04, then tap the Aspect pill | "Default (16:9)" first; Landscape/Square/Portrait/Extreme sections |
| `06-resolution-menu` | as 04, then tap the Resolution pill | "Default (2K)" first; 512 px, 1K, 2K, 4K |
| `07-pro-menus` | `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:empty-overrides`, tap Aspect | no 1:4/4:1/1:8/8:1; accent dots on the overridden pills (9:16, 4K, 3 Pro) |
| `08-pending` | `$BASE -ResetStore 1 -MockLatency 15`, New Chat, type "a red fox", Send, capture within 5 s | an aspect-shaped shimmer card, "Generating… 0:0x", Cancel; Send has become Stop; no permission alert |
| `09-success` | continue from 08 and wait for completion | the reply image, metadata line, and the "Editing latest image" chip in the composer, with no ✕ |
| `10-refused-and-error` | `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:refused` | a "Request refused: IMAGE_SAFETY" card with no message line and exactly the buttons Retry, Edit, New Chat; an "Error 429 RESOURCE_EXHAUSTED" card with Retry, Details (both as in the D§3.4 table) |
| `11-retrying` | `$BASE -ResetStore 1 -MockScenario rateLimitThenSuccess -MockLatency 1`, New Chat, send "a red fox" | "Retrying in 2 s (attempt 2/3)" (the transport's deferred resume really waits 2 s), then success |
| `12-lowres-warning` | `$BASE -ResetStore 1 -MockScenario lowRes`, New Chat, send "a red fox" | ⚠︎ "returned 1K" on the metadata line |
| `13-edit-from-here` | `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse`; first tap ✕ on the pin chip and confirm the chip is gone (capture `13a-unpinned`); then long-press the **turn-2** reply image → Edit from here | `13a`: no pin chip; the informational "Editing latest image" chip shows instead. `13`: the context menu with preview, then the "Editing from pinned image" chip whose thumbnail is the turn-2 image |
| `14-dark` | `xcrun simctl ui $UDID appearance dark`, then the 04 arguments | legible dark rendering |
| `18-markdown` | `$BASE -ResetStore 1 -SeedDemoData 1 -Scene chat:textonly` | the reply rendered as Markdown: a heading, a bulleted list and a monospaced code block; the "No image returned" badge |
| `20-developer-menu` | `$BASE -ResetStore 1 -SeedDemoData 1`, tap the hammer on the chat list | Last Action, Last Error (disabled: the reset log holds no error), Full Log, and Clear Log… in red |
| `21-log-last-action` | `$BASE -ResetStore 1`, New Chat, send "a red fox", wait for the reply, then hammer (chat screen) › Last Action | the "Last Action" sheet in monospaced lines: `[Send xxxx] Begin: gemini-3.1-flash-image · 16:9 · 2K · safety BLOCK_NONE · modalities TEXT+IMAGE · input none · prompt "a red fox"`; the Prepare request, Attempt 1 and Parse sub-actions indented; `Result: success in … · HTTP 200 · 1 image 2752×1536 JPEG …`; Copy and Share in the toolbar |
| `22-log-last-error` | `$BASE -ResetStore 1 -MockScenario imageOther`, New Chat, send "a red fox", wait for the card, then hammer › Last Error | the Send with its sub-actions and `Result: refused · IMAGE_OTHER · HTTP 200 in …` |
| `23-log-full` | `$BASE -ResetStore 1 -MockScenario rateLimitThenSuccess -MockLatency 1`, New Chat, send "a red fox", wait for success, then hammer › Full Log | opened at the bottom, the Send's `Result: success` last; above it Attempt 1 ending `HTTP 429`, the step `auto-retry 1/2 in …: HTTP 429 RESOURCE_EXHAUSTED`, and Attempt 2 ending `HTTP 200`. Scroll to the top for `23a-log-full-top`: the Launch and Reconcile actions first |
| `24-clear-log` | continue from 23: hammer › Clear Log… (capture the dialog), tap Clear Log, then hammer › Full Log (capture `24b-log-after-clear`) | `24`: the "Clear the activity log?" dialog with a destructive Clear Log and Cancel. `24b`: only the `[Log cleared xxxx]` Begin (stating the size and entries removed) and its `Result: success` |

**Done when**
- [ ] All unit suites pass. No warnings; lint passes. `scripts/build.sh --release` succeeds.
- [ ] All 20 screenshots in the table (plus `13a-unpinned`, `23a-log-full-top` and `24b-log-after-clear`) exist in `artifacts/M5/`, and `REVIEW.txt` marks each PASS against the "Must show" column.
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

**Simulator verification.** Unless a row says otherwise, launch with `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse`.

| Screenshot | Steps | Must show |
|---|---|---|
| `01-plus-menu` | tap + | "Photo Library" and "Files" |
| `02-photos-picker` | first `simctl addmedia` with `sample.heic` and 2 generated JPEGs, then + › Photo Library | the system picker with ordered multi-select |
| `03-tray` | pick 3 | 3 tray thumbnails, caption "3 images · x.x MB of 19 MB"; the pin chip dimmed ("Pinned image replaced by attachments") in `lighthouse` |
| `04-tray-menu` | long-press a tray item | Move Left, Move Right, Remove |
| `05-sent-grid` | Send | the user bubble with a 2-column grid of 3; the reply follows |
| `06-paste` | the default arguments plus `-SeedPasteboardImage 1` | the PasteButton is visible; tapping it adds a tray item with no system paste prompt |
| `07-files-importer` | + › Files | the system document picker (tapping into it is optional) |
| `08-edit-resend` | long-press an earlier user message → Edit and Resend | the composer filled with that text and the cloned tray items |

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

**Simulator verification**
- Before starting: `xcrun simctl privacy $UDID grant photos-add com.andrewpurtell.imagegen`.
- Unless a row says otherwise, launch with `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1 -Scene chat:lighthouse`.

| Screenshot | Steps | Must show |
|---|---|---|
| `01-image-menu` | long-press a reply image | Edit from here, Save to Photos, Save to Files…, Share…, Copy, View |
| `02-saved-toast` | Save to Photos | the "Saved to Photos" toast |
| `03-photos-app` | open the Photos app in the simulator (`xcrun simctl launch $UDID com.apple.mobileslideshow`) | the saved image appears; Info shows JPEG at 2752×1536 |
| `04-files-exporter` | Save to Files… | the exporter with the filename `ImageGen-YYYY-MM-DD-HHMM-xxxxxx.jpg` |
| `05-share-sheet` | Share… | the share sheet with a preview |
| `06-viewer` | View | the full-screen image with the glass toolbar |
| `07-viewer-zoomed` | double-tap | zoomed in at the tap point |
| `08-viewer-landscape` | rotate (simulator tool or `Device › Rotate`) | fits in landscape |
| `09-viewer-paging` | `uploads` seed, View on image 1, swipe | page 2 of 3 |

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

**Simulator verification.** Unless a row says otherwise, launch with `-UITestMockGemini 1 -SkipNotificationPrompt 1 -ResetStore 1 -SeedDemoData 1` plus the row's arguments.

| Screenshot | Steps | Must show |
|---|---|---|
| `01-settings-top` | `-Scene settings` | the API Key "Saved (…-key)" (mock), Models, Generation defaults |
| `02-models` | `-Scene settings:models` | Flash fixed; every other catalog model's toggle on (3 Pro, 2.1, Flash Lite, 2.5 Flash, 3 Pro preview); Flash Lite, 2.5 Flash and 3 Pro preview labeled "Not listed for this key" (the mock list); "Last checked" |
| `03-generation-defaults` | scroll | Aspect ratio **16:9**, Resolution **2K**, Safety "Block none", and the footnote |
| `04-defaults-changed` | set 1:1 and 1K, then open a new chat and open the Aspect and Resolution menus | the pills show `1:1` and `1K` with no override dot; the menus' first items read "Default (1:1)" and "Default (1K)" |
| `05-uploads-advanced` | scroll | 2048 selected; both Advanced toggles ("Request text alongside images" on, unless M9 task 8 has flipped the default) |
| `05b-max-edge-4096` | select 4096; in a new chat attach **one** 8064×6048 image (made with `xcrun swift scripts/gen_image_fixtures.swift --large build/large_8064x6048.jpg` and added with `simctl addmedia`; a single image stays under 19 MB, so the budget shrink doesn't hide the setting), send, open the reply Info sheet | the input listed as `image/jpeg` with a 4096 px long edge; then set 2048 back |
| `06-storage` | scroll | the sizes and the destructive buttons |
| `07-notifications-denied` | `-ForceNotificationState denied` | the denied status with an Open Settings button |

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

**Later installs (agent-runnable once the device is paired)**
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
Record each result in `artifacts/M10/DEVICE_RESULTS.txt` (`D<n>: PASS|FAIL notes`). Where a screenshot is useful, the user takes it on the phone (side + volume up).

| # | Area | Steps | Expected |
|---|---|---|---|
| D1 | Install | Install as above, then launch | Onboarding "Connect Gemini" |
| D2 | Key | The user pastes their key and taps Validate and Save | Saved; chat list; Settings shows "Saved (…last4)". No Flash warning. |
| D3 | Defaults 16:9 / 2K | New chat, "a lighthouse at dusk, cinematic", Send | Reply in about 10–60 s; metadata `3.1 Flash · 16:9 · 2K · 2752×1536` (or within the 2K class); **no ⚠︎**. If ⚠︎ "returned 1K" appears while text is on (and M9 task 8 didn't already settle R3), turn off Advanced › "Request text alongside images", send the same prompt again (Regenerate would reuse the recorded modality), and record both sizes. If the cap is confirmed, apply the M9 task 8 flip and reinstall. |
| D4 | Per-chat override | Pills → 9:16 and 4K, then send "same scene, vertical" | Portrait output, metadata `9:16 · 4K`, about 3072×5504 |
| D5 | Global defaults | Settings: 1:1 / 1K. New chat; send | Pills show 1:1 / 1K; output about 1024×1024. Then **restore 16:9 / 2K**. |
| D6 | Edit latest | In the D3 chat, send "make it night" with no attachment | The caption "Edited latest image"; the output is the night version of the D3 image |
| D7 | Edit from here | Long-press the first image → Edit from here; send "add a boat" | The chip appears and then clears after the send; the boat is added to the **first** image |
| D8 | Regenerate reproduces | Change the pills to 1:1, then Regenerate the D3 reply | The new reply records `16:9 · 2K`, and the earlier reply is kept |
| D9 | Multi-attach + HEIC | + › Photo Library, pick 2 iPhone camera photos (HEIC, 48 MP if available) and 1 screenshot | The tray shows 3 items, size under 19 MB; the send succeeds; the Info sheet shows inputs as `image/jpeg` at 2048 px long edge |
| D9b | Max long edge setting | Settings › Uploads › 4096. New chat; attach **one** camera photo; send. Then set 2048 back | The Info sheet shows the input as `image/jpeg` at a 4096 px long edge (a single photo stays under 19 MB, so no shrinking hides the setting) |
| D10 | Files import | + › Files, pick an image from iCloud Drive or On My iPhone | It's added to the tray and sent |
| D11 | Paste | In Photos, Copy a photo; return to the app | The PasteButton appears; tapping it adds the image **without** the "Allow Paste" prompt |
| D12 | Background, lock | Request 4K, then lock the phone right away | Within about 2 min, a local notification "Image ready" on the lock screen; tapping it opens the chat with the result |
| D12b | Background, lock during preparation | Settings › Uploads › 4096. Attach 5 camera photos (enough that the body needs budget shrinking), Send, and lock the phone **immediately** | The request still goes out while locked (the background-task assertion covers preparation) and the notification arrives; it doesn't wait for the app to be reopened. Then set 2048 back |
| D13 | Background, app switch | Send, switch to another app for 2 min | Notification; result present on return |
| D13b | App switch during preparation | As D12b, but switch to another app immediately instead of locking | Same as D12b |
| D14 | Foreground, no banner | Send and stay in the chat | No banner; a success haptic |
| D15 | Force-quit | Send at 4K, then swipe the app away in the app switcher right away; relaunch after 1 min | The card reads "Interrupted…"; Retry succeeds |
| D16 | Offline | Airplane mode on; send; stay in the chat for 30 s; airplane mode off | "Waiting for network" (shown in the foreground from `ConnectivityMonitor`), then it completes by itself |
| D17 | Save to Photos | Long-press the D3 image → Save to Photos; grant Add Only | Toast; in Photos, Info (ⓘ) shows the **same type, pixel size and file size** as the app's Info sheet for that image (the API may return JPEG or PNG; either passes as long as they match) |
| D18 | Save to Files + bytes | Save to Files → On My iPhone. On the Mac: `xcrun devicectl device copy from --device $DEVICE_UDID --domain-type appDataContainer --domain-identifier com.andrewpurtell.imagegen --source "Library/Application Support/ImageGen/Images" --destination /tmp/ig-images`, then AirDrop the exported file to the Mac and compare `shasum -a 256` | Hashes equal |
| D19 | Share, Copy | Share → Messages (or AirDrop to the Mac); Copy → paste into Notes | Full-resolution image is received or pasted |
| D20 | Viewer | View; pinch; double-tap; rotate; swipe down | Smooth zoom; landscape fit; dismisses |
| D21 | Markdown | Ask "describe this image in a bulleted list" on an existing image | Bulleted Markdown text shows with the image (or as text only, with the "No image returned" badge) |
| D22 | Model switch | Open the Model pill and note the list (compare with Settings › Models labels); pick 3 Pro; check the Aspect menu; send | The menu lists every catalog model the key can use (those "Available", plus Flash) and none labeled "Not listed for this key"; with 3 Pro, no extreme ratios and no 512; the reply metadata shows `3 Pro` |
| D23 | Bad key | Settings › Replace Key with a deliberately wrong value; Validate | "Key rejected", not saved; the original key remains |
| D24 | Message actions | Copy Prompt; Edit and Resend; Delete a user message; Delete a reply | Each behaves as in D§3.6 |
| D25 | Chats | Rename, delete a chat (the confirmation shows the image count); relaunch the app | The list persists; deleted data is gone (Settings › Storage shrinks) |
| D26 | Memory | Optional: Xcode › Debug Navigator memory during D9 with a 48 MP photo | Peak under 300 MB; no jetsam |
| D27 | Dark mode and Dynamic Type | System dark mode plus the largest text size | The layout stays usable |
| D28 | Developer log after a background completion | Right after D12 (open the chat from the notification), tap the hammer › Last Action | The D12 Send: its Begin with `4K`, the other settings and the full prompt; the Prepare request, Attempt and Parse sub-actions; a step that the result arrived while the app was in the background; the notification step "Image ready"; `Result: success … HTTP 200 · 1 image …`. (This relies on Last Action skipping system actions, as the user confirmed in D§11 Q5.) |
| D29 | Developer log after a failure | After D15 (force-quit) and again after D23 (bad key), tap the hammer › Last Error | D15: the Send ending `Result: interrupted`, with the force-quit cancel reason or "the app was closed before this finished". D23: Save API key ending `failed`, with Validate key `HTTP 400` and `API_KEY_INVALID`; no part of the key is shown |
| D30 | Share and clear the log | Hammer › Full Log › Share, AirDrop the `.txt` to the Mac; then hammer › Clear Log… › Clear Log, then Full Log | On the Mac, `grep -c AIza ImageGen-log-*.txt` prints 0 (Gemini keys start with `AIza`), and the file is the same text as the view. After clearing (with nothing running), Full Log holds only the Log cleared action |

**Done when**
- [x] D1–D25, including D9b, D12b and D13b, and D28–D30 are PASS in `DEVICE_RESULTS.txt` (D26 and D27 are recommended). Any FAIL has a filed fix, or is accepted by the user.
- [x] The result of R3 (TEXT+IMAGE honors 2K, yes or no) is recorded and reported to the user, and the shipped `includeTextModality` default follows the user's decision (off if capped, on otherwise).

---

## 4. Risks and mitigations (plan-level; product risks are in D§11)

| ID | Risk | Likelihood | Impact | Mitigation | Milestone |
|---|---|---|---|---|---|
| P1 | The toolchain isn't ready: the license isn't accepted, there's no simulator runtime, XcodeGen is missing, and `sudo` is needed | certain | blocks everything | `doctor.sh`; M0 step 0 lists the user commands; `env.sh` uses `DEVELOPER_DIR`, so `xcode-select` is optional | M0 |
| P2 | Provisioning profile expiry | low | the app stops launching | Resolved: the user has a paid Apple Developer Program team, so profiles last a year (D§11 R9); free-team 7-day profiles don't apply. `device-install.sh` reinstalls in one command if ever needed; data persists | M10 |
| P3 | `MockURLProtocol` can't attach to background sessions | certain | background code untested | The transport takes the configuration as a parameter (D§9); a production config unit test; background behavior proven on the device (D12–D16) | M4, M10 |
| P4 | Swift 6 strictness with `NSObject` delegates, SwiftData and `@ModelActor` | high | compile errors or warnings | Default isolation set explicitly to nonisolated; models `nonisolated`; snapshots across actors; `Mutex` state; `@unchecked Sendable` only with a justification | M2, M4 |
| P5 | Swift Testing parallel runs sharing the global `MockURLProtocol` state | high | flaky tests | Per-test token header and a `Mutex` registry; `.serialized` as a fallback | M1, M4 |
| P6 | The test host app starts the background session, Reconciler or Janitor during unit tests | medium | flaky tests, side effects | `AppEnvironment` detects the test host (section 2.2) | M0, M4 |
| P7 | `PasteButton` with `Data` doesn't match image pasteboard types | medium | paste silently does nothing | Custom `PastedImage: Transferable` with `.image`, `.png`, `.jpeg` and `.heic` representations; a unit test; device test D11 | M6 |
| P8 | iOS 26 API names (`safeAreaBar`, `glassEffect`, `GlassEffectContainer`, `@concurrent`) differ in the installed SDK | low–medium | build breaks | M0 adds `Support/PlatformProbe.swift`, which uses each API once in an unused view or function, so a naming mismatch fails the M0 build rather than M5's; adjust DESIGN if a name differs | M0, M5 |
| P9 | The simulator can't exercise real PhotosPicker HEIC, Files or Photos flows fully | medium | gaps in verification | `simctl addmedia` and `privacy grant`; unit tests on helpers; device tests D9–D19 | M6, M7, M10 |
| P10 | The `.fileExporter` and Files byte check in the simulator is awkward to locate | medium | unverified "original bytes" | The `ImageFile` export unit test with SHA; a simulator `find`; device D18 | M7 |
| P11 | Parallel agents editing the same chat files | medium | merge conflicts | The ownership table in section 3; menus created with `MARK` sections; merge order | M6–M8 |
| P12 | Large images make the simulator slow or tests time out (48 MP, 30 MB JSON) | medium | slow CI | Generate the large fixtures once per suite into a temporary cache; tag them `.io`; time limits `.timeLimit(.minutes(1))` | M1, M3 |
| P13 | Keychain error -34018 in a simulator test host without signing | low | Keychain tests fail | Simulator ad-hoc signing (`CODE_SIGN_IDENTITY[sdk=iphonesimulator*] = -`); the tests are hosted by the app | M2 |
| P14 | Live API costs during the smoke and device tests | low | spend | The smoke test uses 512 and 2K only; the device script has about 15 generations, 3 at 4K | M9, M10 |
| P15 | An agent captures a screenshot that contains the API key | low | key leak | The key field is a `SecureField`; Settings shows only the last 4; mock mode uses `"mock-key"`; agents never type the real key | all |
| P16 | Notification permission prompt blocks unattended simulator runs | medium | blocked automation | Permission is asked on first send; in mock mode, `-SkipNotificationPrompt 1` (DEBUG) defers it; every M5–M8 screenshot row passes it | M5 |
| P17 | A Release-only compile error (an unguarded reference to DEBUG-only code) surfaces only at the M10 device install | medium | late, on-device breakage | All DEBUG access goes through `App/DebugHooks.swift` (lint rule); `scripts/build.sh --release` for the simulator is in the M0, M4, M5 and M9 "Done when" lists | M0–M9 |
| P18 | Background behavior that unit tests can't show (relaunch delivery, discretionary retries, force-quit cancel reasons) | medium | results late or mislabeled on the device | One ordered event stream, append-only accumulation, persisted retry counters and cancel-reason mapping, each unit-tested with fakes; device tests D12–D16 (with D12b, D13b). A background-created retry can only be forced on the device with a real 429, so it's noted as untested there unless one occurs | M4, M10 |
| P19 | Later milestones skip instrumentation, or log a Begin with no Result on an error path | medium | the Developer log misses steps exactly when debugging needs them | Section 2.8 contract; each milestone's log assertions with `assertPaired()`; the store's pairing backstop and launch-time closing of orphans; the M9 task 10 coverage review and code review item | M2, M4–M9 |

---

## 5. Traceability matrix

| # | Requirement (confirmed) | DESIGN | Milestones | Verification |
|---|---|---|---|---|
| R-01 | Personal iPhone app, installed once from Xcode with the user's paid Apple Developer Program team (profile lasts a year); no App Store or TestFlight | §1.4, §10, §11 R9 | M0, M10 | `project.yml`; D1 |
| R-02 | iOS 26 minimum, Swift 6 strict concurrency, SwiftData, Liquid Glass, iPhone only | §1.4, §5, §3.1 | M0, M2, M5 | build settings; `check-warnings.sh`; M5 screenshots |
| R-03 | Replicates the pipe: chat + generation/editing via Gemini REST | §2 | M1, M4, M5 | `PipeParityTests`; `GenerationServiceTests.endToEnd*`; D3/D6 |
| R-04 | API key in the Keychain | §4.10, §3.2 | M2, M5, M8 | `KeychainStoreTests`; M5 `01-onboarding`; D2, D23 |
| R-05 | Gemini 3.1 Flash Image is the default and mandatory | §2.5, §3.8 | M0, M1, M8 | `VocabularyTests.defaultModelIsFlash`; `AppSettingsTests.flashCannotBeDisabled`; M8 `02-models` |
| R-06 | Other image models through a per-chat model switch: every known catalog model, on by default, filtered by what the key can use; Settings can hide any but Flash | §2.5, §3.5, §3.8, §11 Q1 | M0, M1, M2, M5, M8 | `VocabularyTests.everyBuiltInEnabledByDefault`; `AppSettingsTests.allCatalogModelsEnabledByDefault`; `SettingsResolverTests` (incl. Flash Lite, 2.5 Flash Image, disabled-override fallback); `SettingsBindingsTests.modelMenuOffersEnabledAvailableModels`; `ModelAvailabilityServiceTests.unlistedModelLeftOutOfMenuButFlashSelectable` and `uncheckedModelsOfferedUntilFirstCheck`; M5 `07-pro-menus`; M8 `02-models`; D22 |
| R-07 | Stateless: only the selected images plus the latest instruction, as a single user turn | §2.1–2.4 | M1, M4 | `RequestBodyWriterTests`; `PipeParityTests` (one `contents` entry) |
| R-08 | Several attachments per message, all sent | §2.2 rule 1, §3.5 | M1, M6 | `InputSelectorTests.canSendRules`; `ComposerAttachmentsTests` (incl. `failedItemBlocksSendUntilRemoved`, `fullTrayDisablesAttachEntryPoints`); `GenerationServiceTests.multipleAttachmentsInOrder`; M6 `05-sent-grid`; D9 |
| R-09 | Fallback: pinned image, else the most recent image (model output or user upload); every turn in a chat with an image sends one (a text-only request happens only in a chat with no image yet, i.e. a new chat); the "Editing latest image" chip is informational and can't be dismissed | §2.2, §3.5, §4.3 | M1, M2, M4, M5 | `InputSelectorTests` (incl. `noImagesGivesNoImage`); `PipeParitySelectionTests` (p3, p6, p7, p8); `editLatestSendsOriginalBytes`; `pinnedUserUploadSendsPreparedBytes`; `modelImagesOrdinalFollowsPartsOrder`; `ChatScreenModelTests.implicitChipIsInformational`; M5 `09-success`; D6 |
| R-10 | "Edit from here": long-press to pin, chip above the composer; the pin is one-shot | §2.2, §3.5, §3.6, §11 Q2 | M5, M7 (viewer action) | `pinnedSendClearsPin`; M5 `13a-unpinned` + `13-edit-from-here`; D7 |
| R-11 | Saved chats: reopen, rename, delete | §3.3, §4.3, §4.4 | M2, M5 | `DataStoreTests`; M5 `03`, `15`, `16`; D25 |
| R-12 | **Aspect ratio configurable, default 16:9** (global + per chat, recorded) | §2.4, §2.5, §3.5, §3.8 | M0, M1, M2, M5, M8 | `SettingsResolverTests.defaultsAre16x9And2K`; golden `flash_text_only_16x9_2k.json`; M5 `05`; M8 `03`/`04`; D3–D5 |
| R-13 | **Resolution configurable, default 2K** (global + per chat, recorded) | §2.4, §2.5, §3.5, §3.8 | M0, M1, M2, M5, M8 | the same as R-12, plus `flash_512_9x16.json`; M5 `06`; D3–D5 |
| R-14 | Regenerate reproduces the recorded settings | §4.3, §6 | M2, M4, M5 | `regenerateUsesRecordedSettings`; M5 `17-regenerate-recorded`; D8 |
| R-15 | Safety threshold global, BLOCK_NONE default | §2.4, §3.8 | M1, M2, M8 | golden `flash_threshold_low.json`; `AppSettingsTests`; M8 `03` |
| R-16 | Save to Photos with the original bytes | §4.9 | M7 | `PhotoLibrarySaverTests`; M7 `03-photos-app`; D17 |
| R-17 | Save to Files with the original bytes | §4.9 | M7 | `ExportTests.imageFileExportsByteIdentical`; the M7 byte check; D18 |
| R-18 | Share and Copy | §4.9 | M7 | `ExportTests.pasteboard*`; M7 `05`; D19 |
| R-19 | Attach from Photos (PhotosPicker) and Files (fileImporter), plus Paste | §3.5, §4.8 | M6 | `FileImportTests`, `PasteSupportTests`; M6 `02`, `06`, `07`; D9–D11 |
| R-20 | Not in v1: camera, share extension, drag-and-drop | §1.3 | none | review: no such code or entitlements |
| R-21 | Downscale to a configurable max long edge (1536–4096); HEIC→JPEG; originals kept; ~20 MB limit | §4.8, §4.3, §3.8 | M3, M4, M6, M8 | `ImagePreprocessorTests` (incl. `heicWithAlphaBecomesJpeg`), `BudgetPlannerTests`; `heicUploadSentAsJpeg`; `SettingsBindingsTests.changingMaxLongEdgeAffectsNewAttachments`; `GenerationServiceTests.reusedUploadRepreparedAfterMaxEdgeChange`; `EditAndResendTests.clonesRepreparedAfterMaxEdgeChange`; M8 `05`, `05b-max-edge-4096`; D9, D9b |
| R-22 | Requests finish in the background; result in the chat | §4.6, §4.7 | M4, M10 | `TransportTests` (event ordering, buffering, append-only accumulation), `ReconcilerTests`, `BackgroundConfigTests`, `GenerationServiceTests.preparationHoldsBackgroundAssertion` / `finishedEventsCallsRelayAfterParse` / `backgroundCreatedRetryRecreatedOnActive`, `AppEnvironmentLaunchTests`; D12, D12b, D13, D13b, D15, D16 |
| R-23 | Local notification on completion when the app isn't active | §4.11 | M4, M5, M10 | `notificationPostedWhenInactive` / `Suppressed…`; D12–D14 (incl. D12b, D13b) |
| R-24 | Model text parts as rendered Markdown | §2.7, §4.12 | M1, M3, M5 | `ResponseParserTests` (incl. `resp_split_sentence.json`); `MarkdownBlocksTests`; M5 `18-markdown` (`chat:textonly`); D21 |
| R-24a | Undecodable image parts dropped with a notice; the previous image stays the edit base (confirmed, D§11 Q3) | §2.6, §2.7 | M1, M4 | `ResponseParserTests` (`resp_bad_image.json`); `GenerationServiceTests.noticesPersistedAndReloaded` and `undecodableImageKeepsPreviousEditBase` |
| R-24c | Safety and policy refusals (`PROHIBITED_CONTENT`, `IMAGE_SAFETY`, `IMAGE_OTHER`, …, unknown reasons verbatim) are shown simply as "Request refused: <reason>" with Retry, Edit and New Chat (`PUP_LIMITED_DISABLED`: no Retry, a one-line note; Edit hidden when the user message was deleted); returned text and `finishMessage` (stored as `errorMessage`) only in Info; a surviving image is never a refusal; a refused chat gets the chat-list red dot; never retried automatically (user request, D§11 Q4) | §2.6, §2.7, §3.3, §3.4, §3.6, §4.6, §4.11, §6 #12–#15, §11 Q4 | M1, M4, M5, M6 | `ResponseParserTests` (`resp_prompt_refused.json`, `resp_image_safety.json`, `resp_image_other.json`, `resp_no_image_no_parts.json`, `resp_refused_with_text.json`, `resp_unknown_finish_reason.json`, `resp_pup_limited.json`, `resp_bad_image_refused.json`, `resp_image_with_safety_finish.json`, and the non-refusal boundary `resp_no_parts_stop.json`, `resp_no_parts_max_tokens.json`, `resp_no_parts_unspecified.json`, `resp_no_parts_no_finish.json`, `resp_text_only_max_tokens.json`, `resp_text_only_unspecified.json`, `resp_text_only_no_finish.json`); `RetryPolicyTests.refusalNeverRetried`; `GenerationServiceTests.refusedOutcomeStoredNotAutoRetried`, `refusedWithTextKeepsTextOutOfReply` and `userRetryAfterRefusalSucceeds`; `ReplyPresentationTests` (incl. the deleted-user-message rows and the chat-row red dot); `ChatScreenModelTests.refusedCardEditLoadsComposerAndFocuses`, `refusedCardEditOnRegeneratedReplyTargetsSourceMessage` and `refusedCardNewChatCreatesAndNavigates`; `EditAndResendTests.refusedCardEditClonesAttachments`; M5 `10-refused-and-error` and the live refusal flow (`19-live-refused`) |
| R-24b | Response modalities: `["TEXT","IMAGE"]` by default; switches to `["IMAGE"]` if the smoke test confirms the 1K cap; the Advanced toggle re-enables text (user decision, D§11 R3) | §2.4, §3.8, §11 R3 | M1, M2, M8, M9, M10 | golden `flash_image_modality_only.json`; `AppSettingsTests.defaultsBlockNoneAnd2048AndTextOn` (or `…TextOff` after the flip); M9 task 8; D3 |
| R-25 | Not in v1: thinking, grounding, usage readout | §1.3, §2.4 | M1 | goldens have no `thinkingConfig` or `tools`; thought parts dropped (`resp_thought_parts.json`) |
| R-26 | Message actions: Regenerate, Edit and Resend, Delete, Copy prompt | §3.6 | M5, M6 | `ChatScreenModelTests`, `EditAndResendTests`; M6 `08`; D24 |
| R-27 | Image actions: Save to Photos, Save to Files, Share, Copy, Edit from here | §3.6 | M5, M7 | M7 `01-image-menu`; D17–D19, D7 |
| R-28 | Full-screen zoomable viewer | §3.7 | M7 | `ZoomMathTests`; M7 `06`–`09`; D20 |
| R-29 | XcodeGen, Swift Testing with mocked network (URLProtocol), simulator checks per milestone, then device install | §9, §10 | every milestone | the "Done when" checklists; `artifacts/M*/REVIEW.txt` |
| R-30 | Deliverables: DESIGN.md and IMPLEMENTATION_PLAN.md in `~/src/imagegen/doc/`, next to the reference pipe `doc/openwebui_gemini_filter.py` | none | none | these files |
| R-31 | Activity log (user request, 2026-10-16): before every action, a terse natural-language line saying what is about to happen with every operative parameter (the full prompt included); then the result. Exactly one begin and one result per action, guaranteed across a killed process; never the API key, headers or image bytes; kept on the device | §1.2 goal 9, §4.13, §4.7, §5, §7, §11 R14 | M0, M1, M2, M4–M9, M10 | `ActivityLogTypesTests`; `ActivityLogTests`; `RedactorTests.forLog*`; `ActivityLogRedactionTests`; `JanitorTests.runLogged`; the `GenerationServiceTests` log assertions (`logsSendBeginParametersAndResult`, `relaunchContinuesSendAction`, …); `GenerationServiceTests.logsEmptyReplyAsFailed`, `flushesBeforeStoringActionID` and `assertionEndFlushesFirst`; `ReconcilerTests.orphanedLogActionsClosedAsInterrupted` and `actionOfLiveRequestKeptOpen`; `AppEnvironmentLaunchTests.launchActionIsFirstAndPaired` and `resetDeletesLogBeforeLaunchBegin`; `BackgroundEventsRelayTests.flushesBeforeCompletionHandler`; `ChatScreenModelTests.chatActionsLogged`, `chatSettingChangesLogged` and `notificationPermissionLogged`; `APIKeySectionTests.removeKeyLogged`; `OnboardingModelTests`; `ComposerAttachmentsTests.attachLogsSourceAndPreparation`, `attachPartialFailureEndsFailed` and `trayReorderLogged`; `ExportTests.*Logged` (including `shareLogged`); `SettingsBindingsTests.settingChangesLogged` and `customIDHoldingKeyIsScrubbed`; `InMemoryKeyStoreTests.readAndSaveRegisterSecret`; lint `no-key-in-activity-log`; M9 task 10; D28–D30 |
| R-32 | Developer menu (`hammer`, always visible on the chat list and the chat screen, displacing nothing): Last Action, Last Error (refusals count), Full Log, Clear Log…; a monospaced, selectable (any range, `LogTextView`), live viewer with Copy and Share as `.txt`; Last Action shows the newest user-started action (D§11 Q5, confirmed) | §3.3, §3.4, §3.10, §11 Q5 | M5, M9, M10 | `LogViewerModelTests` (including `openSheetStaysOnItsAction`); `DeveloperMenuModelTests`; M5 `03`, `04`, `20-developer-menu`, `21-log-last-action`, `22-log-last-error`, `23-log-full`, `24-clear-log`; M9 regression and `06-log-after-relaunch`; D28–D30 |

---

## 6. Definition of done (v1)
- [ ] M0–M10 checklists complete.
- [ ] `scripts/test.sh`, `scripts/lint.sh` and `scripts/check-warnings.sh` pass on `main`.
- [ ] Device results D1–D25 (with D9b, D12b, D13b) and D28–D30 PASS. The R3 outcome is reported, and the `includeTextModality` default follows it (D§11 R3).
- [ ] DESIGN.md and this plan reflect the build that shipped (change log updated).

## 7. Agent prompts (templates)
- **Milestone agent:** "Implement M<n> of doc/IMPLEMENTATION_PLAN.md in this worktree. Read doc/DESIGN.md sections <list> first. Create only the files listed for M<n> (plus tests and fixtures). Run `scripts/gen.sh && scripts/test.sh && scripts/lint.sh && scripts/check-warnings.sh`, then the simulator verification steps, saving screenshots to `artifacts/M<n>/` and reviewing them in `REVIEW.txt`. Report each 'Done when' item with the evidence (command output or screenshot path). Don't change files owned by other tracks; if a contract in doc/DESIGN.md has to change, stop and report."
- **Review agent (per milestone):** "Check M<n> against its 'Done when' list and against the DESIGN sections it cites. Re-run the commands. Open the screenshots. Report any gaps as a checklist."

## 8. Change log
- 2026-10-15: first version. DESIGN.md was updated at the same time, as follows:
  1. D§2.2: rule 3 clarified (only **model** replies are filtered by state; user uploads are always eligible, as in the pipe).
  2. D§2.4: key order isn't significant; the writer uses `.sortedKeys` and golden comparisons are structural (replacing "field order as shown").
  3. D§2.6: added deviation rows for upload re-encoding, text-part joining and the 2xx status check.
  4. D§2.7: `OutputPart.image` carries a stored file, not `Data`; the parser writes each image to a caller-given directory (which matches the memory rule).
  5. D§3.4: the "resolution honored" check uses megapixels, not the long edge (extreme ratios such as 1:8 at 1K have a 3072 px long edge), and adds an aspect check for R4.
  6. D§4.1: added `NotificationPoster`, `BackgroundEventsRelay` and `DebugSupport/`.
  7. D§4.2: `AppEnvironment.shared` is created lazily and inert under the unit-test host.
  8. D§4.4: added the `response-<attempt>.complete` marker to the layout.
  9. D§4.8: `PasteButton` uses a custom `PastedImage` Transferable.
  10. D§5 / D§10: `SWIFT_DEFAULT_ACTOR_ISOLATION` is set explicitly to `nonisolated`; signing goes through `Config/Base.xcconfig` with an optional `#include? "Local.xcconfig"`; scripts are added.
  11. D§6: the CIVIC fallback is an explicit retry-policy case outside the auto-retry budget; Regenerate reuses the recorded values verbatim (dropping CIVIC only if the flag has since been set) and is disabled while the chat has a request in flight.
  12. D§9: the DEBUG mock mode lives in the app target and generates responses in code.
  13. D§11 R1: the toolchain facts are corrected (Xcode 26.6 is in `~/Downloads`, the license isn't accepted, and `xcode-select` points at the Command Line Tools).
- 2026-10-16: review pass. Aspect ratio and resolution remain configurable with defaults of 16:9 and 2K; the "Default (…)" menu items now follow the current global defaults. DESIGN.md was updated at the same time (see its section 12, second entry). Plan changes:
  1. M0 owns `Pipeline/SharedTypes.swift` (every cross-milestone DTO, with full fields), `Support/Logging.swift`, `App/DebugHooks.swift`, the shared test support files and the generated binary fixtures; the vocabulary spells out every raw value; `SelectionReason.none` is `noImage` (stored `"none"`); the catalog adds Flash Lite and 2.5 Flash Image and per-model high-fidelity limits.
  2. M1: tracks share only M0 types; Track 1B builds inputs by hand; an M1 integration step holds `PipeParitySelectionTests` (eight cases, adding p7/p8) and the coerced golden; `canSend` takes ready/pending/failed counts; the resolver falls back to Flash for disabled overrides; `RetryPolicy` has one shared budget and tells idle from resource timeouts by elapsed time; text parts are concatenated verbatim; `ESCALATION`/`PUP_LIMITED_DISABLED` fixtures; all four threshold goldens.
  3. M2: ordinals assigned on create; `ImageAsset.prepared*`; persisted retry counters, notices and the background-retry flag; `APIKeyStore` with `InMemoryKeyStore`; Janitor limited to `Images/`, after the Reconciler, skipping fresh files.
  4. M3: HEIC with alpha becomes JPEG; GIF tested, WebP gated with `.enabled(if:)`; `DecodeTimer`; timing asserted with `ContinuousClock`.
  5. M4: the transport exposes one ordered `AsyncStream` of events created before the session (replacing the handler setters and `drain()`); append-only accumulator; deferred resume for non-background sessions and the `.began` event; cancel reasons; background-task assertion around preparation; background-created retries re-created on foreground; reused uploads re-prepared when needed; the CIVIC flag set on the main actor; `GenerationServicing`; `ConnectivityMonitor`; the Reconciler starts in `didFinishLaunching`.
  6. M5–M8: full launch arguments on every screenshot row (with `-SkipNotificationPrompt 1`); 13 uses a fresh pin; new `18-markdown`; the `empty-overrides` seed has one turn; the card table drives `ReplyPresentationTests`; attachment entry points disabled at 14 and the picker limit never 0; failed or preparing tray items block Send; `ChatScreenModel+Attachments`; one `FileRepresentation` per type; host-side memory measurement; a max-long-edge test and screenshot.
  7. Tooling: `check-warnings.sh` does its own clean build; lint patterns in a code block with plain `|`, a `--self-test`, and a DEBUG-hooks rule; `build.sh --release` checked from M0; the device UDID is the hardware UDID, resolved by `device-install.sh`.
  8. M10: D9b, D12b, D13b added; D16 stays in the foreground; D17 compares with the app's Info sheet instead of assuming JPEG.
- 2026-10-16: completeness check. DESIGN.md sections 3.4, 4.1, 4.6, 4.7 and 4.11 tidied (see its section 12, third entry). Plan impact: `ReconcilerTests` gains `storedParsingStateReparsed`; `GenerationServiceTests` gains `notificationSuppressedWhenToggleOff`.

- 2026-10-16: user decisions. DESIGN.md was updated at the same time (see its section 12, fourth entry). Aspect ratio and resolution remain configurable, defaulting to 16:9 and 2K. Plan changes:
  1. Signing (D§11 R9): the user has a paid Apple Developer Program membership. Section 1.1 and M10 name the paid team; the first install is a one-time Product › Run, and the profile lasts a year. The free-team steps (trusting the developer, 7-day reinstalls) are removed, and P2 is reduced to a resolved note.
  2. Undecodable image parts (D§11 Q3) and the one-shot pin (Q2) are confirmed; new matrix row R-24a, and R-10 cites Q2. The new `GenerationServiceTests.undecodableImageKeepsPreviousEditBase` checks that the next edit uses the previous real image, and R-24a cites it.
  3. No skipping the latest image (D§2.2): `suppressImplicitBase` is removed from `SelectionInput` and `SendDraft`; `InputSelectorTests.suppressImplicitBaseGivesNoImage` and `ChatScreenModelTests.implicitChipDismissForcesNoImage` are removed, and `implicitChipIsInformational` is added; the M5 chip has no ✕, and screenshots `09-success` and `13a-unpinned` check that; R-09 updated.
  4. Models (D§11 Q1): every catalog model is enabled by default: Flash stays `.defaultMandatory`, the four optional models (3 Pro, 2.1, Flash Lite, 2.5 Flash Image) are `.optional(enabledByDefault: true)`, and the 3 Pro preview alias stays `.legacyIfListed` (its toggle is on by default, but it's offered in the menu only once `models.list` lists it, even before the first check; it has a Settings toggle like the others); `ModelCatalog.builtInIDs` is the `enabledModelIDs` default in `GenerationDefaults` and `AppSettings`; the model menu leaves out models `models.list` doesn't list; unconfirmed IDs stay validated at runtime. New tests `VocabularyTests.everyBuiltInEnabledByDefault`, `AppSettingsTests.allCatalogModelsEnabledByDefault`, `SettingsBindingsTests.modelMenuOffersEnabledAvailableModels` and `ModelAvailabilityServiceTests.uncheckedModelsOfferedUntilFirstCheck`; `unlistedModelDisabledButFlashSelectable` becomes `unlistedModelLeftOutOfMenuButFlashSelectable`; M8 `02-models` (now listing the preview alias) and D22 updated; R-06 updated and cites `uncheckedModelsOfferedUntilFirstCheck`.
  5. Response modalities (D§11 R3, decided by the user): M9 task 8 is now a measure, decide and flip step. If the smoke test confirms the 1K cap, the `includeTextModality` default becomes false (with the test, golden and doc updates listed there, including D§2.6, D§6 #18, D§9 and R-24b), with no further approval. `flash_text_only_16x9_2k.json` now sets `includeTextModality = true` explicitly, so the flip doesn't change it. M9 and M10 "Done when", D3 (which now sends again instead of using Regenerate, since Regenerate reuses the recorded modality) and the definition of done check it; new matrix row R-24b.
  6. Edit and Resend clones are re-prepared when the max long edge setting changed since they were prepared (M6), with the new `EditAndResendTests.clonesRepreparedAfterMaxEdgeChange`; R-21 cites it.
- 2026-10-16: safety refusals and doc move (user request). DESIGN.md was updated at the same time (see its section 12, fifth entry). Aspect ratio and resolution remain configurable, defaulting to 16:9 and 2K. Plan changes:
  1. Paths: DESIGN.md, this plan and the reference pipe moved into `doc/`. The header, the section 1.2 layout (a `doc/` folder; no `tmp/`), the `gen_pipe_fixtures.py` import and its `--pipe doc/openwebui_gemini_filter.py` command, the section 7 agent prompts and R-30 now say so.
  2. Refusals (D§2.7 rules 3 and 6): `ParsedOutcome.blocked` is now `.refused(reason:message:details:)`, `RequestState.blocked` is `refused`, and `RequestPatch.blockReason` is `refusalReason`. A missing image with any `finishReason` other than STOP / MAX_TOKENS / FINISH_REASON_UNSPECIFIED is a refusal (unknown reasons verbatim, returned text kept only in `details`). Section 2.4: `resp_prompt_blocked.json` is renamed `resp_prompt_refused.json`; `resp_finish_no_image.json` and `resp_no_parts_other.json` now expect `.refused`; new `resp_image_other.json`, `resp_no_image_no_parts.json`, `resp_refused_with_text.json`, `resp_unknown_finish_reason.json` and `resp_no_parts_stop.json` (the `.empty` boundary).
  3. Never auto-retried: Track 1D notes and `RetryPolicyTests.refusalNeverRetried`; M4 `GenerationServiceTests.blockedOutcomeStored` becomes `refusedOutcomeStoredNotAutoRetried`, plus `refusedWithTextKeepsTextOutOfReply`; `notificationPostedWhenInactive` checks the "Request refused: <reason>" body.
  4. Presentation (D§3.4): `ReplyPresentationTests` assert the exact "Request refused: <reason>" titles, no message line, and the buttons Retry, Edit, New Chat (Edit, New Chat for `PUP_LIMITED_DISABLED`). `ChatScreenModel` gains `editAndResend(userMessageID:)` and `newChat()`, with `ChatScreenModelTests.refusedCardEditLoadsComposerAndFocuses` and `refusedCardNewChatCreatesAndNavigates`; M6 extends `editAndResend` with cloning and adds `EditAndResendTests.refusedCardEditClonesAttachments`.
  5. DEBUG harness: mock scenario `promptBlocked` is renamed `promptRefused`, and `imageOther` is added; the `blocked` seed is renamed `refused`. M5 screenshot `10-blocked-and-error` becomes `10-refused-and-error` (a "Request refused: IMAGE_SAFETY" card with Retry, Edit, New Chat), and `03-chat-list-seeded` names the `refused` row. New matrix row R-24c.
  6. Follow-up consistency pass: rule-6 boundary fixtures (`resp_image_with_safety_finish.json`, `resp_bad_image_refused.json`, and `MAX_TOKENS` / `FINISH_REASON_UNSPECIFIED` / missing-reason variants of the no-parts and text-only fixtures); the refusal `finishMessage` is stored as `errorMessage` and checked in `refusedOutcomeStoredNotAutoRetried`; mock scenarios state their finish reasons (`textOnly` STOP, `empty` no candidates), and `imageSafety` carries a `finishMessage`; new `imageSafetyThenSuccess` scenario and an M5 live refusal flow (`19-live-refused`: Info, Edit, New Chat, Retry); `GenerationServiceTests.userRetryAfterRefusalSucceeds`; `ChatScreenModelTests.refusedCardEditOnRegeneratedReplyTargetsSourceMessage`; `ReplyPresentationTests` cover the deleted-user-message card rows and the chat-row red dot, which now also marks `refused` chats (D§3.3).
- 2026-10-16: activity log and Developer menu (user request). DESIGN.md was updated at the same time (see its section 12, sixth entry). Aspect ratio and resolution remain configurable, defaulting to 16:9 and 2K. The user asked for terse natural-language logging of every step, with the operative parameters before each action and the result after it, and a Developer menu to show the last action, the last error or the full log, or clear it. Follow-up answers: an always-visible `hammer` toolbar menu on the chat list and the chat screen; the full prompt and every parameter, never the API key, headers or image bytes; the log stays on the device. Plan changes:
  1. New section 2.8: the logging contract every milestone follows (one action per operation; Begin with every operative parameter; exactly one Result on every exit path; steps for decisions; the D§4.13 conventions; never the key, headers or image data; the owner logs and pure code doesn't; log assertions in each milestone's tests).
  2. Section 2.2: tests log through a real `ActivityLog` on a temporary file via `ActivityLogProbe`, and the inert test host creates no log file. Section 2.6: `-ResetStore 1` also clears the log. Section 2.7: the lint rule `no-key-in-activity-log`.
  3. Section 3: M0 owns `Support/ActivityLogTypes.swift` (the one exception to the shared-types file), M2 owns the rest of the log core, and M5 owns `Features/Developer/`; M2's graph label names the activity log. No new dependency edges.
  4. M0: the activity-log vocabulary and `ActivityLogTypesTests`; `SendRecordInput`, `RequestSnapshot` and `RequestPatch` gain `activityActionID`; `Logging.swift` becomes the OSLog mirror's categories. M1 Track 1C: `Redactor.forLog` and `errorBodyForLog`, with `RedactorTests`.
  5. M2: `ActivityLog` (facade), `ActivityLogStore` (actor), `ActivityLogQuery`, `ActivityLogFormatter`, `ActivityLogProbe` and `ActivityLogTests`; `GenerationRequest.activityActionID`, stored by `createSend` and `createRegenerate(sourceRequestID:activityActionID:)`; the Janitor logs its run and never touches `Logs/`.
  6. M4: `AppEnvironment` creates the log first and logs Launch; `GenerationService`, `RequestPreparer`, `Reconciler`, `BackgroundEventsRelay`, `NotificationPoster` and `ModelAvailabilityService` are instrumented, an action continues across a relaunch, and late completions get their own action; new log assertions in `GenerationServiceTests` and `ReconcilerTests`, plus `BackgroundEventsRelayTests`, `ActivityLogRedactionTests` (sentinel key) and `ModelAvailabilityServiceTests.refreshLogged`; the headless check reads the mirrored Launch line and the log file.
  7. M5: `DeveloperMenu`, `LogViewerModel`, `LogViewerSheet` and `LogTextFile`; the toolbars (chat list: Settings leading, hammer then New Chat trailing; chat screen: hammer next to the chat menu); onboarding, chat and message actions logged; `LogViewerModelTests`, `OnboardingModelTests` and `ChatScreenModelTests.chatActionsLogged`; screenshots `20-developer-menu`, `21-log-last-action`, `22-log-last-error`, `23-log-full` (+ `23a`), `24-clear-log` (+ `24b`), with `03` and `04` checking the toolbar placement; a `mock-key` grep of the log file.
  8. M6–M8: attachments, Edit and Resend, exports (`Export/ExportLog.swift`), Settings changes, key actions, models refresh and the storage actions are logged, each with log assertions in that milestone's suites.
  9. M9: the regression set includes the Developer screenshots; new task 10, a log coverage review with screenshot `06-log-after-relaunch`; a code review item for results on every exit path. M10: device tests D28–D30 (Last Action after a background completion, Last Error after a force-quit and a rejected key, share without the key, and clear), required in M10 and in the definition of done. New risk P19 and matrix rows R-31 and R-32.
  10. Follow-up review fixes (same day; DESIGN.md section 12, sixth entry, "follow-up review fixes"):
      - Section 2.6: `-ResetStore 1` now deletes `Logs/` (with the store and files) through `DebugHooks.resetBeforeLaunchIfRequested(root:)` before the `ActivityLog` is created, instead of clearing, so a run's log starts with its Launch Begin and has no Log cleared action (M4 builds this; `AppEnvironmentLaunchTests.resetDeletesLogBeforeLaunchBegin`; the M4 headless check launches with it). This replaces item 2's "also clears the log".
      - Section 2.2: `ActivityLogProbe` takes an injectable `sanitize:` (identity in M2), and redaction suites pass `Redactor.forLog(secrets:)`; the probe has no `UserDefaults`. Section 2.7: `no-key-in-activity-log` is a multiline perl check over balanced call arguments, self-tested with a continuation-line violation, and described as a tripwire. Section 2.8: rule 3 defines outcomes and puts the result of a parent with asynchronous children after its last child; rule 5 makes chat titles and all user-entered text private; new rule 9 (flush before handing control to the system).
      - M0: `ActivityEntry.relatedID` (Late completion) and `ActivityLogStatus`; no `empty` outcome (an empty reply's Send is `failed`). M1 Track 1C: `Redactor.forLog(secrets:)` removes registered secrets and key-shaped text, with two new `RedactorTests`.
      - M2: the facade sanitizes before the lock and keeps only the ID, timestamp and yield under it; its ID counter is seeded from the file's newest begin instead of `UserDefaults` (no conflict with the actors-never-write-defaults rule); `init` truncates a cut-off last line; `flush`, `entries(tree:)`, `entries(after:)`, `openActionsAtLaunch` and `clear` are control messages in the ordered stream; the store keeps an action index (not the entries), fills in names and origins for adopted actions, and calls the OSLog mirror itself; rotation and clear keep the begins of open actions; backup exclusion on `Logs/` and re-applied after rotation and clear, with explicit protection on temporary files; `Security/SecretRegistry`. New `ActivityLogTests` (`controlMessagesOrderedAfterEarlierEntries`, `lastErrorIncludesEmptyReplyAsFailed`, `lastErrorSkipsInterruptedResolvedBySuccessfulLateCompletion`, `partialFailureEndsFailed`, `rotationKeepsOpenActionBegins`, `clearKeepsOpenActionBegins`, `idSeededFromFileNotDefaults`, `adoptedEntriesGetNameAndOrigin`, `truncatedLastLineRecovered`; `fileProtectionAndBackupExclusion` now checks after rotation and clear) and `InMemoryKeyStoreTests.readAndSaveRegisterSecret`; the Janitor ends `failed` on a partial failure.
      - M4: Launch's Begin holds only what's known at `AppEnvironment` creation, with the application state as a step and the Result at the end of `didFinishLaunching`; `BackgroundEventsRelay.callAndClear` and `BackgroundTaskProvider.end` (and its expiry) flush first; the Send's ID is stored only after a flush; the request's `empty` state maps to `failed`; the permission request moved out of the Send steps; the retry step honors RetryInfo with no jitter; model-output inputs read "sent as original". New tests `logsEmptyReplyAsFailed`, `flushesBeforeStoringActionID`, `assertionEndFlushesFirst`, `flushesBeforeCompletionHandler` and `resetDeletesLogBeforeLaunchBegin`; `ActivityLogRedactionTests` uses a key-shaped 39-character sentinel, adds the prompt, error-message and `URLError` routes, and repeats with a non-key-shaped stored key.
      - M5: `DeveloperMenuModel` (one shared instance fed by `changes()`) drives Last Error's disabled state; `LogViewerModel` refreshes incrementally and stays on the action it opened with; `LogTextView` (read-only `UITextView`) replaces the `LazyVStack` of `Text` so ranges can be selected; onboarding registers the typed key and the key-save refresh is its own Models refresh action; `ChatScreenModel` logs Chat setting change and Notification permission. New `DeveloperMenuModelTests`, `LogViewerModelTests.openSheetStaysOnItsAction`, `ChatScreenModelTests.chatSettingChangesLogged` and `notificationPermissionLogged`, and `APIKeySectionTests.removeKeyLogged` (so M5's Remove API key logging has a test in M5).
      - M6: Attach and Edit and Resend end after their Prepare attachment children; partial failures end `failed`; Tray change is logged; new `attachPartialFailureEndsFailed`, `attachCapDropIsNotFailure`, `removeWhilePreparingCancelsChild` and `trayReorderLogged`. M7: Share is a button presenting the new `Export/ActivityShareSheet.swift` (`UIActivityViewController`), so Share is begun on tap and ended from its completion handler; `shareLogged` defined and `shareProviderCarriesOriginalType` added. M8: `customIDHoldingKeyIsScrubbed`; `deleteAllChatsLogged` covers a partial failure.
      - M9 task 10 runs as three launches with complete arguments (only the first resets; launch 2 has `-MockLatency 30` for the kill), with `simctl addmedia`, the `photos-add` grant and `-SeedPasteboardImage 1` listed. M10 D28 notes its dependence on D§11 Q5 (Last Action skipping system actions; confirmed by the user on 2026-10-16). Matrix rows R-31 and R-32 cite the new tests.
- 2026-10-16: M0 and M1 executed (branch `m0-m1`). Refinements found during implementation; DESIGN.md D§2.7 updated for the first:
  1. `ParsedOutcome.refused` gains `notices: [String]`, so an only-undecodable image with a refusing finish reason keeps its "1 image could not be decoded" notice, as D§2.7 rule 6 requires (the earlier signature had nowhere to put it).
  2. `ResponseParser.parse` is `async throws`; it throws only when writing a decoded image fails (disk full, D§6 #27), which M4 maps to "Not enough storage to save the result". Every response shape still maps to a `ParsedOutcome`.
  3. `RequestBodyError.imageSizeMismatch`: `write` checks that each image file still has its `byteCount`, so the `Content-Length` from `predictedSize` can't silently disagree with the body.
  4. Section 2.7: `debug-names-only-via-hooks` uses `\bLaunchOptions\b`, because the plain pattern also matched `UIApplication.LaunchOptionsKey` in M0's `AppDelegate`. `lint.sh` uses `/usr/bin/grep`, whose `-E` supports `\b`.
  5. Section 1.4: `scripts/env.sh` honors `IMAGEGEN_SIM` (a simulator name or UDID) to target an already-booted simulator instead of `ImageGen-Sim`.
  6. `scripts/gen_pipe_fixtures.py` compiles the pipe with `from __future__ import annotations` prepended, because the pipe's `dict | None` annotation can't be evaluated by Python 3.9 at import time. Behavior is unchanged.
- 2026-10-16: M2 executed (branch `m0-m1`). Refinements; DESIGN.md D§5 updated for the first:
  1. `DataStore` conforms to `ModelActor` by hand (its own `modelExecutor` and `modelContainer`) instead of using the `@ModelActor` macro, whose generated `init(modelContainer:)` can't also take the `FileStore` and clock. Isolation and executor are the same. Tests declare `typealias DataStore = ImageGen.DataStore`, because SwiftData also declares a `DataStore` protocol.
  2. Shared types gain `ReplyImage` (the `images` of `completeReply`, already moved into `Images/<conv>/`) and `DeletionResult`. `deleteConversation`, `deleteMessage` and `deleteAll` return `DeletionResult` (live request IDs plus files removed, MB freed and failures), so the Delete chat, Delete message and Delete all chats results can state what D§4.13 asks for.
  3. `DataStore` also has `overrides(_:)`, `imageSnapshots(messageID:)` (a message's images in ordinal order; Edit and Resend in M6 clones from these) and `janitorSnapshot()`. A reply's `Message.text` is its text parts joined by a blank line. `StoreFactory.makeContainer` throws.
  4. `ActivityLog` also has `actionRecords()`, `status()`, `flush(timeout:)` (for the 1 s and 0.5 s caps in D§4.13) and `close()` (finish the stream and wait for the store). Its `init` takes `limits:` (rotation sizes, and a write delay used only by tests).
  5. `AppSettings` persists the set of *disabled* catalog models, so a model added to the catalog later starts enabled; `enabledModelIDs` is computed from it and always includes Flash.
  6. The iOS Simulator doesn't implement Data Protection: `.protectionKey` reads back nil there, so `ActivityLogTests.fileProtectionAndBackupExclusion` checks the class only on a device (backup exclusion is checked everywhere). M10 should run that test, or inspect the file, on the iPhone.
- 2026-10-16: M3 executed (branch `m0-m1`). Shapes settled during implementation:
  1. `MarkdownBlock` is `heading(level:text:)`, `paragraph`, `listItem(depth:number:text:)` (bullets have no number), `code(language:text:)` and `quote`. A continuation line joins its list item or quote. Headings, list items and paragraphs that hold only a Markdown image are dropped.
  2. `BudgetPlanner.plan` takes `[PreparedSize]` (bytes and long edge; the index is the array position) and returns `.fits`, `.shrink(index:toLongEdge:)` or `.cannotFit`. The driver `fit(_:envelopeBytes:shrink:)` takes an injectable shrink, records each shrink, and throws `BudgetTooLarge` with the D§4.8 message.
  3. `ImagePreprocessor.shrink` writes `<id>-<newEdge>.jpg` next to its input and keeps `longEdgeSetting`. `ImageInspector` errors are `UnsupportedImageError` ("Unsupported or damaged image"). `Imaging/MemoryFootprint.swift` holds the `phys_footprint` reader for the DEBUG prepare log.
  4. `ThumbnailService` caches `CGImage`s (cost w×h×4, 120 MB), flattens alpha before writing JPEG, and refreshes a thumbnail file's modification date on a disk hit, so the Janitor's LRU trim sees it as used. `DecodeTimer` takes an injectable clock, main-thread check and reporter. `SizeClass` also has `nearestAspect` for the "returned 1:1" marker.
- 2026-10-16: M4 executed (branch `m0-m1`). Refinements; DESIGN.md D§4.4 updated for the first:
  1. The `.complete` marker holds the HTTP status as text (empty for a transport error), so the Reconciler's re-parse (D§4.7 step 4) knows the status after a crash.
  2. `ResponseAccumulator` never creates a missing `Requests/<id>/` folder (it exists for every live request, holding `body.json`), so a completion for a deleted request writes nothing.
  3. One request per chat: `GenerationService` keeps an in-memory claim only from the tap until the request record exists; after that the record's live state enforces it. A chat is free as soon as its request's terminal state is saved, without waiting for the notification and log result.
  4. Shared types: `RequestPatch.clearOutcome` (a Retry clears the previous outcome's fields, which nil-means-unchanged patches couldn't do) and `LocalErrorStatus` (`EMPTY`, `MALFORMED`, `NO_API_KEY`, `TOO_LARGE`, `INPUT_MISSING`, `DISK_FULL`, `TIMED_OUT`, `NETWORK`, `EMPTY_PARTS`), the `errorStatus` values for failures that aren't API errors. M5's reply card maps them to the D§3.4 rows. A timeout stores "No response within 5 min." or "… 30 min.".
  5. `GenerationService` takes a `Dependencies` value (transport, store, files, key store, log, background tasks, notifier, activity, thumbnails, retry policy, defaults reader, the CIVIC and background-events callbacks, the session description, and test seams for shrink, budget and clock), and has `stop()`. The Reconciler calls `markInterrupted` (which returns the action it closed), `refreshLiveTask` and `reparse`.
  6. `URLSessionTransport` tracks the tasks it holds un-resumed for a delay, because `session.allTasks` doesn't reliably list never-resumed tasks; cancelling one cancels and resumes it, so its cancellation is delivered. `invalidateAndWait()` (tests) waits for `didBecomeInvalidWithError`, after every completion callback.
  7. `NotificationPoster` is a struct implementing `NotificationPosting` with injected `isEnabled` and `deliver` (production: `UNUserNotificationCenter`); `AppSettings.readNotifyOnBackgroundCompletion` reads the toggle without the main actor. Cancelled and interrupted requests post nothing.
  8. The Launch step logs the raw `applicationState`. Under the scene lifecycle it reads `background` in `didFinishLaunching` until a scene connects, even for a user launch, so (as D§4.13 already says) the Background events action, not Launch, identifies a background wake.
  9. When the preparation assertion expires, its handler logs the Send result first, as required; the Prepare request sub-action that was still open is then closed by the store's backstop ("parent finished first"). This is the one non-normal path that uses the backstop.
  10. The OSLog mirror writes lines in the viewer's format (`[Launch 0000] Result: success in 0.1 s · …`). `ModelsClient` has a `requestDecorator` for tests. `MockEnvironment` lives in `App/AppEnvironment.swift`, so both `DebugHooks` branches can name it.
- 2026-10-16: live smoke test run with a project-scoped key the user supplied (kept outside the repo; never logged). `LiveSmokeTests.textToImageThenEdit` passed in 20 s: 1:1 / 512 returned 512×512, and the 16:9 / 2K edit (sent as the first output's original bytes) returned 2752×1536 with `["TEXT","IMAGE"]`. R3's 1K cap was not observed, so `includeTextModality` stays true by default; M9 task 8 can re-measure before closing R3. A search of the build logs, result bundles, repo, git history, the simulator's OSLog and the app container found no trace of the key. DESIGN.md D§9 and D§11 R3 record the measurement.

- 2026-10-16: M5 executed (on `main`). DESIGN.md sections 1.3, 3.3 and 4.13 updated (see its section 12, last entry). Refinements:
  1. `ChatServices` bundles what a chat screen needs (store, files, generation, settings, log, connectivity, activity, notifications, navigator, thumbnails, pasteboard writer, draft debounce) and builds `ChatActions` (New chat, Rename chat, Delete chat, and the new Delete empty chat), which the chat list and chat screen share. `AppEnvironment` is `@Observable` and adds `navigator`, `developerMenu`, `notificationPermission` and `chatServices()`.
  2. `DataStore` gains `liveRequest(conv:)`, `originatingUserMessage(requestID:)`, `draftText(conv:)`, `messageInfo(_:)`, `imageFile(_:)`, `imageCount(conv:)` and `messageCount(conv:)`. `ModelsClientError.keyRejected` and `KeyValidation.rejected` carry the API's reason, which onboarding shows. `ThumbnailService` checks that the file exists before decoding.
  3. `SecretRegistry.minimumLength` is 8 (and `Redactor` uses the same threshold): a short registered string such as a test key was rewriting ordinary words like "background" in log lines.
  4. Leaving a chat with no messages deletes it through `ChatActions.discardIfEmpty`, logged as a system "Delete empty chat" action only when there is one to delete (`ChatScreenModelTests.leavingEmptyChatDeletesItAndLogs`, `leavingChatWithMessagesKeepsItAndLogsNothing`).
  5. UI fixes found in the screenshot review: pill menus use `.menuOrder(.fixed)`, so "Default (…)" stays first when a menu opens upward; the chat-list delete confirmation is attached to its row, so the iOS 26 popover points at the chat being deleted, and reads "Delete this chat?" for a chat with no images; the transcript re-settles at the bottom when a request's state changes (a completed pending card is taller), unless the user has scrolled away; image context-menu previews fall back to `AppEnvironment.shared` for thumbnails (the preview is rendered outside the environment and crashed); the dark-mode accent is deeper, for bubble contrast.
  6. `LogViewerModel` serializes its refreshes, so overlapping `changes()` events can't append the same lines twice. `ChatScreenModel.load()` never restores a saved draft over text typed while it was loading.
  7. `scripts/run-sim.sh` launches with `--terminate-running-process` after a short settle. Screenshot runs must pass `$BASE` as a zsh array (`BASE=(…)`), since zsh doesn't word-split a string. The simulator's text injection is asynchronous, so a capture waits about 2 s after a push before tapping the text field and after typing before tapping Send.
  8. iOS 26 presents `confirmationDialog` as a popover with no Cancel button (tapping outside cancels); `24-clear-log` is reviewed on that basis.
  9. Future enhancement (user note): editing a sent message in place, in its bubble. Today Edit and Resend, and a refused reply's Edit, load the composer and send a new turn (D§1.3, D§3.6).
- 2026-10-16: M6 executed (on `main`). Refinements:
  1. `ChatScreenModel.tray: [TrayItem]` replaces M5's settable `trayCounts`, which is now derived. `TrayItem` holds the original's file, type, size and displayed dimensions as soon as it's imported, so `staged` builds the `StagedAttachment` the send records; `ChatScreenModel+Attachments.swift` also holds Edit and Resend (moved from `ChatScreenModel.swift`).
  2. Every import goes through `AttachmentCandidate` (a filename and an async `stage` closure that writes the original into `Staging/`): `.photo(PhotosPickerItem)`, `.file(URL)` (security-scoped copy, `FileImport.copySecurityScoped`) and `.data(Data)` (paste; `AttachmentStaging.write` names the file from `CGImageSourceGetType`). Tests drive `attach(_:from:)` with `.data` and `.file` candidates.
  3. `ChatServices.prepareUpload` is the seam for `ImagePreprocessor.prepare`; tests gate it to hold an item in `.preparing`.
  4. `DataStore.uploadSources(messageID:)` returns a user message's uploads (snapshot, size, dimensions, filename) for cloning. A clone made at the current max long edge clones its prepared file too; otherwise it enters the tray `.preparing` and is re-prepared from the cloned original as a Prepare attachment sub-action of Edit and Resend. A draft with tray items (not only text) asks before Edit and Resend replaces it; confirming deletes the old tray's staged files and logs a step.
  5. The PasteButton sits in the input row only while `UIPasteboard.hasImages` and the tray has room, kept current by `PasteboardImageWatcher` (on appear, on `scenePhase == .active`, on `UIPasteboard.changedNotification`). `-SeedPasteboardImage 1` is wired in `DebugHooks.prepareLaunch` (the mock renderer's JPEG bytes; converting to PNG through `UIImage` trips the `no-full-decode` lint).
  6. The dimmed pin chip dims its thumbnail and text: `.opacity` on a glass view inside a `GlassEffectContainer` has no visible effect.
  7. Screenshots also include `06b-pasted` and `08a-edit-resend-menu`. `02-photos-picker` needs about 2 s after the taps before capturing (the picker runs out of process).
  8. New suites: `ComposerAttachmentsTests` (14), `EditAndResendTests` (7), `FileImportTests`, `PasteSupportTests`; `GenerationServiceTests.heicUploadSentAsJpeg`.
- 2026-10-16: M7 executed (on `main`). DESIGN.md D§4.9 updated for the first item. Refinements:
  1. Save to Files uses `.fileExporter(document:)` with `ImageFileDocument`, a `FileDocument` whose `FileWrapper(url:)` reads the original file and is named with the suggested name. `.fileExporter(item:)` with the `ImageFile` Transferable crashed on iOS 26.5 (`NSFileWrapper preferredFilename cannot be empty`, inside SwiftUI). The bytes are still the original's (the simulator byte check matched). The document form has no `onCancellation`; a cancel arrives as `CocoaError.userCancelled` and is logged `cancelled`. SwiftUI clears `isPresented` before `onCompletion`, so only `onCompletion` ends the action. `ImageFile` still backs Share (and `ExportTests` export through its `FileRepresentation`s).
  2. `ImageExportModel` (`Features/Export/`) holds Save to Photos, Save to Files, Share and Copy for one screen, with `ImageExportPresenter` attaching the exporter, the share sheet, the Photos-denied alert, the toast and the success haptic. The chat and the viewer each own one (the viewer is a full-screen cover, so the chat's presenter can't present over it). `ExportItem` carries what the log states (ID, type, bytes, pixel size, creation date for the suggested name).
  3. `PhotoLibraryAccess` is the protocol around `PHPhotoLibrary` (`SystemPhotoLibrary`; tests use a fake). `PasteboardWriter` takes the pasteboard, so tests use a named one.
  4. `ActivityShareSheet` uses `UIActivityItemsConfiguration(itemProviders:)` with Link Presentation metadata (the suggested name and the original as the preview image) for the sheet's header; `ShareTicket` makes the Result write at most once (completion, then `onDisappear`).
  5. `Support/Toast.swift` (`ToastView`, `.toast(_:)`) is shared by the composer and the exporters.
  6. Viewer: `ViewerRequest`/`ViewerImage` are built by `ChatView` from the message's images and its request's settings; the top bar shows "2 of 3" when paging; `ZoomMath` holds the fit, max, double-tap and centering math. The DEBUG `phys_footprint` line is debug-level and isn't persisted by the unified log; the M7 memory check used `footprint` (141 MB after a 5504×3072 decode, peak 165 MB).
  7. New DEBUG launch option `-Orientation landscape` (`LaunchOptions.orientation`, applied in `DebugHooks.prepareLaunch` with `requestGeometryUpdate`), because the simulator tool can't rotate and osascript lacks assistive access. Screenshot `08-viewer-landscape` uses it.
  8. New suites: `ExportTests` (12), `PhotoLibrarySaverTests` (7, one integration test run with `TEST_RUNNER_IMAGEGEN_PHOTOS_GRANTED=1`), `ZoomMathTests` (4).
  9. Live rotation (checked once the user granted the terminal accessibility access, so Simulator › Device › Orientation can be driven with osascript): a page `TabView` keeps a stale container frame after rotating, clipping 10 pt of the image, so `ImageViewer` rebuilds the pager with `.id` keyed on its container size (the selection lives in `current`, so the page survives); `ZoomingScrollView` also resets its offset when it re-fits. Screenshots `08b`–`08d`.
- 2026-10-16: in-place rename (user request; DESIGN.md sections 3.3 and 3.4). `InlineTitleField` (`Features/ChatList/`) pairs a UIKit `AutoFocusTextField` (it becomes first responder and selects all when it enters a window, because `@FocusState` doesn't reach a field hosted in the navigation bar on iOS 26.5) with ✕ and ✓. `TitleEdit.change(draft:current:)` decides whether a save renames. The chat list's Rename (context menu and swipe) edits the row in place (the row drops its link while editing); the chat screen's long-press on the title uses `ChatScreenModel.beginTitleEdit` / `commitTitleEdit` / `cancelTitleEdit`. Renames are logged as before. New tests: `ChatScreenModelTests.inlineTitleEdit*` (4) and `TitleEditTests`. Screenshots `artifacts/M7/11-inline-rename`, `12-list-inline-rename`.
- 2026-10-16: chat-list long-press (user request; DESIGN.md section 3.3). Long-pressing a row edits its title in place directly, and the row's context menu (Rename, Delete) is gone: Delete is on the trailing swipe, Rename also on the leading swipe, and VoiceOver has a Rename action. The long press is a `.simultaneousGesture` on the `NavigationLink`; an `.onLongPressGesture` on the row label swallowed the link's tap. M5's `16-delete-confirm` steps (long-press › Delete) now use the swipe.
- 2026-10-16: M8 executed (on `main`). Refinements; DESIGN.md D§3.8 updated for the first:
  1. Settings › Models has a Check Now button as well as pull to refresh; both log a user Models refresh, whose reason `ModelAvailabilityService.Reason.manual` now reads "manual check".
  2. `SettingsModel` (`Features/Settings/`) holds every control except the API key, with `Services` injected (settings, key store, availability, models client, store, files, thumbnails, generation, log, navigator, a notification-status reader). Each change logs a paired Settings change with old → new, and nothing when the value is unchanged; custom IDs log Add custom model with the ID private. `APIKeySectionModel` gains Replace Key (the onboarding form inline, source "Settings › Replace Key"), Validate Now and the "Saved (…a1B2)" status. `AppEnvironment` builds both (`settingsModel()`, `apiKeySectionModel()`).
  3. `Navigator.openSettings(_:)` and `settingsPath` open Settings on a page; the 404 card's Open Models and `-Scene settings:models` use it. `-ForceNotificationState` is wired through `DebugHooks.forcedNotificationState`.
  4. Delete All Chats cancels live requests, deletes every chat (`DataStore.deleteAll`, counted with the new `inventory()`), clears the thumbnail cache, resets the navigation path, and logs chats, images, files and MB. Its confirmation popover and alert are attached to the button, so the popover points at it.
  5. The composer shows `OnboardingModel.flashWarning` as a banner when the cached model list doesn't include Flash (`ChatScreenModel.flashUnlisted`).
  6. The reply Info sheet lists each sent input ("Sent 1 image/jpeg · 4096×3072 · 408 KB") from the recorded `RequestInput`s, which `05b-max-edge-4096` needs.
  7. Simulator notes: the default aspect, resolution and max edge live in `UserDefaults`, which `-ResetStore 1` doesn't clear, so a run that changes them must set them back. A scripted pull to refresh didn't trigger `.refreshable` in the simulator, hence Check Now.
  8. New suites: `SettingsBindingsTests` (18), `CustomIDScrubbingTests`; `ModelAvailabilityServiceTests` gains `unlistedModelLeftOutOfMenuButFlashSelectable` and `uncheckedModelsOfferedUntilFirstCheck`.
- 2026-10-16: M9 executed (on `main`). DESIGN.md sections 2.4, 3.3, 3.8, 4.4 and 9 updated. Results are in `artifacts/M9/REVIEW.txt`; refinements:
  1. R3 settled: the second live smoke run returned 2752×1536 (2K class) for the 16:9 / 2K edit with `["TEXT","IMAGE"]`, so task 8's flip does not apply and `includeTextModality` stays on.
  2. Log pairing (task 9), from an audit of every `begin`: `GenerationService.Preparation` has an atomic phase so an expiring background-task assertion and a successful preparation can't both write the Send's result, and a task never starts after expiry (`PreparationPhaseTests`); an adopted background retry is registered before re-creation, so a failed re-creation closes its action; `cancel` adopts an earlier process's action, and the deleted-record path closes its Attempt by name; `ImageExportModel.closeOpenActions` ends a superseded or orphaned Save to Files / Share `cancelled`; `BackgroundEventsRelay` remembers events that finished before the handler arrived. New tests: `adoptedRetryRecreationFailureClosesAction`, `deletingAdoptedRequestClosesItsActions` (both fail without the fixes), `openExportsClosedWhenSupersededOrScreenCloses`, `eventsFinishedBeforeHandlerStillCallIt`.
  3. Every file-operation `try?` carries a one-line justification.
  4. UI fixes: composer pills wrap as whole capsules at accessibility sizes (`Support/FlowLayout`); chat-list rows stack title over time at accessibility sizes; the tray ✕ is inside the thumbnail (offset outside the scroll view, it took no taps); chat-list swipe › Delete confirms with a list-level alert.
  5. `-SeedLargeChat 1` is implemented (`DemoSeeder.seedLargeChat`, key `large`: 30 turns, 60 messages, 40 images). The Janitor removes stale empty chat folders under `Images/` (`JanitorTests.removesStaleEmptyChatFolders`).
  6. The performance numbers: 0 main-thread decodes while scrolling the large chat (peak 170 MB); 48 MP preparation peak 107 MB.
  7. The regression set re-captures the launch-only screens into `artifacts/M9/regression/`; the interactive ones were exercised in the task 10 run (which needed two extra relaunches without reset, to pick up the tray and delete fixes).
  8. The Simulator app's Device › Orientation menu went unavailable mid-run (no device window), so the landscape chat capture uses `-Orientation landscape`.
- 2026-10-16: Concurrency review after M9 (on `main`), at the user's request before M10. Five read-only reviewers (pipeline, networking, persistence, screen models, log/imaging/launch) reported about 35 findings; each was checked against the code, and the fixes are in `artifacts/M9-concurrency/REVIEW.txt`. DESIGN.md sections 3.5, 4.4, 4.6, 4.7, 4.13 and 6 updated. Highlights:
  1. `GenerationService.exclusive(_:)` serializes the handlers of one request; `reparse`, `refreshLiveTask` and `markInterrupted` take the attempt or state the Reconciler saw. New `PipelineRaceTests` (6), all failing before the fixes (double-saved reply, phantom retry, Stop ignored during the CIVIC rebuild, a notification for a deleted chat, a duplicate re-created task, a success logged as interrupted).
  2. Janitor: staging retirement, list-then-snapshot, re-check, `rmdir`. Activity log: a working `flush(timeout:)`, prompt answers after `close()`, no `0000` ID, partial-write repair. Thumbnails decode off the main thread (the M9 "0 main-thread decodes" measurement couldn't see ImageIO's lazy decode, which happened at first draw) and image files are written atomically. The Redactor removes longer secrets first.
  3. Screens: Send, Retry and Regenerate are gated while starting; an unrecorded send gives back its text and items; leaving a new chat mid-send keeps it; Replace Key's Cancel during validation saves nothing; Validate Now and model refreshes drop superseded results; Add custom model can't add twice; an untouched title edit keeps the automatic title; a notification tap that cold-launches the app opens its chat; deletes stop requests recorded after their live-request check.
  4. Not fixed, for M10: a launch before the first unlock (protected data unavailable) is unverified; see REVIEW.txt.
- 2026-10-16: Comment pass (at the user's request): `doc/SWIFT_PRIMER.md` added, and all 116 source files commented for a reader new to Swift (comments only; checked by stripping comments and comparing). Bugs the commenters found, fixed in a follow-up commit: a store error made the completion handler and the Janitor's re-check treat a request as deleted (now kept); two pills changed quickly could undo each other (changes now saved in turn, `ModelRaceTests.quickPillChangesKeepBoth`); the Reconciler's log pass could write a second Result for a re-parsed request, whose Attempt the backstop closed (now closed with its real outcome; `completeMarkerReparsed` extended); a refused notification was logged as posted (`failedPostIsLoggedAsNotPosted`); a stale "Checking the previous model…" message and a theoretical stuck Validate Now spinner. Section 2.6: `-SeedPasteboardImage` writes a JPEG (the table said PNG). Open follow-ups are listed in `artifacts/M9-concurrency/REVIEW.txt`.
- 2026-10-17: M10 executed (on `main`) on the user's iPhone 17 Pro Max (iOS 26.6.2), signed by the paid Individual team (B36P525327; Xcode still labeled it "Personal Team" from before enrollment, and the team ID is the same). Results are in `artifacts/M10/DEVICE_RESULTS.txt`: every required check passes; D26 and D27 were skipped (optional; covered in the simulator in M9). Changes:
  1. `scripts/device-install.sh` implemented: picks the one reachable iPhone (stops on several, or when Developer Mode is off), registers it with `-allowProvisioningDeviceRegistration`, builds, installs and launches. No Xcode GUI Run was needed. Results were checked from the activity log, copied off the device with `devicectl` after each batch (0 occurrences of the key each time).
  2. A crash on tapping a notification (D12): the `async` notification delegate methods, `nonisolated`, had UIKit's completion handler called off the main thread. Fixed with the completion-handler forms on the main thread; re-checked.
  3. An image's long-press menu lacked the message section (D8: no Regenerate for an image-only reply). Fixed per D§3.6.
  4. User requests, done during the run: Edit from here sets the aspect ratio and resolution pills to the pinned image's recorded values, with a haptic and a toast; the pills and chips use glass tinted nearly solid by appearance, with black or white labels, to stay legible over images.
  5. R3: 2K honored with TEXT+IMAGE on the device too (D3, 2752×1536), the third measurement; `includeTextModality` stays on.
  6. Byte checks: Save to Files (from iCloud Drive) and Share › AirDrop each match the stored original's SHA-256.
  7. Follow-ups, not done: a "New Chat" first row in the chat list (user request); the Background events result counts completions since the last end of events, not this wake's; the Reconciler logs "re-parse" for a request the completion already ended; a Models refresh is logged as failed ("no API key") on every foreground before onboarding; D12b's body stayed under the budget, so locking during a budget shrink wasn't exercised.
