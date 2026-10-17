# Swift and iOS primer for this codebase

This document explains the Swift and iOS concepts that the ImageGen code uses. It is for a skilled engineer who knows other languages (C, Java, Go, Python, TypeScript) but not Swift. It explains each concept at the design level: what it guarantees and why this code uses it. It does not teach the full language.

The comments in the source files use the same terms. A file comment that says "See the primer, *Actors*" refers to a section here.

The writing follows the rules of simplified technical English: short sentences, one idea in each sentence, and the same word for the same thing.

## 1. How the code is organized

The app is a chat client for an image-generation web service (Google's Gemini API). The user types a prompt and can attach images. The app sends a request. The service returns text and images. The app stores the conversation on the device.

The code is in layers. A layer uses only the layers below it.

| Folder | Layer | What it does |
|---|---|---|
| `Features/` | Screens | The user interface: one folder for each screen, each with a *view* and a *model*. |
| `App/` | Assembly | Starts the app, builds every service once (`AppEnvironment`), and connects the operating system's events to the services. |
| `Pipeline/` | Generation | Prepares requests, sends them, retries them and saves the results (`GenerationService`). |
| `Networking/` | Transport | Sends requests with the operating system's background download service (`URLSessionTransport`). |
| `Gemini/` | Protocol | Builds request bodies and reads responses in the service's JSON format. |
| `Persistence/` | Storage | The database of chats (`DataStore`) and the files on disk (`FileStore`, `Janitor`). |
| `Imaging/` | Images | Reads, shrinks and writes image files; makes thumbnails. |
| `Export/` | Export | Saves images to the photo library, to files, or to the share sheet. |
| `Security/` | Secrets | Stores the API key in the Keychain (the operating system's secret store). |
| `Support/` | Shared tools | The activity log, formatting, layout helpers. |
| `DebugSupport/` | Test tools | A fake web service and demo data. This code is not in release builds. |

The design document, `doc/DESIGN.md`, is the source of truth. Comments refer to its sections as `D§4.6` (DESIGN section 4.6).

## 2. Types and values

**Struct and class.** A `struct` is a *value type*: an assignment copies it, and two variables never share one struct. A `class` is a *reference type*: an assignment copies a reference, and two variables can share one object. This code uses structs for data (a request snapshot, a settings record) and classes for objects with identity and a lifetime (a screen model, a network session).

**Enum with associated values.** An `enum` lists the possible cases of a value. A case can carry data. For example, `case failed(String)` is a failure that carries its reason. A `switch` must handle every case; the compiler checks this. The code uses enums for states (`RequestState`) and outcomes (`ParsedOutcome`).

**Optional.** A type followed by `?` (for example `UUID?`) can hold a value or `nil` (no value). The compiler does not let the code use the value before it checks for `nil`. `if let x` and `guard let x` check and unwrap in one step. `a ?? b` means "a, or b when a is nil".

**Protocol.** A `protocol` is an interface: a list of the functions and properties that a type must have. The code uses protocols at the boundaries between layers, so that a test can supply a fake (for example `GenerationTransport`, `APIKeyStore`).

**Extension.** An `extension` adds functions to an existing type, in another place or file. The code uses extensions to split a large type by topic (for example `ChatScreenModel+Attachments.swift`).

**Closure.** A closure is an anonymous function, written `{ x in ... }`. A closure can *capture* variables from the code around it. `[weak self]` captures the object weakly, so the closure does not keep the object alive. `@escaping` means the closure can run after the function that received it returns. `@Sendable` means the closure is safe to run in another concurrency domain (see section 4).

**Property wrapper and macro.** A word that starts with `@` before a declaration changes its behavior. Examples: `@State`, `@Observable`, `@Model`. The compiler generates the extra code. The sections below explain the ones this code uses.

## 3. Errors and early exits

**`throws`, `try`, `do`/`catch`.** A function marked `throws` can fail with an error. A call to it must be marked `try`. The error goes to the nearest `do { } catch { }` block, or up to the caller. This is like exceptions in Java, but every call that can fail is visible in the code.

**`try?`.** This converts an error into `nil` and continues. The code uses it only where a failure is harmless, and each use has a comment that says why (a project rule).

**`guard`.** `guard condition else { return }` exits early when the condition is false. After the `guard`, the code can assume the condition. Most functions here start with one or more `guard` lines.

**`defer`.** A `defer { }` block runs when the current scope exits, on every path (return, throw, or the end). The code uses it for clean-up that must always happen, for example to release a lock or to write a log result.

## 4. Concurrency

The app does many things at the same time: it draws the screen, waits for the network, writes files and decodes images. Swift's concurrency model makes most data races impossible: the compiler rejects code that could let two threads change the same data at the same time. **But the compiler cannot find logical races.** The comments in this code explain how each part avoids them.

### 4.1 `async` and `await`: suspension points

A function marked `async` can pause and let other work run, without blocking a thread. Each `await` marks a place where the function can pause. This place is a *suspension point*. When the awaited work completes, the function continues, possibly on another thread.

The important design rule: **at each `await`, other code can run and change shared state.** A value that the code read before an `await` can be out of date after it. Much of this code is shaped by that rule. The usual pattern is: read the state, do the slow work, then read the state again and check it before you write (see section 8).

### 4.2 Tasks and cancellation

A *task* is a unit of asynchronous work, like a lightweight thread.

- **Structured tasks** are children of the current task: `async let`, and task groups (`withTaskGroup`). The parent waits for all of its children before it returns.
- **Unstructured tasks** start with `Task { ... }` and run on their own. They keep the actor context of the code that created them (see 4.3). `Task.detached { ... }` starts one with no context, usually to move slow work off the main thread. The code that creates an unstructured task must keep a reference to it if it wants to cancel it or wait for it (`task.value`).

**Cancellation is cooperative.** `task.cancel()` only sets a flag. The task stops only where its code checks the flag: `Task.checkCancellation()` throws, `Task.isCancelled` reads it, and some system calls (for example `Task.sleep`) stop early. Code that does not check continues to run. This code checks before each step that costs time or money, for example just before it sends a request.

`@concurrent` on an `async` function makes it run away from the caller's actor, in the background.

### 4.3 Actors

An `actor` is an object that protects its own state. It runs **one call at a time**. Code outside the actor must `await` to call it. This is like an object with a lock around every method, without a thread that waits.

**Actor reentrancy.** An actor runs one call at a time *only between suspension points*. When a call reaches an `await`, the actor can start another call. When the first call continues, the actor's state may have changed. This is the most important concurrency fact for this codebase. `GenerationService` and `DataStore` are actors, and their comments explain how they handle reentrancy.

**The main actor.** `@MainActor` marks code that must run on the main thread. The main thread draws the user interface and handles touches. All screen models are `@MainActor`. Slow work on the main actor makes the interface stop, so the code moves slow work (image decoding, file scans) to other tasks.

`nonisolated` marks a member of an actor that does not touch the actor's protected state, so callers do not need to `await` it.

### 4.4 `Sendable`: what can cross between concurrency domains

A type is `Sendable` when it is safe to pass from one task or actor to another. Value types made of `Sendable` parts are `Sendable`. A class is `Sendable` only if its state cannot change, or if a lock protects it.

`@unchecked Sendable` tells the compiler: "trust me, this class is safe; I protect it myself." The compiler then does not check it. This code uses it only twice, and each use has a comment that says what protects the state. `nonisolated(unsafe)` is the same kind of promise for one variable.

### 4.5 Locks: `Mutex` and `Locked`

`Mutex` (from the `Synchronization` library) is a lock around a value. `withLock { }` runs the closure while the code holds the lock. `Locked` is this project's small class around a `Mutex`, so that closures can share it. The code uses locks for small, fast state that synchronous code must change, for example in network callbacks, which cannot `await`.

### 4.6 Continuations: connecting callbacks to `await`

Old APIs report results with a callback. `withCheckedContinuation { c in ... }` pauses the current task and gives a *continuation* `c`. Some other code later calls `c.resume()` (with a value if needed), and the paused task continues. A continuation must be resumed **exactly once**. Never resumed: the task waits forever. Resumed twice: the app stops with an error. The comments explain who resumes each continuation.

### 4.7 `AsyncStream`: an ordered queue of events

An `AsyncStream` is a queue. One side calls `continuation.yield(value)`. The other side reads with `for await value in stream`, one value at a time, in order. The network layer and the activity log each use one stream, so that events are handled in the order they happened. After `finish()`, the stream accepts nothing more.

## 5. SwiftUI: the user interface

**A view is a description.** A SwiftUI `View` is a struct with a `body` property. The `body` describes what to draw for the current state. SwiftUI calls `body` again when the state changes, compares the result with the previous one, and updates the screen. A view struct is cheap and short-lived. It is not the object on the screen.

**State that views read:**
- `@Observable` on a class makes SwiftUI record which properties a `body` reads. When one of these properties changes, SwiftUI calls that `body` again. The screen models in `Features/` are `@Observable` classes.
- `@State` stores a value that belongs to one view and survives when SwiftUI calls `body` again.
- `@Bindable` and `$value` give a two-way connection, for example between a text field and a model property.
- `@Environment` reads a shared object that an outer view provides, for example `AppEnvironment`.

**Lifecycle hooks:**
- `.task { }` starts asynchronous work when the view appears and cancels it when the view disappears. `.task(id:)` also restarts the work when the id changes.
- `.onAppear` and `.onDisappear` run when the view enters or leaves the screen. Some presentations (for example a full-screen cover) can trigger them.
- `.onChange(of:)` runs when a value changes. It does not run for the first value, unless `initial: true` is given.

**Presentation.** `.sheet`, `.alert`, `.confirmationDialog` and `.fullScreenCover` show a screen or a question when a bound value becomes true or non-nil. `NavigationStack` with a `path` array shows a stack of screens; changing the array pushes or pops screens.

## 6. SwiftData: the database

SwiftData stores Swift objects in a SQLite database.

- `@Model` on a class makes it a stored record (for example `Conversation`, `GenerationRequest`).
- The `ModelContainer` is the database. A `ModelContext` is a working area for reading and changing records; `save()` writes the changes.
- A record object belongs to one context, and a context belongs to one actor. **Records must not cross actors.** `DataStore` is a `ModelActor` (an actor with its own context). It never returns records. It returns *snapshots*: plain `Sendable` structs that copy the fields.
- Because `DataStore` is an actor and none of its methods awaits inside, each of its methods runs as one step. Other code cannot see a half-done change. The design depends on this, for example: a send moves its files and saves its record in one step.

## 7. iOS application lifecycle

**Scenes and phases.** The app's window is a *scene*. Its phase is `active` (in front, receives touches), `inactive` (in front, but covered, for example by Control Center), or `background` (not visible). The phase can change several times in a second.

**Background time.** When the app goes to the background, iOS suspends it after a few seconds. `beginBackgroundTask` asks for a little more time. iOS calls an *expiration handler* shortly before that time ends; the app must end the background task then, or iOS stops the app.

**Background `URLSession`.** A normal network request stops when iOS suspends the app. A *background session* gives the request to a system service, which continues it while the app is suspended or not running. When the request finishes, iOS can start the app again in the background to deliver the result (`handleEventsForBackgroundURLSession`). The app must call a completion handler when it has handled the results. The results can arrive before, during or after the app's own start-up work. Much of `Pipeline/` and `Networking/` exists to handle this correctly.

**Data protection.** Files and Keychain items are encrypted. This app's files are readable after the first unlock since the device started.

**Images.** `ImageIO` reads and writes image files without the full user-interface stack. `CGImage` is a decoded bitmap. An image file is often decoded *lazily*, the first time it is drawn; the code asks for an early decode, off the main thread, where that matters.

## 8. Patterns used in this project

**Snapshot, then check again.** Code reads a snapshot, awaits slow work, then reads the state again and checks it before it writes. Example: the Janitor re-checks a request before it deletes the request's folder.

**One handler at a time for each request.** `GenerationService.exclusive(_:)` lets only one piece of code work on one request at a time. Other code that wants the same request waits its turn. This prevents two handlers from acting on the same out-of-date reading.

**Claims with tokens.** A chat can have one request in progress. A new send *claims* the chat and receives a token. Only the holder of the token can release the claim.

**Remembered intent.** A Stop from the user is recorded, and the code checks the record just before it creates any network task. So a Stop also works when no task exists at that moment.

**The activity log.** Each user or system action is logged as a *Begin*, then optional *Steps*, then exactly one *Result*. A request is one action with sub-actions (Prepare request, Attempt, Parse). The log is a file the user can read in the app's Developer menu. Many comments say which code writes the Result on each path, because "exactly one Result" is a project rule.

**Seams for tests.** Services receive their dependencies in a `Dependencies` struct or as protocol values, so that tests can supply fakes, clocks and gates.
