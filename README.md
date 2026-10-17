# ImageGen

ImageGen is a personal iPhone app for making and editing images with Google's Gemini image models. You chat with the model. You type an instruction, and you can attach images. The app sends the request to the Gemini API with your own API key. The reply is one or more images, sometimes with text. Your chats stay on your phone.

The app does on an iPhone what an [OpenWebUI](https://openwebui.com) "pipe" did on a server (`doc/openwebui_gemini_filter.py`). Given the same inputs, it sends the same request, with a few deliberate changes that the design document lists.

The app is for one person. It is not on the App Store. You build it with Xcode and install it on your own phone.

## What it does

- **Make an image from text.** The default model is Gemini 3.1 Flash Image. Each chat can use another image model that your key can use.
- **Edit an image.** Each new message edits the latest image in the chat, unless you choose another one. Long-press any earlier image and choose **Edit from here** to continue from it.
- **Attach images** from Photos, Files or the clipboard, up to 14 in one message. The app converts HEIC to JPEG, removes location and other photo metadata, and shrinks each image to a long edge that you set.
- **Choose the shape and size.** Aspect ratio and resolution have defaults (16:9 and 2K) that you set in Settings. Each chat can change them. Every request records the values it used, so **Regenerate** gives the same settings again.
- **Keep working while it runs.** A request continues when you leave the app or lock the phone. A notification tells you when the image is ready. A request also survives when iOS stops the app.
- **Save the real file.** Save to Photos, Save to Files, Share and Copy all give the exact bytes that the API returned. The app never re-encodes them.
- **See what happened.** The app logs each action in plain language: what it is about to do, with its settings, and then the result. The Developer menu (the hammer) shows the last action, the last error, or the full log. The log never contains your API key or image data.

## How it works

### The layers

The code is in layers. Each layer uses only the layers below it.

| Folder | What it does |
|---|---|
| `ImageGen/Features/` | The screens: the chat list, the chat, the composer, the image viewer, Settings, onboarding and the Developer menu. Each screen has a view and a model. |
| `ImageGen/App/` | Starts the app, builds each service once, and connects iOS events (launch, background wake, notification taps) to the services. |
| `ImageGen/Pipeline/` | Prepares each request, sends it, retries it when the service is busy, and saves the result. `GenerationService` is the center of the app. |
| `ImageGen/Networking/` | Sends requests through an iOS background download session. |
| `ImageGen/Gemini/` | Writes request bodies and reads responses in the Gemini JSON format. |
| `ImageGen/Persistence/` | Stores chats in a SwiftData database and images as files. Cleans up unused files at launch. |
| `ImageGen/Imaging/` | Reads, shrinks and writes images. Makes and caches thumbnails. |
| `ImageGen/Export/` | Saves to Photos and Files, shares and copies. |
| `ImageGen/Security/` | Keeps the API key in the iOS Keychain. |
| `ImageGen/Support/` | The activity log and small shared tools. |
| `ImageGen/DebugSupport/` | A fake Gemini server and demo data for tests and the simulator. Release builds do not contain this code. |

### The life of a request

1. You tap Send. The composer gives the text and the attachments to `GenerationService`, and empties itself at once.
2. The service chooses the input image: your attachments, the pinned image, or the latest image in the chat. It records the request in the database.
3. The service writes the request body to a file. Each image goes into the body as base64, and the body is never held in memory as one block. If the body is too large, the service shrinks the images until it fits.
4. The service gives the body file to an iOS **background session**. The system sends the request and receives the response, also while the app is suspended.
5. When the response arrives, iOS wakes the app if necessary. The app reads the response, writes each image to its own file, and saves the reply.
6. If the app is not on screen, a notification says that the image is ready. A tap on it opens the chat.

If the service is busy or has a temporary error (HTTP 408, 429, 500, 502, 503 or 504), or the connection drops, the app tries again automatically, up to two times. If iOS stops the app during a request, the next launch finds the request and finishes it from the saved response, or marks it "Interrupted" with a Retry button.

### Concurrency

The app does many things at the same time. Swift 6 checks the code for data races when it compiles. The compiler cannot find logical races, for example two pieces of code that act on the same request with out-of-date information. The code prevents these with a small number of patterns, and the comments explain each one:

- **One handler at a time for each request.** A completion, a recovery at launch, a Retry and a Stop never work on one request at the same time.
- **Read, then check again.** Code that waits for slow work reads the state again before it changes anything.
- **A Stop is remembered.** A Stop also works when no network task exists yet.

`doc/SWIFT_PRIMER.md` explains these patterns and the Swift features behind them.

### Privacy and security

- The API key is in the iOS Keychain. It never goes into a URL, a file, the log, or the repository.
- The log is a file on the phone. Before the app writes a line, it removes anything that looks like a key, and all image data.
- Uploaded images lose their photo metadata (EXIF and GPS) before the app sends them.
- The app has no analytics and no third-party code. It talks only to the Gemini API.

## Build and run

### What you need

- A Mac with **Xcode 26** or later, and the iOS 26 simulator runtime.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later (`brew install xcodegen`). The Xcode project is generated from `project.yml`; it is not in the repository.
- For an install on a phone: an iPhone with **iOS 26**, and an Apple Developer Program team in Xcode.
- A Gemini API key from Google AI Studio, entered in the app. The build does not need one.

`scripts/doctor.sh` checks the Mac and tells you what is missing.

### Simulator

```bash
scripts/gen.sh
```

```bash
scripts/build.sh
```

```bash
scripts/run-sim.sh -UITestMockGemini 1 -SeedDemoData 1
```

The last command starts the app in **mock mode**. A fake Gemini server inside the app answers every request, so you need no key and no network. The scripts use a simulator named `ImageGen-Sim`; set `IMAGEGEN_SIM` to use another one.

### Tests and checks

```bash
scripts/test.sh
```

```bash
scripts/lint.sh
```

```bash
scripts/check-warnings.sh
```

`test.sh` runs the unit and integration tests (Swift Testing) on the simulator. `lint.sh` checks for banned patterns, for example a key in a URL, or code that decodes full-size images on the main thread. `check-warnings.sh` fails on any compiler warning.

An optional test calls the real API with your key. The script never shows the key:

```bash
TEST_RUNNER_GEMINI_API_KEY="$GEMINI_API_KEY" scripts/live-smoke.sh
```

### Install on an iPhone

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, and put your team ID in it (Xcode › Settings › Accounts). Git ignores this file.
2. On the iPhone, turn on Developer Mode: Settings › Privacy & Security › Developer Mode. Connect the phone with a cable and trust the Mac.
3. Unlock the phone and run:

```bash
scripts/device-install.sh --release
```

The script finds the phone, registers it with your team, builds, installs and starts the app. The first time, onboarding asks for your Gemini API key.

## Documentation

| Document | What it contains |
|---|---|
| [`doc/DESIGN.md`](doc/DESIGN.md) | The design: the behavior, the screens, the data model, the request pipeline, background work, the log, and the risks. This is the source of truth. |
| [`doc/IMPLEMENTATION_PLAN.md`](doc/IMPLEMENTATION_PLAN.md) | How the app was built, milestone by milestone (M0 to M10), with the tests and checks for each, and a change log. |
| [`doc/SWIFT_PRIMER.md`](doc/SWIFT_PRIMER.md) | The Swift and iOS concepts that the code uses, explained for an engineer who knows other languages. |

The source files have comments in the same style: an overview at the top of each file, and the reasons for each design decision where it is made.

## Status

Version 1 is complete. It passes 473 automated tests and a 30-step test script on an iPhone 17 Pro Max with iOS 26.6.

Some things are not in version 1 on purpose: camera capture, a share extension, iPad, sync between devices, and streaming replies. Each request carries only the chosen image and the newest instruction, not the earlier conversation. `doc/DESIGN.md` (section 1.3) lists all of them.

Claude Code agents wrote the app from the design and the plan. The owner reviewed each milestone.
