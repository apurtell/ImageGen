# ImageGen for Mac, iPhone and iPad

Status: v1 design
Date: 2026-10-15

---

## 1. Purpose and scope

### 1.1 Purpose
ImageGen is a personal app for Mac, iPhone and iPad: a native Mac app (section 3.11), and one iOS app for iPhone and iPad (section 3.12 covers the iPad). It does what the OpenWebUI Gemini pipe does: you chat to generate and edit images through the Gemini REST API, using your own Gemini API key. A request carries only the selected image(s) and the latest instruction. Results arrive as images plus optional Markdown text, and stay in a list of saved chats on the device.

### 1.2 Goals (v1)
1. **Same results as the pipe.** Given the same inputs, the request body matches the pipe's except for the deliberate deviations in section 2.6.
2. **Gemini 3.1 Flash Image (`gemini-3.1-flash-image`) is the default model and always available.** Each chat can switch to other image models.
3. **Aspect ratio and resolution are configurable, with defaults of 16:9 and 2K.** Global defaults live in Settings. Each chat can override them from the composer. Every request records the values it used, so Regenerate reproduces them.
4. **Images can be attached from Photos, Files and the clipboard, and on the Mac and iPad by dropping them on the chat.** Several attachments per message are allowed. Uploads are downscaled to a long edge you set, and HEIC is converted to JPEG.
5. **"Edit from here".** You can pin any earlier image as the base for the next message.
6. **Requests survive the app going to the background.** On iOS they run on a background `URLSession`; the Mac app keeps running and holds off idle sleep for them (section 3.11). A local notification fires when one finishes while the app isn't active.
7. **Saved images are byte-for-byte what the API returned.** This applies to Photos, Files, Share and Copy.
8. **Saved chats.** Chats persist on the device (SwiftData plus image files) and can be reopened, renamed and deleted.
9. **Every step is logged, for debugging.** Before each action the app logs, in terse natural language, what it is about to do and every operative parameter; afterwards it logs the result. A Developer menu on the chat list and the chat screen (on iPad with a sidebar, beside the chat) shows the last action, the last error or the full log, and clears it. The log stays on the device and never holds the API key, headers or image data (sections 3.10, 4.13).

### 1.3 Non-goals (v1)
These were declined or deferred:
- Camera capture and a share extension.
- Thinking controls or displaying thoughts. `thinkingConfig` is never sent, and thought parts are always dropped.
- Google Search grounding.
- A usage, token or cost readout.
- Full-history (multi-turn) context. The app never sends earlier turns, so `thoughtSignature` handling isn't needed.
- Mac Catalyst, App Store or TestFlight distribution, iCloud sync, and widgets.
- Streaming and the Interactions API.
- The Files API. Everything goes inline, within the 20 MB budget.
- Batch generation, and asking for more than one output image.
- Editing a sent message in place (in its bubble). In-place editing is a possible future enhancement.

### 1.4 Platform and constraints
- **iOS app:** iOS and iPadOS 26.0 minimum, one universal target. On iPhone, supported interface orientation is restricted to portrait mode outside active full-screen media presentation, restoring transcript scroll position upon dismissal. On iPadOS, all interface orientations and resizable window configurations are supported (Section 3.12). In this document "iOS" covers both devices except where explicitly noted.
- **Mac app:** macOS 26.0 minimum, a native AppKit and SwiftUI target (not Catalyst).
- Built against the iOS 26+ (which includes iPadOS) and macOS 26+ SDKs with Xcode 26.x or later.
- Swift 6 language mode with complete strict concurrency, SwiftUI with Observation, SwiftData, and Liquid Glass.
- No third-party dependencies.
- Installed from Xcode with an Apple Developer Program team. The first install on an iPhone or iPad is a one-time Product › Run from Xcode; the provisioning profile lasts a year (see section 11, R9). The Mac app needs the same team for signing, because its keychain requires a signed build.
- Built and verified using XcodeGen and Swift Testing, on iPhone and iPad simulators and then the device, and on the Mac directly.

---

## 2. Matching the pipe's behavior

This section is the normative contract. Every rule is implemented in pure, unit-tested code: `InputSelector`, `RequestBodyWriter` and `ResponseParser`.

### 2.1 What the pipe does (summary)
- The pipe takes the text of the latest user message and the latest user message's **last** image. If there isn't one, it walks the earlier messages from newest to oldest and takes the **last** image of the first message that has any images. That can be an assistant output or a user upload.
- It sends a **single user turn**: `parts = [inlineData(image)?, text?]`. The image comes first. The text part is omitted when it's empty.
- It sends `generationConfig.responseModalities = ["TEXT","IMAGE"]`, with no `imageConfig` and no `thinkingConfig`.
- It sends `safetySettings` with one threshold applied to five categories: HARASSMENT, HATE_SPEECH, SEXUALLY_EXPLICIT, DANGEROUS_CONTENT and CIVIC_INTEGRITY. The default threshold is `BLOCK_NONE`.
- It sends `POST …/v1beta/models/{model}:generateContent?key=…` with a 300 s timeout and no retries.
- **Responses:** for a non-200 status it shows `Error {status}: {body}`. On success it renders `candidates[0].content.parts` in order: text as-is, `inlineData` as an embedded image (falling back to `image/jpeg` when no MIME type is given). With no parts it shows `"No content returned by the model."`. When the JSON lacks the expected keys, it shows the pretty-printed JSON.

### 2.2 Choosing input images (the `InputSelector`)
These inputs are evaluated when the user taps Send:
- `attachments`: the composer tray items in the `.ready` state, in tray order. Send can't be tapped while any tray item is still importing or preparing, or has failed (see "Send is enabled when" below), so at send time every tray item is ready and every attachment shown is sent.
- `pin`: `Conversation.pinnedImageID`
- `history`: the chat's messages, earlier than the new one

Rules, applied in order:
1. **Attachments.** If there is at least one, send **all** of them, in tray order. The reason is recorded as `.attachments`. The pin is cleared even though it wasn't used.
2. **Pin.** Otherwise, if a pin is set and its `ImageAsset` still exists, send that one image. The reason is `.pinned`, and the pin is cleared because it's one-shot.
3. **Most recent image.** Otherwise, walk `history` by descending `sequence`. Skip **model** messages whose request state is not `succeeded`: pending, failed, refused, cancelled and interrupted replies carry no images anyway, and skipping them keeps the rule explicit. User messages are always eligible, whatever happened to their reply, as in the pipe (where an error reply has no image, so the walk reaches the user's upload). In the first message with at least one `ImageAsset`, take the image with the **highest `ordinal`**. Because `ordinal` follows response-part order for model messages and tray order for user messages (section 4.3), this is the last image in that message, the same image as the pipe's `images[-1]`. User and model messages count the same. Image parts that failed to decode were never stored (section 2.7), so they are never candidates. The reason is `.latest`.
4. **None.** Otherwise, send no image. The reason is `.noImage`, stored as `"none"` (text-to-image). This happens only when the chat holds no image yet, which in practice is the first turn of a new chat.

At every turn, either new attachments, the pinned image or the latest image in the chat is sent along with that turn's text; to generate from text only, start a new chat. This is the pipe's behavior. When rule 3 applies, the composer shows an "Editing latest image" chip (section 3.5). The chip is purely informational: it shows which image will be sent and can't be dismissed.

**Send is enabled when all of these hold:**
- no tray item is still importing or preparing (the composer shows "Preparing images…" next to the disabled Send button);
- no tray item has failed. A failed item shows ⚠︎ with its reason, and Send stays disabled until the user removes it, so an attachment is never dropped silently;
- the trimmed text is non-empty, or there is at least one ready attachment; and
- the chat has no request in flight.

Sending an image with no text is allowed only from attachments, which matches the pipe's "image without text" case. Sending only the reused previous image with no text is not allowed.

The request body never has an empty `parts` list. `RequestBodyWriter` throws `emptyParts` if it gets no images and no text, which mirrors the pipe's "Could not extract any content from the conversation" error. The Send rules above make this unreachable from the UI.

### 2.3 Extracting the text
- `promptText` is the composer text, trimmed of leading and trailing whitespace and newlines. Inner newlines are kept.
- When `promptText` is empty, there is no text part.

### 2.4 Request construction (the `RequestBodyWriter`)
- **Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/models/{modelID}:generateContent`
- **Headers:**
  - `Content-Type: application/json`
  - `Accept: application/json`
  - `x-goog-api-key: <key>`
  - The key is **never** put in a query parameter.

Body (camelCase; shown in a readable key order). Key order has no meaning to the API. The writer encodes with `.sortedKeys` so the bytes are deterministic, and golden tests compare structurally. Array order (parts, safety categories) is significant and is kept:

```json
{
  "contents": [{
    "role": "user",
    "parts": [
      {"inlineData": {"mimeType": "image/jpeg", "data": "<base64 #1>"}},
      {"inlineData": {"mimeType": "image/png",  "data": "<base64 #2>"}},
      {"text": "<promptText>"}
    ]
  }],
  "generationConfig": {
    "responseModalities": ["TEXT", "IMAGE"],
    "imageConfig": {"aspectRatio": "16:9", "imageSize": "2K"}
  },
  "safetySettings": [
    {"category": "HARM_CATEGORY_HARASSMENT",        "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_HATE_SPEECH",       "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"},
    {"category": "HARM_CATEGORY_CIVIC_INTEGRITY",   "threshold": "BLOCK_NONE"}
  ]
}
```

**Parts**
- Images come first, in selection order, and the text comes last. This matches the pipe's image-then-text order.
- `mimeType` is the type of the bytes actually sent (section 4.8).

**`responseModalities`**
- Default `["TEXT","IMAGE"]`, matching the pipe. The live smoke test settled R3 on 2026-10-16: 2K is honored with TEXT+IMAGE, so the default stays (section 11).
- Advanced setting "Request text alongside images" (`includeTextModality`, default on). Turning it off sends `["IMAGE"]`.
- **R3 decision (user, 2026-10-16):** if the live smoke test confirms that `["TEXT","IMAGE"]` caps output at 1K, the default switches to `["IMAGE"]` (the setting's default becomes off). The Advanced toggle still lets the user turn text back on. Until that's confirmed, the default stays `["TEXT","IMAGE"]`.

**`imageConfig`**
- Always sent for models whose capability says they support it.
- The `imageSize` key is left out for models without size support (section 2.5).
- Values are exact API strings: `"512"`, `"1K"`, `"2K"`, `"4K"` (uppercase K; 512 is sent as the bare string `"512"`, never `"512px"` or `"0.5K"`).

**Not sent:** `thinkingConfig` (matches the pipe; thinking level is documented as controllable only for 2.1, 3.1 Flash and 3.1 Flash Lite, and Flash defaults to `minimal`), `candidateCount`, `tools` and `systemInstruction`.

**`safetySettings`**
- The five categories above, all at the global threshold.
- `HARM_CATEGORY_CIVIC_INTEGRITY` is deprecated in the API enum. It's kept for parity, with an automatic fallback:
  1. If a request fails with 400 `INVALID_ARGUMENT` and the message mentions `CIVIC_INTEGRITY`, rebuild the body without it and retry once.
  2. Persist the `omitCivicIntegrity = true` flag through `AppSettings` on the main actor (section 5), so the next send from an already-open chat resolves four categories at once.
  3. Record the categories actually sent on the request, and set `civicFallbackUsed` on it.

**Thresholds:** `BLOCK_NONE` (default), `BLOCK_ONLY_HIGH`, `BLOCK_MEDIUM_AND_ABOVE`, `BLOCK_LOW_AND_ABOVE`. These are the pipe's set; `OFF` isn't offered.

**How the body is written.** The body is streamed to a file (`Requests/<id>/body.json`):
1. The JSON envelope and the text are encoded with `JSONEncoder` (correct escaping).
2. The image bytes are base64-encoded in 48 KiB chunks (a multiple of 3), straight from the prepared files.

No full-body `String` or `Data` is ever built in memory. The exact body size is computed before writing: envelope bytes plus `4*ceil(n/3)` per image.

### 2.5 Models, capabilities and coercion
`ModelCatalog` defines static metadata for supported Gemini image generation endpoints. Every catalog model is enabled by default and presented in the per-conversation model selector, filtered dynamically by capabilities returned from `models.list`. Settings allows hiding optional catalog models and configuring custom model identifiers (Section 11, Q1).

- **Gemini 3.1 Flash Image (`gemini-3.1-flash-image`)**: Default mandatory model, always enabled and cannot be removed. Supports all 14 aspect ratios, dimensions 512, 1K, 2K, and 4K, and up to 10 objects / 4 high-fidelity character inputs.
- **Gemini 3 Pro Image (`gemini-3-pro-image`)**: Optional high-fidelity model, enabled by default when available. Supports 10 standard aspect ratios (excluding 1:4, 4:1, 1:8, and 8:1), dimensions 1K, 2K, and 4K, and up to 5-6 high-fidelity character inputs. Replaces legacy preview endpoints.
- **Gemini Nano Banana 2.1 (`gemini-nano-banana-2.1`)**: Optional recommended model, enabled by default when available. Supports all 14 aspect ratios, dimensions 1K, 2K, and 4K, and up to 10 objects / 4 character inputs.
- **Gemini 3.1 Flash Lite Image (`gemini-3.1-flash-lite-image`)**: Optional lightweight model, enabled by default when available. Supports 10 standard aspect ratios with output constrained to 1K resolution.
- **Gemini 2.5 Flash Image (`gemini-2.5-flash-image`)**: Optional legacy model, enabled by default when available. Supports 10 standard aspect ratios with fixed output resolution per ratio (approximately 1 MP), omitting the `imageSize` configuration parameter.
- **Gemini 3 Pro Image Preview (`gemini-3-pro-image-preview`)**: Legacy alias offered in model selection only when explicitly enumerated by `models.list`. Inherits Gemini 3 Pro capabilities.
- **Custom Model Identifiers**: User-configured model endpoints. Defaults to all 14 aspect ratios and 1K, 2K, and 4K dimensions, with uncoerced API error presentation for unsupported parameters.

- **All 14 aspect ratios:** 1:1, 1:4, 4:1, 1:8, 8:1, 2:3, 3:2, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9. **The 10 standard ratios** are the same without 1:4, 4:1, 1:8 and 8:1.
- **High-fidelity soft limit** (`ModelCapability.highFidelityInputLimit`, one number per model, used only for the soft tray warning in section 4.8): Flash 10, 2.1 10, 3 Pro and its preview alias 5 (the lower of the two documented values), 2.5 Flash Image 3. Flash Lite and custom IDs have no soft limit (the value is 14, the hard cap), so no warning appears.
- **Effective settings** for a request are resolved by `GenerationSettingsResolver`, in this order:
  1. Model: `conversation.modelIDOverride` if that model is still enabled in Settings › Models (a catalog model whose toggle is on, or a custom ID that hasn't been removed); otherwise the default model (Flash). An override that falls back this way is reported as a coercion: the Model pill shows "3.1 Flash" with the caution glyph, and the request records Flash. The override itself is kept, so turning the model back on restores it. Flash can't be disabled, so the fallback always exists.
  2. Aspect ratio: `conversation.aspectRatioOverride`, or `settings.defaultAspectRatio` (default `16:9`, landscape widescreen).
  3. Size: `conversation.imageSizeOverride`, or `settings.defaultImageSize` (default `2K`).
  4. Coerce to the model's capability:
     - aspect ratio not supported: use `16:9` if supported, else `1:1`;
     - size not supported: use the nearest supported size, preferring the larger (512 becomes 1K; for a 1K-only model everything becomes 1K);
     - model without `imageSize` support: leave the key out.
  5. When coercion changes a value (the model, aspect ratio or size), the composer pill shows it with a caution glyph, and the request records the coerced value.
- **Runtime validation (`ModelAvailabilityService`):**
  - Calls `GET /v1beta/models?pageSize=1000` with the header key, and follows `nextPageToken` if one is returned.
  - Runs when the key is saved, on foreground at most once every 24 h, and when you pull to refresh in the Settings › Models screen.
  - Caches `{id: supportsGenerateContent}` and a timestamp.
  - The per-chat model menu offers every model that is enabled in Settings and that the key can use. A model that isn't listed is labeled "Not listed for this key" in Settings › Models and left out of the model menu. Before the first successful check (availability "Unknown — not checked"), enabled models are offered, except the legacy preview alias, which needs a listing (it's offered only once `models.list` returns it). Flash stays selectable even if unlisted, with a warning banner, because listing can lag.
  - The catalog IDs other than Flash haven't all been confirmed against a real key. They stay validated at runtime: by this `models.list` filter, and by the 404 handling below.
  - A 404 at request time is reported as "Model not found or retired" with a button that opens Settings › Models.

### 2.6 Deliberate deviations from the reference pipeline

The native application intentionally deviates from the reference OpenWebUI pipeline to enhance security, reliability, and native UX capabilities:

- **Authentication**: API credentials are transmitted via the `x-goog-api-key` HTTP header rather than query string parameters (`?key=`), ensuring credentials are never exposed in URLs, proxy logs, or diagnostic traces.
- **Image Configuration**: The application explicitly sends `imageConfig` parameters specifying desired aspect ratio (default 16:9) and output resolution (default 2K), rather than relying on server-side defaults.
- **Attachment Sequencing**: All composer attachments are transmitted in ordinal sequence rather than restricting input to the final image of the preceding turn.
- **Edit Baseline Precedence**: Pinned images take precedence over the most recent conversation output when establishing the image-to-image base canvas.
- **Response Modalities**: Configured by default to `["TEXT", "IMAGE"]`, with fallback capability to `["IMAGE"]` if intermediate text generation imposes resolution caps.
- **Pro Model Target**: Routes Pro requests to `gemini-3-pro-image`, reserving `gemini-3-pro-image-preview` strictly as a conditional legacy alias.
- **Transport Architecture**: Employs background `URLSession` transfers with 300-second idle timeouts and automated retry policies for transient faults, replacing synchronous HTTP executions.
- **Safety Category Compatibility**: Transmits `CIVIC_INTEGRITY` safety settings with automatic single-request fallback omitting the category if rejected by the API.
- **Structured Error Handling**: Presents native error card interfaces with actionable remediation controls (Retry, Edit, New Chat), retaining raw redacted JSON diagnostics within inspection sheets.
- **Safety Refusals**: Surfaces concise refusal reasons directly on the response card while preserving detailed finish messages and sanitized payloads within inspector views.
- **Thought Modality Filtering**: Drops internal thought tokens and interim thought visualizations, restricting presentation strictly to completed text and image assets.
- **Client-Side Image Sanitization**: Preprocesses imported user images prior to upload (stripping EXIF/GPS metadata, normalizing HEIC to JPEG, and constraining dimensions within maximum budget bounds), while reusing existing model outputs byte-for-byte.
- **Whitespace Normalization**: Preserves text segments verbatim while trimming leading and trailing whitespace at segment boundaries.
- **Corrupt Part Recovery**: Drops unparseable image byte blocks with user notifications, preserving prior valid assets as edit baselines.
- **HTTP Status Acceptance**: Evaluates any 2xx response status as successful transport completion.

### 2.7 Parsing responses (the `ResponseParser`)
**Inputs:** the HTTP status and the response body file. **Output:** a `ParsedOutcome` (Sendable):
- `.success(parts: [OutputPart], finishReason, notices, modelVersion, responseId)`, where `OutputPart` is `.text(String)` or `.image(StoredOutputImage)`. `StoredOutputImage` is `{fileURL, mimeType, byteCount, pixelWidth, pixelHeight}`: the parser writes each decoded image straight to the directory the caller passes in, which is always `Requests/<requestID>/out-<attempt>/` (section 4.4), and `GenerationService` moves the files into `Images/<conv>/` (see Memory below). No image `Data` is held in the outcome. `notices` are short user-facing strings (for example "1 image could not be decoded"); they're stored on the request (`noticesData`, section 4.3) so they survive a relaunch.
- `.refused(reason, message?, notices, details)`: a safety or policy refusal. `reason` is the API's string, verbatim, and is stored as `GenerationRequest.refusalReason`; `message` is `finishMessage` when present, and is stored as `GenerationRequest.errorMessage` (section 4.3), which the reply's Info sheet shows as "Message: …" (section 3.6). It never appears on the card.
- `.empty(finishReason?, details)`
- `.apiError(httpStatus, status?, message, details)`
- `.malformed(details)`

Rules, in order:
1. **Status not in 200…299.** Try to decode `{"error":{"code","message","status","details"}}`.
   - The result is `.apiError`.
   - If the body isn't that JSON, the message is the first 2 KB of the body as UTF-8, matching the pipe's `Error {status}: {text}`.
   - `details` holds the full body, truncated to 64 KB.
2. **The body isn't valid JSON, or doesn't decode as a response.** The result is `.malformed`, with the first 64 KB of the body.
3. **`promptFeedback.blockReason` is set** (for example `SAFETY`, `OTHER`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `IMAGE_SAFETY`). The result is `.refused(reason: blockReason)`.
4. **`candidates` is missing or empty.** The result is `.empty(nil)`.
5. **Otherwise, take `c = candidates[0]`** (the pipe uses only the first candidate) and filter `c.content?.parts` to drop every part where `thought == true`. For each remaining part, in order:
   - `text` parts: consecutive text parts are concatenated **verbatim, with no separator**, into one text run, as the pipe does. A run ends at an image part or at the end of the parts. Each run is trimmed of leading and trailing whitespace at its two ends only, and a run that is empty after trimming is dropped. Text inside a run is never changed, so a sentence, list or code fence that Gemini splits across parts comes back intact. Each remaining run becomes one `.text`.
   - `inlineData` becomes `.image`. Use `Data(base64Encoded:options:.ignoreUnknownCharacters)`. The MIME type is `inlineData.mimeType`, defaulting to `image/jpeg` as the pipe does. If the bytes don't decode as an image (`CGImageSourceGetCount == 0`), drop the part and add a "1 image could not be decoded" notice. This is a deliberate deviation (section 2.6): the bytes are never stored, so the latest-image rule (§2.2 rule 3) never picks them.
   - Other part kinds are ignored.
6. **Refused candidate.** If no `.image` survived step 5, and `c.finishReason` is present and is **not** one of {`STOP`, `MAX_TOKENS`, `FINISH_REASON_UNSPECIFIED`}, the result is `.refused(reason: finishReason, message: finishMessage)`.
   - This explicitly includes `IMAGE_SAFETY`, `IMAGE_PROHIBITED_CONTENT`, `IMAGE_OTHER`, `IMAGE_RECITATION`, `PROHIBITED_CONTENT`, `SAFETY`, `BLOCKLIST`, `SPII`, `RECITATION`, `NO_IMAGE`, `OTHER`, `ESCALATION` and `PUP_LIMITED_DISABLED`.
   - It is forward-compatible: any finish reason the app doesn't recognize is a refusal too, and its string is shown verbatim.
   - The boundary is the surviving image: a candidate with at least one decodable image is `.success` whatever its finish reason (rule 8, for example "Finished: IMAGE_SAFETY" as a footnote), while a candidate whose only image parts were undecodable and dropped in step 5 is `.refused` when its finish reason is a refusing one (the "could not be decoded" notice is kept).
   - It applies even when the candidate carried text parts. Those text runs are **not** shown in the turn and don't become reply parts; they stay in the request record (in `details`, the redacted response JSON) and are shown under Details in the reply's Info sheet.
   - `PUP_LIMITED_DISABLED` means the API account itself is limited or disabled for Prohibited Use Policy violations. It is still `.refused` and titled like every refusal, but its card has no Retry and a one-line note that retrying won't help (section 3.4).
7. **No parts left** (and not refused: the finish reason is `STOP`, `MAX_TOKENS`, `FINISH_REASON_UNSPECIFIED` or missing). The result is `.empty(finishReason)`, shown as "No content returned by the model." plus the raw reason.
8. **At least one part.** The result is `.success`. If `finishReason` is anything other than `STOP`, or is missing, it's shown as a footnote (for example "Finished: MAX_TOKENS"). A text-only success, with no image, is possible only when the finish reason is `STOP`, `MAX_TOKENS`, `FINISH_REASON_UNSPECIFIED` or missing (any other reason is rule 6); it gets a "No image returned" badge. The badge isn't stored as a flag: the UI derives it from the stored reply (state `succeeded` and no image parts in `partsData`), so it survives a relaunch.

Refusals are never retried automatically: no `RetryPolicy` retry and no CIVIC fallback is triggered by a refusal (section 6). Retrying is the user's choice, from the card.

**Details text.** For every terminal outcome the parser makes a **redacted** pretty-printed JSON copy of the response:
- Every `inlineData.data` is replaced with `"<N bytes image/jpeg>"`, and every `thoughtSignature` with `"<redacted>"`.
- It's stored on the request (capped at 64 KB) and shown under "Details" in the error card and in the reply's info sheet (for a refusal, only in the info sheet, section 3.4).

This is the native counterpart of the pipe's JSON dump.

**Memory.** The parser decodes from a memory-mapped body (`Data(contentsOf:options:.mappedIfSafe)`) with `Decodable` structs where `inlineData.data` is a `String`. It decodes each image and writes it at once to the output directory the caller passed in (`Requests/<id>/out-<attempt>/`, on the same volume, so `GenerationService`'s move into `Images/<conv>/` is a rename), then releases it. The Janitor never touches the request folder of a non-terminal request (section 4.4), so these files are safe until they're moved and saved. Nothing keeps the base64 strings or decoded bytes after parsing.

---

## 3. UX spec

### 3.1 Structure
- `NavigationStack` at the root:
  - the chat list is the root view;
  - `navigationDestination(for: Conversation.ID.self)` opens a chat;
  - Settings is a sheet;
  - the image viewer is a `fullScreenCover`.
- Standard bars get Liquid Glass automatically. Custom glass is used only in the composer and on viewer controls, never on message content.
- Dark mode, Dynamic Type (up to accessibility sizes, with the composer pills wrapping) and VoiceOver labels are supported for every icon button.

### 3.2 Onboarding and API key
This screen appears when the Keychain has no key, at first launch or after the key is removed.
- Title "Connect Gemini". A short explanation. The text "Get a key at aistudio.google.com/apikey", shown as selectable text, not a web view.
- A `SecureField` with a paste-friendly reveal toggle, and a **Validate and Save** button (`.glassProminent`).
- Validation calls `GET /v1beta/models?pageSize=1000` with the header key over an ephemeral session, with a 20 s timeout:
  - **Successful Verification (HTTP 200)**: The API key is committed to the Keychain, model availability metadata is cached, and navigation transitions to the conversation list. If `gemini-3.1-flash-image` is absent or unverified for `generateContent`, the interface presents a non-blocking diagnostic notice regarding potential generation failures.
  - **Authentication Failure (HTTP 400 with `API_KEY_INVALID`, 401, or 403)**: Key registration is rejected, presenting an error message containing the API diagnostic description. The credential is not saved.
  - **Transport Failure or Server Error (HTTP 5xx or Network Fault)**: The interface displays a connection failure alert offering options to retry validation or save the credential without verification.

- The key is never displayed after saving. Settings shows only its last 4 characters.

### 3.3 Chat list
- The large title is "Chats".
- **Toolbar:** a Settings button (`gearshape`, leading); trailing, the Developer menu (`hammer`, section 3.10) and then the New Chat button (`square.and.pencil`, primary), so New Chat stays the trailing-most item. New Chat creates an empty conversation and pushes it onto the stack.
- **New Chat row:** the first row is not a chat. It shows a tinted `square.and.pencil` square where a chat's thumbnail would be and "New Chat" in the title's place, and a tap does exactly what the toolbar's New Chat button does. It has no swipe actions and no long-press rename. It isn't shown in the empty state, which has its own New Chat button.
- **Chat rows**, below it, sorted by `updatedAt` descending:
  - a 44 pt rounded thumbnail of the chat's latest image, or a placeholder glyph;
  - the title (one line);
  - a subtitle with the last prompt snippet (one line, secondary);
  - a relative timestamp;
  - an activity indicator when the chat has a request in flight, and a red dot when its latest request is `failed` or `refused` (both need the user's attention; `cancelled`, `interrupted`, `empty` and succeeded requests get no dot).
- **Swipe actions:** trailing **Delete** (destructive, with a confirmation alert: "Delete chat and its N images?", or "Delete this chat?" when it has none) and leading **Rename**, which edits the title in place in the row.
- **Long-press a row** to edit its title in place (no context menu; a tap still opens the chat). Delete is on the trailing swipe only.
- **Rename in place:** the row's title becomes a focused text field with its text selected, plus ✕ and ✓. Return or ✓ saves; ✕ or moving focus away cancels; an unchanged name does nothing. An empty name reverts to the automatic title (`titleIsUserSet = false`), as it does in the Rename alert (section 3.4).
- **Automatic title:** the first 48 characters of the first prompt, trimmed at a word boundary. "New Chat" until the first send.
- **Empty state:** a `ContentUnavailableView` reading "No chats yet", with a New Chat button.
- Empty conversations (no messages) are deleted automatically when you leave them.

### 3.4 Chat screen
**Navigation bar**
- The inline title is the chat title. Tapping it opens the Rename alert; long-pressing it edits the title in place in the navigation bar (a glass capsule with the text selected, ✕ and ✓; Return or ✓ saves, ✕ or moving focus away cancels).
- Trailing: the Developer menu (`hammer`, section 3.10), then the existing chat menu, which offers Rename, "Chat settings…" (the model, aspect and resolution overrides, the same as the pills) and Delete chat.

**Transcript**
- A `ScrollView` with a `TranscriptStack`, a bottom scroll anchor for the initial position, and `.scrollDismissesKeyboard(.interactively)`. The stack is a `LazyVStack` on iPhone. On the Mac and in an iPad split it's a `VStack`, because rows there change height with the window (section 3.11).
- The view moves on its own only to follow the end of the transcript: a new last message, or the last rows growing while the bottom edge is in view. A row retried further up grows in place, the rows above it stay still, and it never pulls the view to the bottom. Height changes keep the bottom edge still only while following; otherwise they keep the top of the visible rows still.
- On open and on a new message, it scrolls to the bottom. A "jump to latest" glass button appears when you're scrolled more than one screen up.

**User message**
- A right-aligned bubble tinted with the accent color.
- Attachments appear above the text as a grid: one image at full bubble width; two to four in a 2-column grid; five or more in a 3-column grid. Each thumbnail keeps its stored aspect ratio.
- When the input came from the pin or the latest image rather than attachments, a small secondary caption under the bubble says "Edited from pinned image" or "Edited latest image", with a 20 pt thumbnail.

**Model reply**
- Left-aligned, with no bubble background.
- Parts render in the order returned:
  - images at full content width, with a 12 pt corner radius and placeholder frames sized from the stored pixel dimensions, so layout doesn't jump;
  - text as rendered Markdown (section 4.12).
- Under the reply, a metadata line in caption style, secondary color: `3.1 Flash · 16:9 · 2K · 2752×1536`.
  - The requested values come from the request record. The pixel size is the actual size of the first output image.
  - **Size check (R3).** The size class is judged by **pixel count**, not the long edge, because extreme ratios have long edges outside the usual range (1:8 at 1K is 384×3072). The nominal sizes are 512 ≈ 0.26 MP, 1K ≈ 1.05 MP, 2K ≈ 4.2 MP and 4K ≈ 16.8 MP. If the actual megapixels are more than a factor of 1.5 away from the requested class, it shows a ⚠︎ marker naming the nearest class, for example "returned 1K".
  - **Aspect check (R4).** If the actual width/height differs from the requested ratio by more than 3%, it shows a ⚠︎ "returned 1:1"-style marker, naming the nearest of the 14 ratios.
  - This is how the app checks reports R3 and R4.
- Regenerated replies show a header: "↻ Regenerated · “prompt snippet…”".

**Pending reply**
- A placeholder card shaped to the requested aspect ratio, with a subtle shimmer, and the label "Generating… 0:23". The shimmer is a Core Animation gradient that runs in the render server (`ShimmerAnimation`, `ShimmerBand`), so the app does nothing per frame and the card's frame has no part in it. A gradient layer works in its unit square and is stretched to the card, so the ends are worked out from the card's shape, which keeps the band at right angles to the line from its top to its bottom on any card. Elapsed time comes from a one-second `TimelineView(.periodic)` and `request.startedAt`.
- The label under the timer depends on the state:
  - `preparing`: "Preparing images…";
  - `inFlight` or `retryScheduled` while `ConnectivityMonitor` reports no usable network path and the app is in the foreground: "Waiting for network" (section 4.6; the background session itself waits silently);
  - `retryScheduled` with a retry created in the foreground: "Retrying in 2 s (attempt 2/3)", a countdown to `nextAttemptAt`;
  - `retryScheduled` with a retry created while the app was in the background: "Retry scheduled (attempt 2/3)", with no countdown, because iOS may defer such a task (section 6, Retry policy);
  - `inFlight` and `parsing`: no extra label.
  - The attempt counter is `autoRetriesUsed + 1` of `maxAutoRetries + 1`.
- A **Cancel** button.

**Failed, refused, empty, cancelled or interrupted reply**
- An inset card with an SF Symbol, a title, a one-line message (where the table gives one) and the buttons from the table below. **Retry** is a new attempt of the same request (section 6, Regenerate vs Retry). **Details** opens a sheet with monospaced, selectable redacted JSON or the error body, and a Copy button. Regenerate, Info and Delete are always in the reply's long-press menu (section 3.6), not on the card.
- Card presentation specifications define glyph symbols, primary titles, explanatory text, and action buttons for terminal request outcomes, verified by `ReplyPresentationTests`:

- **Safety and Content Refusals**:
  - *Standard Refusal*: Icon `hand.raised`, title `Request refused: <reason>` (e.g. `IMAGE_OTHER`), no message text. Actions: **Retry**, **Edit**, and **New Chat**. If the originating user prompt was deleted, the **Edit** action is omitted.
  - *Account Limitation (`PUP_LIMITED_DISABLED`)*: Icon `hand.raised`, title `Request refused: PUP_LIMITED_DISABLED`, message `This API account is limited by Google; retrying won't help.` Actions: **Edit** and **New Chat** (or **New Chat** only if the prompt was deleted); Retry is suppressed.
- **Empty Response**: Icon `photo.badge.exclamationmark`, title `No content returned by the model.`, message `Finished: <finishReason>`. Actions: **Retry** and **Details**.
- **Credential Errors**:
  - *No Key*: Icon `key`, title `No API key`, message `Add a key in Settings.` Actions: **Settings**.
  - *Rejected Key*: Icon `key`, title `Key rejected (<code> <STATUS>)`, displaying server error payload. Actions: **Settings** and **Details**.
- **Configuration and Policy Errors**:
  - *Invalid Arguments or Billing / Regional Restrictions*: Icon `exclamationmark.triangle`, title `Error <code> <STATUS>`, displaying API diagnostic message (and sent dimensions for configuration errors). Actions: **Details**.
  - *Credit Depletion*: Icon `creditcard`, title `Out of credits`, displaying provider message. Actions: **Details**.
  - *Model Not Found*: Icon `questionmark.circle`, title `Model not found or retired: <modelID>`. Actions: **Open Models** and **Details**.
- **Network and Transport Errors**:
  - *Rate Limit or Upstream Service Faults*: Icon `exclamationmark.triangle`, title `Error <code> <STATUS>` (e.g. `Error 429 RESOURCE_EXHAUSTED`). Actions: **Retry** and **Details**.
  - *Timeouts*: Icon `clock.badge.exclamationmark`, title `Timed out`, message `No response within <n> min.` Actions: **Retry** and **Details**.
  - *Network Failures*: Icon `wifi.exclamationmark`, title `Network error`, displaying URLError code name. Actions: **Retry** and **Details**.
  - *Unexpected Response*: Icon `doc.questionmark`, title `Unexpected response`, message `The server didn't return a Gemini response.` Actions: **Retry** and **Details**.
- **Resource and System Errors**:
  - *Payload Capacity Exceeded*: Icon `photo.stack`, title `Images too large to send together (<N> MB)`, message `Remove some or lower the max size in Settings.` No action buttons.
  - *Storage Full*: Icon `externaldrive.badge.exclamationmark`, title `Not enough storage to save the result`, message `Free some space, then retry.` Actions: **Retry**.
  - *User Cancellation*: Icon `stop.circle`, title `Cancelled`. Actions: **Retry**.
  - *Process Interruption*: Icon `bolt.horizontal.circle`, title `Interrupted: the app was closed before the result arrived`, message explaining system termination. Actions: **Retry**.

**Refused replies** (Section 2.7 rules 3 and 6). The card presents "Request refused: <reason>" with the exact API reason string. Detailed diagnostic text and finish messages reside under Details within the Info inspector sheet (Section 3.6). Primary remediation actions include:
- **Retry**: Re-executes the recorded request with identical parameters in place (Section 6). Because content moderation thresholds can exhibit transient variance, immediate re-execution without parameter mutation is supported. Refusals are never retried automatically.
- **Edit**: Invokes Edit and Resend (Section 3.6) for the originating user message, restoring prompt text into the composer, cloning attachments, and restoring baseline image pins. The action is hidden if the prompt message has been removed.
- **New Chat**: Initializes an empty conversation and updates navigation state, preserving the refused turn in historical conversation records.

A refused reply has no images, so the latest-image rule skips it (section 2.2 rule 3).

### 3.5 Composer
The composer sits at the bottom in `.safeAreaBar(edge: .bottom)`, inside a `GlassEffectContainer`. From top to bottom:

1. **Context chips** (conditional, single row):
   - Pin chip: `[thumb] Editing from pinned image ✕`. ✕ unpins, so the send falls back to the latest image (rule 3). When attachments are present, it dims and reads "Pinned image replaced by attachments".
   - Implicit base chip (when rule 3 would apply): `[thumb] Editing latest image`. It's informational only, with no ✕: it shows which image will be sent and can't be dismissed. Text-only generation needs a new chat (section 2.2).
2. **Attachment tray** (conditional): a horizontal scroll of 56 pt thumbnails.
   - Each has ✕, a spinner while importing or preparing, a ⚠︎ on failure (tap to see why, with a Remove button), and a long-press menu to reorder (Move Left, Move Right) or Remove.
   - While any item is importing or preparing, or has failed, Send is disabled (section 2.2). The caption then reads "Preparing images…" or "Remove the image that couldn't be prepared".
   - The trailing caption otherwise shows the count and the budget, for example "3 images · 6.1 MB of 19 MB". Above the model's high-fidelity soft limit (section 2.5) it adds "Best results with up to N images on <model>".
3. **Settings pills** (one row of compact glass capsules, each a `Menu`):
   - **Model** ("3.1 Flash ▾"): every enabled model the key can use (all catalog models by default); models `models.list` doesn't list are left out (section 2.5).
   - **Aspect** ("16:9 ▾"): grouped sections:
     - Landscape: 16:9, 21:9, 3:2, 4:3, 5:4
     - Square: 1:1
     - Portrait: 9:16, 2:3, 3:4, 4:5
     - Extreme: 4:1, 8:1, 1:4, 1:8
     Ratios the model doesn't support are hidden. The first item is "Default (<value>)", where `<value>` is the **current** `settings.defaultAspectRatio`: "Default (16:9)" out of the box, "Default (1:1)" after the global default is changed to 1:1. If the current model doesn't support the default, the item shows the coerced value with the caution glyph, for example "Default (16:9 ⚠︎)".
   - **Resolution** ("2K ▾"): 512 px, 1K (~1 MP), 2K (~4 MP), 4K (~16 MP), filtered by the model. The first item is "Default (<value>)" from the current `settings.defaultImageSize`: "Default (2K)" out of the box, with the same coerced-value rule.
   - A pill showing a per-chat override has a small accent dot. Choosing "Default" clears the override.
   - Changes persist on the `Conversation` right away and affect only future sends.
4. **Input row:**
   - a **+** `Menu` with "Photo Library" (PhotosPicker) and "Files" (fileImporter). When the tray already holds 14 items, both items are disabled and the menu shows the hint "Up to 14 images per message";
   - a **PasteButton** (icon only), shown only while `UIPasteboard.general.hasImages` is true and the tray has fewer than 14 items. That check doesn't prompt; it's re-checked on `scenePhase == .active` and on `UIPasteboard.changedNotification`;
   - a `TextField("Describe an image or an edit", axis: .vertical)` with `lineLimit(1...6)`;
   - a **Send** button (`arrow.up`, `.glassProminent`, circular). While a request is in flight, Send turns into a **Stop** button that cancels it.

**Input behavior**
- Return inserts a newline. Sending is by button only.
- The draft text is saved to `Conversation.draftText` (debounced 500 ms).
- Draft attachments live only in memory and in `Staging/`, and are lost if the app is killed.
- **Pickers:**
  - `PhotosPicker(selection:maxSelectionCount: max(1, 14 - trayCount), selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)`. The picker is only reachable when `trayCount < 14` (see the + menu above). Never pass 0: PhotosPicker and PHPicker treat a limit of 0 as "no limit";
  - `.fileImporter(allowedContentTypes: [.image], allowsMultipleSelection: true)`, which has no count limit.
  - If more items are selected than there is room for (possible from Files), the extras are dropped, with a toast: "Up to 14 images per message".
- **On send:**
  - haptic `.sensoryFeedback(.impact)`;
  - when a reply completes while the chat is visible, `.success` haptic.
- On first send, ask for notification permission (section 4.11).

### 3.6 Image context menu and message actions
Long-pressing an image opens a `contextMenu` with a large preview.

**Image section**

**Image Context Menu Actions**:
- **Edit from here**: Assigns `Conversation.pinnedImageID`, presenting the pinned chip within the composer alongside haptic confirmation. For generated images, conversation aspect ratio and resolution overrides adopt the recorded parameters of the source request, logging setting updates and presenting toast confirmation.
- **Save to Photos**: Writes verbatim original image bytes to the system photo library (Section 4.9).
- **Save to Files…**: Presents a native system document export interface or save panel with the source asset file (Section 3.11).
- **Share…**: Dispatches the source image file through the platform share sheet (`UIActivityViewController`).
- **Copy**: Places uncompressed original image bytes directly onto the system pasteboard.
- **View**: Opens the full-screen interactive media viewer.

**Message Context Menu Actions**:
- **User Messages**:
  - *Copy Prompt*: Copies prompt text to the system pasteboard.
  - *Edit and Resend*: Loads prompt text into the composer (prompting for confirmation if an uncommitted draft exists), clones associated attachments via APFS copy, re-prepares media if dimension thresholds have changed, and restores pins to originating baseline images. Refused reply Edit controls invoke this workflow before focusing the input field.
  - *Delete*: Displays confirmation alert and removes the message record alongside on-disk assets, disabling downstream regeneration for dependent replies.
- **Model Replies**:
  - *Copy Text*: Copies synthesized textual content to the pasteboard when text parts exist.
  - *Regenerate*: Dispatches a new generation request reconstructing inputs and parameters from the historical record, disabling execution if referenced input assets have been purged.
  - *Info*: Presents an inspector sheet displaying operative models, dimensions, safety categories, input thumbnails, execution latencies, server identifiers, finish reasons, and sanitized raw JSON payloads.
  - *Delete*: Prompts for confirmation, aborting active background tasks if execution is in flight prior to record removal.

Failed, refused, empty, cancelled and interrupted cards show the buttons from the section 3.4 table; Regenerate, Info and Delete stay in this long-press menu for every reply.

### 3.7 Full-screen viewer
- A `fullScreenCover` holding a `ZoomableImageView`: a `UIViewRepresentable` around a `UIScrollView`.
  - `minimumZoomScale` fits the image to the screen.
  - `maximumZoomScale` is the larger of 1:1 pixels × 2 and 4× the fit scale.
  - Double-tap toggles between fit and 2.5× at the tap point.
  - The image is centered while zoomed out.
- The image is decoded at full resolution off the main actor with `CGImageSourceCreateImageAtIndex`. A 4K 16:9 image is about 67 MB decoded, which is acceptable for one image. The display thumbnail shows until decoding finishes.
- Swiping down (when at the minimum zoom) or tapping ✕ dismisses it. A single tap toggles the chrome.
- **Bottom glass toolbar:** Share, Save to Photos, Save to Files, Copy, Edit from here (pins the image and dismisses the viewer), and Info (pixel size, MIME type, byte size, source, model and settings).
- When a message has several images, the viewer pages between that message's images with a horizontal `TabView(.page)`, with zoom reset per page.
- Landscape is supported.

### 3.8 Settings (sheet)
**API Key**
- Shows the status "Saved (…a1B2)", or "Not set".
- Actions: Replace Key (the onboarding form inline), Validate Now, and Remove Key (destructive, with confirmation; returns to onboarding).

**Models**
- Default model: "Gemini 3.1 Flash Image". This is fixed and not editable; a footnote explains it's always used for new chats.
- A toggle per catalog model other than Flash (3 Pro, 2.1, Flash Lite, 2.5 Flash Image and the legacy 3 Pro preview alias), **on by default**, with availability ("Available", "Not listed for this key", "Unknown — not checked"). Turning a model off hides it from the per-chat model menu.
- Custom model IDs: add or remove a text ID, validated against `GET v1beta/models/{id}` before it's added.
- Footnote: "Chats set to a model you turn off or remove use Gemini 3.1 Flash Image until it's turned back on." (section 2.5, step 1).
- Pull to refresh, or the Check Now button, re-runs `models.list` and shows "Last checked 5 min ago".

**Generation defaults**
- Aspect ratio: a picker over the default model's 14 ratios. Default **16:9**.
- Resolution: 512 / 1K / 2K / 4K. Default **2K**.
- Footnote: "Chats can override these from the composer. Unsupported combinations are adjusted per model."
- Safety threshold: Block none (default), Block only high, Block medium and above, Block low and above.

**Uploads**
- Max long edge: 1536 / **2048 (default)** / 3072 / 4096 px.
- Footnote: "Uploaded photos are resized and converted to JPEG before sending. Originals are kept in the chat."

**Advanced**
- "Request text alongside images" (on sends `["TEXT","IMAGE"]`, off sends `["IMAGE"]`). Default on: the live smoke test found 2K honored with text requested (R3, section 2.4).
- "Omit deprecated CIVIC_INTEGRITY category" (set automatically, can be changed).

**Notifications**
- Shows the authorization status, with a button that opens the system Settings when it's denied.
- Toggle "Notify when a generation finishes in the background" (default on).

**Storage**
- Total size of Images, Requests and Caches.
- "Clear thumbnail cache".
- "Delete All Chats" (destructive, double confirmation).

**About:** the app version and build, and the model IDs in use.

### 3.9 iPhone-specific details
- One-handed use: every frequent action is in the composer or a context menu at the bottom of the screen. Only rare actions are in the top bar.
- Keyboard: the composer rides the keyboard via the safe-area bar. The transcript keeps its bottom anchor when the keyboard appears.
- Output sizing in stack layouts: Standard 16:9 images fill available content width. For tall or vertical aspect ratios, image width is constrained so the full image height fits within the visible viewport bounds (`TranscriptLayout.heightFitWidth`), computed against outer transcript dimensions to ensure stability across software keyboard presentations. The viewer handles expanded detail.
- Thermal and memory: one full-resolution decode at a time, and thumbnails are used everywhere else (section 8).
- No status bar spinners. Progress lives in the transcript, plus the notification.

### 3.10 Developer menu and log viewer
The Developer menu exposes structured diagnostic activity logs (Section 4.13). It is presented as a toolbar `Menu` with the SF Symbol `hammer` (VoiceOver label "Developer"), accessible across Debug and Release builds on the chat list and detail view.

Menu items and inspection scopes:
- **Last Action**: Surfaces entries and child actions associated with the most recent user-initiated top-level operation (`origin: user`). Renders an "In progress" badge during active execution. System-initiated actions (background events, reconciliation tasks, maintenance jobs) are excluded unless no user actions exist in the buffer, ensuring automated routines do not displace user-initiated diagnostic views.
- **Last Error**: Surfaces entries and child operations from the most recent top-level action concluding with a failure, refusal, or interruption outcome. Excludes explicitly cancelled requests. The menu option is disabled when no error records exist in the current log buffer.
- **Full Log**: Displays the complete diagnostic log buffer in chronological order, initialized with scroll anchoring at the trailing edge.
- **Clear Log…**: Presents a confirmation prompt to purge accumulated log entries, retaining entry headers for active in-flight operations to preserve trace continuity.

**Log viewer sheet** (`LogViewerSheet`)
- The title is the item's name. The text is monospaced (the `caption` text style in the system monospaced font) and wraps. It's shown in `LogTextView`, a read-only `UITextView` (TextKit 2, `isEditable = false`, `isSelectable = true`), so any range can be selected, within a line or across lines, and copied with the standard edit menu. (A SwiftUI `Text` with `.textSelection(.enabled)` only offers copying the whole `Text` on iOS.) TextKit 2 lays out only the visible part, so a full 4 MB log stays responsive.
- One line per entry: `HH:mm:ss.SSS [Name id] Begin|Step|Result: message`, in local time. Sub-actions are indented two spaces per level after the timestamp, so timestamps stay aligned. Result lines start with the outcome word. A date line (`— 2026-10-16 —`) separates days in Full Log. An action whose earlier entries were rotated out shows "(earlier entries rotated out)" before its first remaining line. In Last Action and Last Error, a Late completion of the shown action follows the action's own lines, indented one level, after the line "(completed later)".
- Toolbar: **Done**, **Copy** (copies the text of the current view; a "Copied" toast) and **Share** (`ShareLink` with a `LogTextFile` Transferable that writes the current view as a `.txt` file named like `ImageGen-log-2026-10-16-1402.txt` when shared; sharing the log isn't logged, so `ShareLink` needs no callback here).
- It updates live while open: new entries for the shown action (or any entry, for Full Log) are appended without reopening. The sheet stays on the action it opened with; a newer action doesn't replace it until the sheet is reopened. Full Log stays pinned to the bottom while you're at the bottom.
- No editing. Opening, copying and sharing the log are not logged, so viewing never changes what Last Action shows.
- Empty log (only possible before the first launch entry is written): "No log entries".

### 3.11 macOS app

The Mac app is a native AppKit/SwiftUI target (`ImageGenMac`, product name `ImageGen`), not Catalyst. It shares the pipeline, persistence, view models and most views with iOS.

- **Platform split:**
  - `ImageGen/` is shared and imports neither UIKit nor AppKit (`scripts/lint.sh` enforces it). `Platforms/iOS` and `Platforms/macOS` each define the same type and function names (`Platform`, `PrimaryNavigation`, `ChatToolbar`, `ComposerAddMenu`, `MenuCheckItem`, `ViewerPager`, `ViewerChrome`, `ZoomableImageView`, `LogTextView`, `AutoFocusTextField`, `SystemBackgroundTaskProvider`, `SettingsProgressButton`, `SettingsActionRow`, `CustomModelRow`, plus view modifiers such as `chromelessMenu()`, `sharePresentation(_:)`, `messageRowMenu(isPrompt:_:)` and `viewerCover`), so shared code calls them without `#if`. A modifier is a no-op where the other platform doesn't need it.
  - The one `#if os(macOS)` in `ImageGen/` is `kSecUseDataProtectionKeychain` in `KeychainStore`, where a platform file would only duplicate the store.
  - `DebugHooks` and `DebugSupport` are `#if DEBUG`, so Release builds of both apps exclude them.
- **Bundle IDs:** Release uses `IMAGEGEN_BUNDLE_ID`. Debug appends `.debug`, which gives it its own sandbox container, defaults, keychain item and background session, so test runs that seed or reset the store (`-ResetStore`) can't touch a Release install. Release builds are not debuggable: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is off, so development signing adds no `get-task-allow`. Distribution still needs a Developer ID re-sign.
- **Window and navigation:** one main window. On first launch it is half the display's visible area in each dimension (never below the 800×560 content minimum or above the display) and centred (`MainWindowSizing`); after that the system restores the size and position people chose. The chat list is a sidebar (`NavigationSplitView`) with the selected chat beside it; selection is `Navigator.path.last`. Sidebar rows have a context menu (Rename, Delete), the Delete key on the selected row uses the same confirmation as iOS, and rows show their status in a tooltip. An inline rename takes the keyboard directly (an AppKit field, because a closing menu or the composer can undo a SwiftUI focus request), and ends on Return, Esc, losing focus or a selection change. SwiftUI keeps a `Window` scene's window out of the Window menu's list and adds an item named after the scene instead, so the scene's title follows the chat on screen (`Navigator.chatTitle`), and the menu lists the chat's title.
- **Keyboard focus:** a chat opened from the sidebar leaves the keyboard in the sidebar, so the arrow keys keep moving through chats and the Delete key keeps working; Return or Tab moves on to the prompt. A typed character starts a prompt instead of being lost: a key monitor on the list asks `SidebarKeyRouting`, and on a yes gives the composer's field the keyboard, with the caret after any draft, before returning the key to normal delivery. So the key arrives at the field like any other, through its input context, which is what composes dead keys and input methods. The list keeps its arrows, Delete, Return, Tab and Esc, the menus keep every Command and Control shortcut, and nothing is forwarded while a rename is active, a sheet is up or a field in the list has the keyboard. Routes that open a chat to type in it (New Chat, a notification, Edit From Here, ending a rename) ask for the composer through `Navigator.requestComposerFocus`. Otherwise the field takes the keyboard when a chat appears, unless the sidebar or another text field has it.
- **Unsent work:** selecting another chat is casual browsing on the Mac, not the deliberate back navigation it is on iOS. So a chat's screen model lives as long as the chat (`ChatModelCache`), which keeps its attachment tray, and a new chat with a draft or attachments is not discarded when left. A chat with neither is still deleted when left, and it also leaves `Navigator.path`, since closing the window can make it disappear while still selected. A quit runs `AppEnvironment.prepareToTerminate` for up to a second: drafts flush, empty chats go, and queued log entries reach the file. A tray doesn't outlive the process.
- **Settings scene:** a standard Settings window (Cmd-comma) with General and Models tabs over the shared settings content. `Navigator.settingsPath` selects the tab. Actions are regular buttons at the trailing edge of their rows. The About panel in the app menu holds the version and the SynthID note, which iOS keeps in Settings. Custom models have a Remove button and context menu, since a Mac form has no swipe. Saving a key in Settings ends onboarding.
- **Commands:** File has New Chat, Delete Chat and Save Image As. Edit adds Paste Image and the standard text commands (Find, Spelling and Grammar, Substitutions, Transformations). View has Show Sidebar, Jump to Latest (Cmd-Option-Down, because Cmd-Down moves a text field's caret), and the viewer's zoom and paging; Previous and Next Image are enabled only when there is an image to go to. Chat has Send, Stop, the attachment pickers, the last message's actions (Regenerate, Edit and Resend, Info, Delete), Rename and Chat Settings. Image acts on the viewer's image while its window is key, and otherwise on the chat's latest image. Developer replaces the iOS Developer menu. Chat commands act on the key window's chat through `ChatCommandHandle` and disable themselves without one or while one of its sheets or dialogs is up. New Chat is disabled during onboarding.
- **Transcript:** a right-click anywhere on a row, including over selectable text and blank space, shows the message's actions, and a button with the same menu appears while the pointer is over the row, beside the bubble on a prompt and at the top trailing corner of a reply. Text selection and Cmd-C still work; a transparent view (`SecondaryClickMenu`) takes only secondary clicks, because selectable text's own menu would otherwise replace the row's. Images can be dragged out as files, and reached and opened by keyboard and VoiceOver. Prompt bubbles use the app's accent colour, not the System Settings accent, which white text can't always sit on.
- **Scrolling the transcript:** after a new reply the view re-aligns to the bottom a few times to absorb late image layout (`TranscriptSettling`). It stops for good at any scroll by the user, and it issues no scroll when the bottom is already in place: a scroll takes effect at the next layout pass, so an unneeded one undoes a wheel event that arrives before that pass.
- **Laying out every row:** the transcript's stack is a `VStack`, not a `LazyVStack`. A lazy stack's height is an estimate from the rows it has laid out, and here rows change height with the window. So a resize moves that estimate by thousands of points, and rows change position by as much from one pass to the next. Measured opening a 24-row chat at 800×612 and widening it to 1500×900: the content's height went 4880, 6452, 9455, 8068, 7715 in one resize, while its rows really ended at about 5700. The bottom scroll anchor followed the estimate past the last row, nothing was laid out there, and with nothing laid out the estimate could never correct itself, so the window stayed blank. The same estimates took the reader's row out of layout, and frames reported on the way came from throwaway passes at widths the column never has. With every row laid out the height is exact, so none of that can happen, and the reflow below can trust every frame.
  - Only rows within 800 pt of the visible area hold pixels (`TranscriptRowPresence`). Each row's images observe their own value, so scrolling past a row redraws only that row, and the rest show their placeholders at the same frames: a thumbnail's rounded pixels have a slightly different shape from the original, so the image fills a frame made from the original's shape, and rows don't move when images come and go. A row out of that range also takes no part in hit testing (`FarRowHitTesting`): it can't be under the pointer, and SwiftUI otherwise goes through every row's hover and content shape on each scroll tick to see what the pointer is now over. Which rows are near goes by the scroll view's own position and changes (below), because the view can end up somewhere no report says.
  - The cost grows with the chat. Section 8 has the numbers.
- **Reflowing under resize:** while the transcript's size is changing (an episode, until it has been still for 300 ms) the geometry can't say where the reader meant to be, because shrinking the height at the bottom looks like having scrolled up. So `TranscriptReflow` freezes the follow state and the place from before the episode, and goes on asking for them as each layout pass reports.
  - At the bottom, the bottom stays in view through any resize.
  - In the middle, the place is the first visible row and how far into it the visible area starts, as a share of the row, so rows above changing height don't move what's being read, and neither does the row itself. Each row reports its frame in content coordinates to an unobserved object, so this redraws nothing. The correction moves the clip view directly, when the place's row reports and when the clip view or the document changes (`scrollViewDidChange`), which can come after the last report: a pass that shrinks the view takes the clip view's new height after everything has reported, and the bottom would stay out of view until the episode ended. Driving the same corrections through `ScrollPosition` holds the place just as closely (worst 0.2 pt from where it should be in a width sweep, either way), but it still needs the handle to read the real position, it writes SwiftUI state from inside a pass, and its modifier would reach the iPhone's scroll view, so the clip view stays.
  - A place the content is too short to show stands until the position changes, so growing the window and shrinking it back returns to it. Full screen and back returns to the same place the same way.
  - After an episode that kept a place, the bottom isn't followed until the position changes or is about to, however near the new size has left the view to it (`keepsPlace`). Otherwise a reader 60 pt up, who a shorter window leaves 40 pt from the end, within the 44 pt that counts as being at the bottom, would be taken to the bottom by the next resize. A reader who then scrolls there follows it again, even if the scroll moves nothing.
  - The place is taken again after every report of the position, not only one that differs from the last position held. What runs after the scroll view's own notification can already have read the new position by the time the report comes, and a report that looked like no move left the place behind, so the next rotation went to the wrong row.
  - A retry above the visible rows is held the same way, so what's being read stays still however the row's height changes. When the retried row is itself the place, with its top above the visible area, a share of the row would throw it upward as it grew, so a retry keeps the place in points from the row's top (`holdsRowTop`) until the episode ends. Rows above it stay still and it grows downward. Any scroll by the user ends an episode, and the position is theirs.
  - The scroll view can clamp a position after reporting it, and the report then stands until the next scroll, so positions are read from the scroll view itself.
  - A new reply or the user scrolling also releases a place the content was too short to show, so the bottom is followed again if the reply is at it.
- **Sheets:** a plain header with the title and a Done button sits above the content (`SheetScaffold`), not a `NavigationStack`, whose toolbar sets the title in from the content in a Mac sheet. Chat Settings has no minimum height, so it is as tall as its rows.
- **Viewer window:** the full-screen viewer becomes a separate window that opens on the display of the window that asked. Each opening gets a fresh identity, so opening another image replaces the content, selection and zoom. Its actions are in the window's toolbar (previous and next for several images, then Share, Save to Photos, Save As, Copy, Edit From Here, Info) and in a context menu on the image; nothing overlays the picture, and the position is the window subtitle. Arrow keys change the image and Esc closes it (or leaves full screen first); the zoom shortcuts belong to the View menu; Edit > Copy copies the image. At fit a drag takes the image out as a file; zoomed in it pans. Edit From Here returns to the image's chat, and deleting that chat closes the viewer. The window's minimum content size is 360×280, stated by the SwiftUI content: its hosting view manages the window's minimum and overwrites one set on the window directly.
- **Export:** Share opens the system picker at the pointer with no sheet in between, and stays tracked until the chosen service reports back. Services and drags get a temporary copy under the suggested name (`ExportScratch`), not the stored original. Drags offer it as a file URL and not a file promise, whose name the system rebuilds from the type (a JPEG would land as .jpeg, not the .jpg the viewer and the save panel show). Those copies and shared logs are removed at launch and when the log is cleared. Save As uses an `NSSavePanel` as a sheet on the window rather than `fileExporter`, whose panel can't be retitled and calls itself "Export". A failed save shows an alert.
- **Composer:**
  - Return and Cmd-Return send, and Shift-Return and Option-Return insert a newline. Return belongs to an input method while it is composing. Caps Lock doesn't change any of this.
  - Images attach by dropping files or image data anywhere on the chat, with Cmd-V (text still pastes as text), from Edit > Paste Image or from the + menu (Photos, Choose File, Paste Image). Paste Image takes the image even when text came with it. Edit > Paste itself stays with the text field, whose editor owns that command's validation, so it stays text-only.
  - An image drag takes the keyboard from the composer field while it is over the chat, because the field's editor would otherwise accept it and insert the file's path. Text drags still insert into the field.
  - Pasted data is read after the tray shows the item. Chosen and dropped files are copied into staging under security-scoped access before preprocessing, links resolved, so the preprocessor reads only real files inside the sandbox container. Files and data over 512 MB are rejected.
  - Code that replaces the composer text clears the field's undo history, which can no longer describe it.
- **Layout:**
  - `TranscriptLayout` is the policy, computed from the transcript's outer size. The column is the width of the window's detail area less its margins, up to 1600 pt of content, centred. Text is capped at a comfortable 820 pt inside it, leading-aligned; prompt bubbles keep their trailing edge on the column and their 48 pt leading inset, and the composer is 820 pt on the column's centre.
  - The composer bar is an opaque, window-wide surface in the system background colour, with a separator above it, and the transcript simply ends at it. The system's scroll edge effect is off at the bottom, because it would show blurred content through the bar. The last row keeps a 16 pt margin above the bar, as a content margin so that scrolling to the bottom respects it.
  - The composer's pills and chips use no glass on the Mac. They sit directly on the system background, outlined by a hairline capsule.
  - Reply images and the pending card share one rule, so a card that becomes an image doesn't change size and a retried reply stays put. An image fills the column, with its height at most 80% of the transcript's outer height and never so tall that the composer hides it, down to a 240 pt limit and a 200 pt minimum width for very tall images. It's the outer height, composer area included, so typing a longer prompt doesn't resize every image. The card uses the pixels Gemini returns for the ratio (`AspectRatio.oneKPixels`), not the ratio's name: 16:9 comes back as 1376×768, a few points off at these sizes.
  - A pending card's footer is as tall as what the finished reply adds to its image, a line of text if the request allows text and the metadata line, so the row keeps its height when the reply arrives. The Cancel button is drawn over that space and adds nothing to it, and the card's text is drawn over the shapes, one line when the card is too short for two, so neither changes the row's height. A request that allows text can still get none back, and then the row is shorter by that line.
  - Reply images load more pixels when drawn large: the displayed long edge times the display scale, from the buckets 1200, 1800, 2400, 3200 and 4096 so that resizing reuses them, and never more than the original has. See section 8.
  - Controls use larger text styles than iOS, because the Mac's footnote and caption styles are 10 pt and it has no Dynamic Type.
- **Scroll bar width rule:** Under persistent legacy scrollbar settings, content overflowing vertically claims lateral space for the scroller bar. Because aspect-constrained image heights depend directly on column width, layout passes that narrow content to accommodate the scroller reduce content height, which in turn removes the overflow condition and scroller, inducing rapid oscillation. To prevent unstable layout loops, the transcript column width is constrained relative to the enclosing viewport width with legacy scrollbar gutter clearance continuously reserved (`measuresTranscriptViewport`, `scrollBarIndependentColumn`). The column is positioned via leading-edge offset rather than centering to preserve alignment with the composer bar.
- **Launching for tests:** `scripts/run-mac.sh` with `RUN_MAC_BACKGROUND=1` opens the app with `open -g`, which asks the system not to bring it to the front, so a run can go on beside other work.
- **Onboarding:** the scroll view fills the window and the form is capped inside it, at 520 pt. AppKit puts a backdrop under the title bar at a scroll view's width, which at the form's width would show as a lighter band across the top of the window.
- **Log view:** the Developer menu's log views open in one window, which can stay beside a chat while the log streams. It is called Activity Log in its title and the Window menu, the view on show is the subtitle (Last Action, Last Error, Full Log), and it opens on the full log from the Window menu. It closes like any window, so it has no Done button. Edit > Find opens the find bar over the log, which searches as you type.
- **Background execution:** In the absence of system background session wakeup events on macOS, active generation operations maintain a `ProcessInfo` activity assertion (`.userInitiated`) from request registration until completion, pre-empting idle sleep and App Nap. `GenerationService` publishes active counts via `BackgroundTaskProviding.liveRequestsChanged`. Local completion notifications are suppressed when the conversation window is frontmost and unminimized. Storage maintenance executes periodically when the app is active if the elapsed interval exceeds 6 hours.
- **Sandbox and signing:** the app is sandboxed with network client, user-selected file read-write and Photos library access. The data protection keychain requires a signed build, so `scripts/build-mac.sh` and `scripts/test-mac.sh` use real signing.

### 3.12 iPad

The iPad runs the iOS target. `Platform.isPad` is the only device test, and `NavigationLayout.choose(isPad:isRegularWidth:)` is the only layout decision, a pure function that sends every iPhone to the stack, including large ones whose landscape width is regular. The modifiers in `Platforms/iOS` that change layout apply only in the split layout, read from the `navigationLayout` environment value, so the stack layout is the iPhone's. The ones that don't depend on width (keys, tooltips, drops) test `Platform.isPad`.

- **Navigation:** at regular width `PrimaryNavigation` is a `NavigationSplitView` with the chat list as a sidebar selecting `Navigator.path.last`, the chat as the detail, and "No Chat Selected" when there is none. At compact width (Slide Over, narrow windows) it is the iPhone's `NavigationStack` on the same path. In a sidebar there's no New Chat row, because the toolbar has the button, and the Developer menu moves from the list's toolbar to the detail's. Rows have a context menu (Rename, Delete) instead of the iPhone's long press to rename.
- **Crossing between layouts:** Navigation path state is shared, retaining active conversation selections across transitions between split and stack navigation. Root-level presentation coordinates media viewing across layout rebuilds (`ViewerCoverController`), while `TranscriptReflow` preserves scroll anchors and relative visible row offsets. Uncommitted message drafts and attachment trays are retained in memory via `ChatModelCache`.
- **Transcript at regular width:** the policy is `TranscriptLayout`, as on the Mac (section 3.11): a centred column up to 1600 pt of content, text and the composer at 820 pt, images up to 80% of the outer height, and the pending card framed like the image that replaces it. The composer stays on glass, floating over the transcript, with the hard scroll edge, because the pills sit far apart on a wide bar and text behind them would show through. The Jump to Latest control integrates directly into the composer accessory row rather than floating as an overlay to prevent occluding prompt content near the trailing edge. The control appears when scroll offset exceeds container height, accounting for safe area insets. Reply images load at display resolution through `ThumbnailService.displayPixels` (section 8). iOS scroll indicators take no width, so no gutter is reserved.
- **The software keyboard:** the outer size is measured from a background that ignores the keyboard's safe area, so images don't change size when it comes up. In a split view the keyboard's inset going away is not reported to SwiftUI and leaves the scroll view past the end of the content, so `TranscriptScrollHandleView` pulls it back when the keyboard hides, unless a finger is on it.
- **Reflow:** every row is laid out, as on the Mac (section 3.11), and `TranscriptReflow` runs through a handle that moves the enclosing `UIScrollView` directly and observes its offset and sizes. Rotation and window resizing keep the bottom in view at the bottom and the first visible row and its fraction in the middle, and a retry above the bottom keeps rows above it still. Compact width has no reflow, as on the iPhone.
- **Hardware keyboard:** Return and Cmd-Return send; Shift-Return and Option-Return insert a newline at the caret, which a vertical `TextField` doesn't do for a hardware key; an input method composing keeps Return. The software keyboard reports no key presses, so its Return still inserts a newline. New Chat and Edit from Here, from wherever they're chosen, put the cursor in the composer only when `GCKeyboard` reports a hardware keyboard, so they raise no software keyboard, and only once nothing covers the chat. `PadCommands` puts New Chat, Settings, Delete Chat, Jump to Latest and the shared Chat menu in the menu bar. An iPhone registers none of them. They're off while a sheet, dialog, picker or export of the chat is up, and while the viewer or Settings covers it, because those are in the same window and another presentation has nowhere to go. Esc ends an inline rename.
- **Pointer:** icon controls that their style gives no effect to get the system hover effect (`padHoverEffect`) and tooltips. Context menus open on a secondary click, which the system provides. A double click or double tap opens an image. Dragging an image out isn't offered.
- **Drops:** dropping images on the chat attaches them. Each item's bytes start loading during the drop, in the first image type it offers.
- **Sheets and viewer:** the same presentations as on the iPhone, which the system shows as form sheets on iPad: Settings, Chat Settings, Info, the log, and Share, which is a centred sheet and not a popover from its button. The viewer is a full-screen cover with paging, and its pages follow a window's size without being rebuilt, so a drag loses neither zoom nor picture. Confirmation dialogs show as popovers.
- **Onboarding** keeps a width of 560 pt. Text says "iPad" and "iPadOS" where it would say "iPhone" and "iOS".

---

## 4. Architecture

### 4.1 Layers and modules
There is one app target with folder-based layering and no local packages. Dependencies point only downward.

```
ImageGen/
  App/            ImageGenApp, RootView, AppDelegate (background URLSession events, notification delegate),
                  AppEnvironment (DI container), NotificationRouter, NotificationPoster, AppActivity,
                  BackgroundTaskProvider (UIApplication background-task assertions), DebugHooks
  Features/       ChatList/, Chat/ (ChatView, ChatScreenModel (+Attachments), MessageRow, ReplyCard,
                  ComposerView, AttachmentTray, SettingsPills), Viewer/, Settings/, Onboarding/,
                  Developer/ (DeveloperMenu, DeveloperMenuModel, LogViewerSheet, LogViewerModel, LogTextView,
                  LogTextFile)
  Pipeline/       GenerationService (actor, behind the GenerationServicing protocol), RequestPreparer,
                  Reconciler, RetryPolicy, GenerationSettingsResolver, InputSelector, ModelAvailabilityService,
                  SharedTypes
  Gemini/         Vocabulary (incl. ModelCatalog/ModelCapability), GeminiEndpoint, RequestBodyWriter,
                  ResponseModels (Decodable), ResponseParser, Redactor, MimeTypes, GeminiErrorBody, ModelsClient
  Networking/     GenerationTransport (protocol), URLSessionTransport (delegate-based; background
                  or test configuration), ResponseAccumulator, BackgroundEventsRelay,
                  ConnectivityMonitor (NWPathMonitor, foreground "Waiting for network" label)
  Imaging/        ImagePreprocessor, ImageInspector (dims/type without decode), BudgetPlanner, SizeClass,
                  DecodeTimer, ThumbnailService
  Persistence/    SchemaV1 (@Model types), MigrationPlan, StoreFactory, DataStore (@ModelActor), FileStore, Janitor
  Export/         ImageFile (Transferable), PhotoLibrarySaver, PasteboardWriter, ActivityShareSheet,
                  ExportLog (the export actions' logging helpers)
  Security/       KeychainStore, SecretRegistry (secrets the log sanitizer removes)
  Settings/       AppSettings (@Observable, UserDefaults-backed)
  Support/        MarkdownBlocks renderer, Logging (OSLog categories), Formatters, Toast,
                  activity log: ActivityLogTypes, ActivityLog (nonisolated facade), ActivityLogStore (actor),
                  ActivityLogQuery, ActivityLogFormatter (section 4.13)
  DebugSupport/   #if DEBUG only: LaunchOptions, MockGeminiURLProtocol (responses generated in code),
                  DemoSeeder; never compiled into Release (section 9). Code outside this folder reaches
                  it only through App/DebugHooks.swift, whose DEBUG branch calls in and whose Release
                  branch is no-op stubs
ImageGenTests/    Swift Testing suites + Fixtures/ (JSON requests and responses, pipe-reference bodies, images)
```

- **Rule:** `Gemini/`, `Imaging/`, `Pipeline/` (apart from `GenerationService`'s store calls) and `Security/` import no SwiftUI. Everything they exchange is `Sendable` value types.
- `Features/` talks only to `AppEnvironment` services and `@Query`.
- **Logging.** Every layer may call the `ActivityLog` facade in `Support/`, which imports no SwiftUI. Pure functions (`InputSelector`, `GenerationSettingsResolver`, `RequestBodyWriter`, `ResponseParser`, `RetryPolicy`, `ImagePreprocessor`, `BudgetPlanner`) don't log; the component that calls them logs the action, its parameters and the result (section 4.13). The facade takes its redaction function as an injected closure (`Redactor.forLog(secrets:)` over the `SecretRegistry`, wired by `AppEnvironment`), so `Support/` doesn't depend on `Gemini/` or `Security/`.

### 4.2 UI state (Observation)
- `@Observable @MainActor final class` types:
  - `AppSettings`: UserDefaults-backed, with typed properties and `didSet` persistence.
  - `ChatScreenModel` (one per open chat): composer text, tray items (in the `ChatScreenModel+Attachments.swift` extension), chip state, send enablement, the "Waiting for network" flag from `ConnectivityMonitor`, and pill values resolved for display. It talks to generation only through the `GenerationServicing` protocol, so its tests use a fake. There is no separate composer model type.
  - `ModelAvailability`: cached availability, published to the UI.
  - `LogViewerModel` (one per open log sheet): the chosen view (Last Action, Last Error, Full Log), the action it opened with, its formatted text, and the live subscription to `ActivityLog.changes()`, through which it fetches only the entries written since its last refresh (section 4.13).
  - `DeveloperMenuModel` (one, owned by `AppEnvironment`, shared by both toolbars): the latest `ActivityLogStatus` from `ActivityLog.changes()`, so the menu knows synchronously whether Last Error has anything to show (section 3.10).
- Lists come from SwiftData `@Query` on the main `ModelContext`:
  - `Conversation` sorted by `updatedAt`;
  - `Message` filtered with `#Predicate { $0.conversation?.id == convID }` and sorted by `sequence`;
  - `GenerationRequest` for the chat, used for live state.
- Saves from `DataStore` on its background context are merged into the main context automatically, and `@Query` refreshes.
- `AppEnvironment.shared` is a lazily created singleton. Whichever of `ImageGenApp.init` or `AppDelegate.didFinishLaunching` runs first creates it, so it (and the background session) also exists on a background relaunch. Construction order matters (section 4.6). The `ActivityLog` is created first, and the Launch action begins before anything else is built (section 4.13). The only thing before it is the DEBUG `-ResetStore 1` handling, which deletes the store, the files and `Logs/` so the run's log starts with its own Launch Begin. Inside its `init`, the transport creates its ordered, unbounded event stream **before** it creates the background `URLSession`, so delegate events that arrive before `GenerationService` starts consuming are buffered, never dropped. The Reconciler starts right after the session is created, in the same `didFinishLaunching` pass, whether or not a UI scene ever connects. It's injected with `.environment(...)`.
- Under the unit-test host (`XCTestConfigurationFilePath` is set), `AppEnvironment` is inert: it creates no background session and no activity log file, doesn't run the Reconciler or Janitor, and doesn't request notification permission. Tests build their own components.

### 4.3 SwiftData schema (SchemaV1)
- The model classes are explicitly marked `nonisolated` (the project's default isolation is also nonisolated, section 5), so `@ModelActor` works.
- A `VersionedSchema` and `SchemaMigrationPlan` exist from day one.
- Enums are stored as `String` raw values.
- Ordered or structured payloads are stored as JSON `Data`, which avoids SwiftData's quirks with composite Codable types.

```mermaid
erDiagram
  Conversation ||--o{ Message : "messages (cascade)"
  Conversation ||--o{ GenerationRequest : "requests (cascade)"
  Message ||--o{ ImageAsset : "images (cascade)"
  GenerationRequest }o..o{ ImageAsset : "inputs (by UUID, JSON)"
  GenerationRequest |o..|| Message : "replyMessageID / userMessageID (by UUID)"

  Conversation {
    UUID id "unique"
    String title
    Bool titleIsUserSet
    Date createdAt
    Date updatedAt
    String modelIDOverride "nil = default (Flash)"
    String aspectRatioOverride "nil = Settings default"
    String imageSizeOverride "nil = Settings default"
    UUID pinnedImageID "nil = none"
    String draftText
    Int nextSequence
  }
  Message {
    UUID id "unique"
    Int sequence "monotonic per chat"
    String role "user | model"
    Date createdAt
    String text "prompt (user); model: text runs joined by a blank line (Copy Text)"
    Data partsData "JSON [MessagePart] order of text/image"
    UUID requestID "user: request it started; model: request that produced it"
    UUID regenerateOfRequestID "model only, optional"
  }
  ImageAsset {
    UUID id "unique"
    Int ordinal
    String origin "photos | files | paste | model"
    String relativePath "Images/<conv>/<id>.<ext>"
    String mimeType
    Int byteCount
    Int pixelWidth
    Int pixelHeight
    String originalFilename "optional"
    String preparedRelativePath "uploads only: Images/<conv>/prepared/<id>-<edge>.<ext>"
    String preparedMimeType "uploads only"
    Int preparedByteCount "uploads only"
    Int preparedPixelWidth "uploads only"
    Int preparedPixelHeight "uploads only"
    Int preparedLongEdgeSetting "uploads only: maxUploadLongEdge used"
    Date createdAt
  }
  GenerationRequest {
    UUID id "unique"
    UUID userMessageID "nil for regenerate"
    UUID replyMessageID
    UUID sourceRequestID "regenerate lineage"
    String modelID
    String aspectRatio "sent value, nil if omitted"
    String imageSize "sent value, nil if omitted"
    String safetyThreshold
    Data safetyCategoriesData "JSON [String] actually sent"
    Bool includeTextModality
    String promptText
    Data inputsData "JSON [RequestInput]"
    String selectionReason "attachments|pinned|latest|none"
    String state
    Int attempt "every attempt, automatic or manual"
    Int maxAutoRetries
    Int autoRetriesUsed "reset to 0 by manual Retry"
    Bool civicFallbackUsed "CIVIC rebuild done for this request"
    Bool nextAttemptCreatedInBackground "retryScheduled task created while inactive"
    Int taskIdentifier "optional"
    Date nextAttemptAt "optional"
    Date createdAt
    Date startedAt
    Date completedAt
    Int httpStatus
    String errorStatus "e.g. RESOURCE_EXHAUSTED"
    String errorMessage "API error message, or finishMessage for a refusal"
    String details "redacted JSON / error body, <=64KB"
    Data noticesData "JSON [String] parser notices"
    String finishReason
    String refusalReason "promptFeedback.blockReason or the refusing finishReason"
    String modelVersion
    String responseID
    Int outputWidth
    Int outputHeight
    String activityActionID "logging only: the action following this request (section 4.13)"
  }
```

- `MessagePart` is `{kind: "text"|"image", text: String?, imageID: UUID?}`.
- `RequestInput` is `{imageID, preparedRelativePath, mimeType, byteCount, pixelWidth, pixelHeight}`, describing the bytes actually sent: the prepared file for an upload, the original for a model output (unless the budget step shrank it). The recorded file is part of what makes Regenerate reproducible. These Sendable types, and the other DTOs that cross layers, live in `Pipeline/SharedTypes.swift` (IMPLEMENTATION_PLAN.md M0).
- **`ImageAsset.ordinal`** is the 0-based position of the image within its message, assigned once and never changed:
  - model messages: the index among the **image** parts of `ParsedOutcome.success.parts`, in response order (text parts don't count);
  - user messages: the tray index at send time, after any reordering. Edit and Resend clones get the tray index of the new send.
  So the highest ordinal is always the last image, which is what §2.2 rule 3 relies on.
- **Prepared fields on `ImageAsset`.** For uploads, the `prepared*` fields are copied from the tray item at send time; for model outputs they're nil. When a later send reuses an upload through the pin or the latest-image rule, `RequestPreparer` uses that prepared file if it exists and `preparedLongEdgeSetting` equals the current `maxUploadLongEdge`. Otherwise (the file is missing, or the setting has changed since), it re-prepares from the original at the current setting (section 4.8), writes `prepared/<id>-<edge>.<ext>`, and updates the fields. It never sends an upload's original bytes, so the HEIC→JPEG, downscale and EXIF-stripping rules always hold. Only a missing **original** fails the send (`inputMissing`). The same check applies when Edit and Resend clones an upload into the tray: if the clone's prepared file is missing or its edge setting differs from the current `maxUploadLongEdge`, the tray item is re-prepared from the cloned original before it becomes ready (section 3.6).
- **A user send creates:**
  - a user `Message`, with `requestID` set;
  - a model `Message` placeholder, with empty parts and the same `requestID`;
  - a `GenerationRequest`.
- **Regenerate creates** a new model `Message` placeholder appended at the end, and a new `GenerationRequest` whose `sourceRequestID` points to the original. No new user message is created.
- **`GenerationRequest.activityActionID`** is the 4-hex ID of the activity-log action that follows the request: its Send or Regenerate, replaced by the Retry action on each manual Retry. A relaunched process uses it to log the rest of the request under the same action (section 4.13). Nothing else reads it.
- **Reply state** is the state of its `GenerationRequest`, and isn't duplicated on `Message`. Notices and the "No image returned" badge are rendered from the stored record too (`noticesData`; parts with no image), never from in-memory parse results.
- **Indexes:** `#Index<Message>([\.sequence])`, `#Index<GenerationRequest>([\.state])`, plus `#Unique` on `id` for all four entities.

### 4.4 File storage layout
Everything lives under `Application Support/ImageGen/`. It is included in the device backup (except `Logs/`, section 4.13) and uses the default protection class, `completeUntilFirstUserAuthentication`, so background relaunches can write.

```
Application Support/ImageGen/
  default.store                         SwiftData
  Images/<conversationID>/<imageID>.<ext>          originals: exact user-file bytes or exact API bytes
  Images/<conversationID>/prepared/<imageID>-<edge>.<jpg|png>   API-ready versions (uploads, or shrunk outputs)
  Requests/<requestID>/body.json        streamed request body (kept until terminal, for retries)
  Requests/<requestID>/response-<attempt>.part     accumulated response body
  Requests/<requestID>/response-<attempt>.complete marker: delegate completion received; holds the HTTP status (section 4.7)
  Requests/<requestID>/out-<attempt>/<uuid>.<ext>  parser output, moved into Images/<conv>/ before the save
  Staging/<uuid>.<ext>                  composer attachments not yet sent (+ prepared/)
  Logs/activity.jsonl                   activity log, JSON Lines (section 4.13); excluded from backup
Caches/Thumbnails/<imageID>-<px>.jpg    240 px (list/tray), 1200 px (bubble) and larger Mac and iPad thumbnails
                                        (displayBuckets, or the original's long edge)
```

- Paths in the model are **relative** to Application Support/ImageGen. The container path can change between installs.
- **The extension comes from the MIME type:** `image/jpeg` → jpg, `image/png` → png, `image/webp` → webp, `image/heic` → heic, `image/heif` → heif, `image/gif` → gif, `image/avif` → avif.
- **When an attachment is sent,** its staged files are moved, not copied, into `Images/<conv>/`.
- **Deleting a chat** removes `Images/<conv>/` and each of its `Requests/<id>/` folders, after cancelling any live tasks.
- **The `Janitor`** runs at launch, at utility priority, after the first frame and only **after the Reconciler has finished** (including any re-parse it started), so it never races a launch-time parse. It:
  - removes the staging folders of earlier launches. At launch, before any screen exists, `AppEnvironment` renames `Staging/` into `StagingRetired/<uuid>/` (trays aren't kept across launches); the Janitor removes only `StagingRetired/`, so it can never take a file this launch staged while it waited for the Reconciler;
  - lists `Requests/` and `Images/` **before** it reads the store. A send records its files in the same store turn that moves them, and a request folder is made only after its record, so anything listed that a record owns is in the snapshot taken after it;
  - deletes `Requests/<id>/` for terminal requests older than 1 h, and for request folders with no record, checking each request again just before removal (a Retry may have revived it). It never touches the folder of a non-terminal request, which protects `body.json`, the response files and `out-<attempt>/`;
  - removes image files under `Images/` (and only there) that aren't referenced by any `ImageAsset` (`relativePath` or `preparedRelativePath`) or `RequestInput`, skipping files modified in the last 10 minutes, which covers the short window between moving parsed images into `Images/<conv>/` and saving their `ImageAsset`s (a move into `Images/` marks the file modified now, because a rename or clone keeps the source's date); chat folders left empty are removed with `rmdir`, which refuses a folder a file was just moved into;
  - trims `Caches/Thumbnails` above 300 MB, least recently used first.
  
  It never touches `Logs/`, which the activity log rotates itself. It logs its run as one Janitor action (section 4.13).

### 4.5 Gemini REST client
- `GeminiEndpoint` builds `URLRequest`s for `generateContent`, `models.list` and `models.get`. The base URL comes from a constant (`https://generativelanguage.googleapis.com/v1beta`).
- `ModelsClient` runs on an ephemeral default `URLSession`, with async/await, a 20 s timeout and decoded `ModelsListResponse`.
- Generation never uses async URLSession APIs. It always goes through `GenerationTransport` (section 4.6).
- Keeping all wire formats in `Gemini/` means a future move to the Interactions API touches only that folder.

### 4.6 Background request pipeline
**Components**
- `URLSessionTransport`: a `final class`, a `NSObject` subclass, conforming to `URLSessionDataDelegate` and `Sendable`, with internal state in `Synchronization.Mutex`. Background session configuration parameters:
  - **identifier**: `<bundleID>.generation`
  - **isDiscretionary**: `false` (dispatched immediately without requiring Wi-Fi or AC power)
  - **sessionSendsLaunchEvents**: `true` (system awakens or relaunches process upon task completion)
  - **timeoutIntervalForRequest**: 300 seconds (idle duration accommodating long model synthesis latencies)
  - **timeoutIntervalForResource**: 1800 seconds (upper bound for overall task execution)
  - **httpMaximumConnectionsPerHost**: 4
  - **requestCachePolicy**: `.reloadIgnoringLocalCacheData`
  - **urlCache**: `nil`

  `waitsForConnectivity` is **not** set: background sessions ignore it and always wait for connectivity, and `urlSession(_:taskIsWaitingForConnectivity:)` is never called for them. The delegate queue is a serial `OperationQueue`.
- **The event stream.** The transport turns delegate callbacks into one ordered `AsyncStream<TransportEvent>` (unbounded buffering), created in the transport's `init` **before** the `URLSession` is created. Events are yielded synchronously on the delegate queue, so their order is the delegate order:
  - `.began(requestID, attempt, taskIdentifier)`: a delayed retry task started (from `urlSession(_:task:willBeginDelayedRequest:completionHandler:)` on a background session, or when the transport itself resumes a deferred task on a non-background session; see Retries below);
  - `.completed(TransportCompletion)`: `didCompleteWithError` (after the accumulator has closed the file and written the `.complete` marker);
  - `.finishedEvents(sessionIdentifier)`: `urlSessionDidFinishEvents(forBackgroundURLSession:)`.

  `GenerationService` consumes the stream in a single long-lived task and handles each event to the end (parse and save included) before taking the next. That gives two guarantees. Completions that arrive before anything is listening, for example on a background relaunch, are buffered rather than lost. And when `.finishedEvents` is handled, every earlier completion has already been parsed and saved, so the system completion handler is called only then. There are no separate completion or finish-events callbacks to wire, and there's no counter to race.
- `ResponseAccumulator`: maps a task's `taskDescription` (`"gen:<requestUUID>:<attempt>"`) to an open `FileHandle` on `response-<attempt>.part`. Chunks are written **synchronously in the delegate callback**, so they stay in order. The handle map is in memory only, so a task whose body is split across a relaunch reopens its file in the new process: the accumulator always opens with create-if-missing and then `seekToEnd()` (append), and **never truncates** on a lazy open. A `.part` file is created empty only when the task for a new attempt is created; each attempt has its own file. On completion it closes the handle, writes the `.complete` marker and yields `.completed`.
- `TransportCompletion` carries `requestID`, `attempt`, `taskIdentifier`, `httpStatus`, headers, the `.part` URL, bytes received, the `URLError` code, and the **cancel reason**, read from `(error as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey]`.
- `GenerationService`: an `actor`, the single owner of request state transitions, exposed to the UI through `protocol GenerationServicing: Sendable` (send, regenerate, retry, cancel). It talks to `DataStore` (`@ModelActor`), `RequestPreparer`, the transport, `ResponseParser`, `NotificationPoster` and `BackgroundTaskProvider`. It logs each request as one activity-log action (Send, Regenerate or Retry) with sub-actions for request preparation, each HTTP attempt and the parse, and steps for retry decisions, the save and the notification; the action stays open until the request is terminal, across relaunches (section 4.13).
- `BackgroundTaskProvider` (protocol; the production type wraps `UIApplication.beginBackgroundTask(withName:expirationHandler:)` and `endBackgroundTask` on the main actor; tests use a recording fake that can fire expiry).
- `ConnectivityMonitor` (protocol; the production type wraps `NWPathMonitor`): publishes `isSatisfied` to the main actor. It only drives the foreground "Waiting for network" label (section 3.4); it never starts, stops or retries a task.

**Flow**

```mermaid
sequenceDiagram
  participant UI as ChatScreenModel (MainActor)
  participant GS as GenerationService (actor)
  participant DS as DataStore (@ModelActor)
  participant RP as RequestPreparer
  participant TR as URLSessionTransport (bg)
  participant API as Gemini API
  UI->>GS: send(SendDraft) — text, staged attachments, convID
  GS->>GS: beginBackgroundTask("gen-prepare") (held until the task is resumed)
  GS->>DS: create user Message + ImageAssets (move staged files), reply placeholder, GenerationRequest(state: preparing, resolved settings, inputs)
  DS-->>UI: @Query refresh (pending card visible)
  GS->>RP: prepare(requestID) — ensure prepared files, budget check, write body.json
  RP-->>GS: bodyURL, bodySize
  GS->>TR: start(requestID, attempt, bodyURL, earliestBegin: nil)
  TR->>API: uploadTask(fromFile: body.json) + x-goog-api-key
  GS->>DS: state = inFlight, taskIdentifier, startedAt
  GS->>GS: endBackgroundTask
  Note over TR,API: app may be suspended; system continues transfer
  API-->>TR: response body (chunks or single chunk after wake)
  TR->>TR: append chunks to response-<attempt>.part
  TR->>GS: event stream: .completed(requestID, attempt, status, error, cancelReason)
  GS->>GS: RetryPolicy decides: retry (new task, earliestBeginDate) or finish
  GS->>GS: ResponseParser.parse(file → Requests/<id>/out-<attempt>/) [@concurrent]
  GS->>DS: move images to Images/<conv>/, fill reply parts, request state = succeeded/refused/failed
  GS->>UI: (if not viewing chat or app inactive) local notification
  TR->>GS: event stream: .finishedEvents (after every earlier event)
  GS->>UI: call stored system completion handler (MainActor)
```

- **Keeping the app alive until the upload task exists.** Everything before `transport.start` runs in the app's own process: `createSend`, ensuring prepared files, the budget shrink loop (section 4.8 step 5) and streaming up to about 19 MB of base64 into `body.json`. Only the system-owned upload task survives suspension. So `send`, `regenerate` and `retry` each take a background-task assertion through `BackgroundTaskProvider` before `createSend` (or before rebuilding the body) and end it right after the task is resumed, or when preparation fails. If the assertion's expiration handler fires first, `GenerationService` cancels the preparation (cancellation is checked between shrink iterations and before starting the task, section 5), deletes any half-written `body.json` and marks the request `interrupted`, so the card offers Retry. Automatic retries created from a delegate event need no assertion: they only create a task from the existing `body.json`, inside the system's background-event window.

- **Request states:**

```mermaid
stateDiagram-v2
  [*] --> preparing
  preparing --> inFlight: body written, task resumed
  preparing --> failed: preparation error (too large, decode, no key, disk)
  preparing --> interrupted: background-task assertion expired
  inFlight --> retryScheduled: transient error, attempts left
  retryScheduled --> inFlight: .began event (willBeginDelayedRequest, or deferred resume)
  inFlight --> parsing: didComplete with HTTP response
  parsing --> succeeded
  parsing --> refused: safety or policy refusal (never auto-retried)
  parsing --> failed: apiError / malformed / empty
  inFlight --> failed: transport error, not retryable or no retries left
  interrupted --> parsing: late completion (section 4.7)
  inFlight --> cancelled: user Stop / delete
  retryScheduled --> cancelled: user Stop / delete
  inFlight --> interrupted: system cancel (force-quit, background updates off, low resources)
  retryScheduled --> interrupted: system cancel
  preparing --> interrupted: found at launch
  inFlight --> interrupted: no live task at launch (after grace)
  interrupted --> preparing: user Retry
  failed --> preparing: user Retry
  cancelled --> preparing: user Retry
  refused --> preparing: user Retry
  succeeded --> [*]
```

- `refused` never goes to `retryScheduled`; only the user's Retry leaves it (not offered for `PUP_LIMITED_DISABLED`, section 3.4).

- `empty` is stored as `failed` with `errorStatus = "EMPTY"`, so it renders as "No content returned by the model."
- **Upload task from a file.** This is the only body source that survives the app exiting. `countOfBytesClientExpectsToSend` is the body size. `countOfBytesClientExpectsToReceive` is estimated per image: 512 → 1 MB, 1K → 3 MB, 2K → 8 MB, 4K → 24 MB.
- **API key.** It's read from the Keychain each time a task is created, including retries created in the background. The class is `AfterFirstUnlockThisDeviceOnly`.
- **Concurrency limits.** One in-flight request per chat, enforced by `GenerationService` and reflected in the composer. Different chats can run in parallel.
- **Retries (delayed tasks).** `TransportJob.earliestBegin` is how a retry delay reaches the transport. `earliestBeginDate` only works on background sessions; other configurations ignore it. So:
  - on a background configuration, the transport sets `task.earliestBeginDate` and resumes the task at once; the system starts it later and calls `willBeginDelayedRequest`, which the transport answers with `.continueLoading` and reports as `.began`;
  - on any other configuration (unit tests, DEBUG mock mode), the transport keeps the task un-resumed and resumes it after an injected sleeper (`@Sendable (Duration) async -> Void`; tests inject an instant or manually advanced one), then yields `.began`.
  - `.began` moves the request from `retryScheduled` to `inFlight`. If the app isn't running when a delayed task begins, the transition is applied by the next event for that task (its completion), or by the Reconciler when it finds the live task with `countOfBytesSent > 0`.
- **Cancel** calls `task.cancel()`. Before cancelling, `GenerationService` adds the request ID to an in-memory `userCancelledRequestIDs` set. A retry that is scheduled but hasn't started is cancelled through its task.
- **Who cancelled.** A completion with `NSURLErrorCancelled` maps to `cancelled` only when its request ID is in `userCancelledRequestIDs` (or the record was deleted, in which case it's discarded). Otherwise the system cancelled it. The cancel reason (`NSURLErrorCancelledReasonUserForceQuitApplication`, `…BackgroundUpdatesDisabled`, `…InsufficientSystemResources`, or none) is logged and the request becomes `interrupted`, with Retry. This is what makes a force-quit show "Interrupted" on the next launch: after a force-quit, the recreated session reports the old tasks as `NSURLErrorCancelled` with the force-quit reason.
- **Waking in the background.**
  1. `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` stores the handler in the `BackgroundEventsRelay` (MainActor).
  2. The transport is already recreated with the same identifier, because `AppEnvironment` is created by whichever of `ImageGenApp.init` and `didFinishLaunching` runs first, with the event stream in place before the session (section 4.2). The Reconciler has started too (section 4.7).
  3. On `urlSessionDidFinishEvents(forBackgroundURLSession:)`, the transport yields `.finishedEvents` into the same ordered stream. `GenerationService` reaches it only after every earlier `.completed` event has been parsed and saved.
  4. It then calls the stored handler on the main actor through the relay.
  5. Parsing a 4K response takes well under 5 s, which is inside the background time budget.

### 4.7 Reconciling after launch
The `Reconciler` runs once per process start, in `didFinishLaunching`, right after the transport session is recreated. It doesn't wait for a first frame, because a background relaunch may never draw one (section 8).
1. `session.getAllTasks()` gives the live set: request ID and attempt, parsed from `taskDescription`.
2. For each `GenerationRequest` in a non-terminal state:
   - `preparing`: there's no task, and preparation never persists half-way, so mark it `interrupted`.
   - `inFlight` or `retryScheduled` with a live task for the same attempt: leave it, and refresh `taskIdentifier`. A `retryScheduled` request whose live task has `countOfBytesSent > 0` has begun, so it moves to `inFlight`.
   - `parsing`: handled as in step 4 (re-parse when the `.complete` marker is present; otherwise treated like `inFlight` with no live task).
   - `inFlight` or `retryScheduled` with no live task: start a **5 s grace timer**. Completion events for tasks that finished while the app was gone are delivered after the session is recreated, possibly after `getAllTasks` returns. When the timer expires, if no completion has arrived, mark it `interrupted`.
   - **A completion that arrives late always wins.** If a completion arrives for a request already marked `interrupted`, `GenerationService` parses it, and a success replaces the interrupted state. A late completion that is a system cancel (section 4.6, "Who cancelled") also ends as `interrupted`, never `cancelled`.
3. Force-quit cancels background transfers. On the next launch the recreated session reports those tasks as `NSURLErrorCancelled` with the force-quit cancel reason, and they map to Interrupted with Retry. This is documented in the card text.
4. Unfinished parsing is always recoverable. `parsing` may be the stored state (it drives the pending card, section 3.4), or the state may still read `inFlight` if the process died before that write; either way the `.part` file is complete. The Reconciler checks for a `response-<attempt>.complete` marker, written right after the delegate completion and before parsing. If the marker is present, the Reconciler re-runs parsing from the file instead of marking the request interrupted.
5. It logs its run as a Reconcile action, with one step per request decision. It then closes the activity-log actions a previous process left open (`ActivityLog.openActionsAtLaunch()`, section 4.13): each gets `Result: interrupted · the app was closed before this finished`, except an action (or a sub-action of one) that is the `activityActionID` of a request still non-terminal after steps 1–4. That action stays open with a step saying which request it follows, and gets its result when the request ends. A request this pass marks `interrupted` closes its action with `interrupted` and the reason (for example "no live task after the 5 s grace").

### 4.8 Upload preprocessing
**When it runs.** `ImagePreprocessor` runs when you attach (as soon as an item lands in the tray), at utility priority, with `@concurrent` functions. It isn't tied to Send, so Send is fast, and Regenerate reuses exactly the same prepared bytes.

**Steps**
1. **Import the original bytes.**
   - PhotosPicker: `loadTransferable(type: Data.self)` with `.current` encoding, which gives HEIC originals. The type comes from `supportedContentTypes.first`.
   - fileImporter: under `startAccessingSecurityScopedResource`, copy the file to `Staging/`.
   - PasteButton: `PasteButton(payloadType: PastedImage.self)`, where `PastedImage` is a custom `Transferable` with `DataRepresentation(importedContentType: .image)` (plus explicit `.png`, `.jpeg` and `.heic` representations). Plain `Data` is avoided because its `Transferable` representation is generic data, which may not match image pasteboard items. The type is found by `CGImageSourceGetType`.
   - The bytes are saved unchanged as the **original**, used for display and save.
2. **Inspect** with `CGImageSourceCreateWithURL(kCGImageSourceShouldCache: false)`: get the UTType, the pixel size from properties (no decode), orientation and whether there's alpha. An unreadable source shows the error "Unsupported or damaged image".
3. **Prepare** into `prepared/<id>-<edge>.<ext>`, with `edge = settings.maxUploadLongEdge` (default 2048):
   - **Always re-encode.** This strips EXIF and GPS before the image leaves the device, applies the orientation, and normalizes the type. Use `CGImageSourceCreateThumbnailAtIndex` with `FromImageAlways: true`, `WithTransform: true`, `MaxPixelSize: min(edge, longEdge)` and `ShouldCacheImmediately: true`. Images are never upscaled.
   - **Output type:**
     - **HEIC/HEIF is always written as JPEG at quality 0.9**, as the requirement says. If it has alpha, the alpha is flattened onto white first, as the budget shrink does;
     - a PNG or WebP source with alpha is written as PNG;
     - everything else, including WebP without alpha, GIF (first frame) and AVIF, is written as **JPEG at quality 0.9**.
   - Record the prepared MIME type, size, dimensions and the edge setting used on the tray item. They become the `RequestInput` and the upload's `ImageAsset.prepared*` fields on send (section 4.3).
4. **Reused images** (through the pin or the latest image):
   - **Model outputs** are sent as their **original bytes**, as the pipe does. They're only re-prepared when the budget step requires it.
   - **Earlier user uploads** are sent as their prepared bytes, found through the `ImageAsset.prepared*` fields. If that file is missing, or was made at a different max long edge than the current setting, it's re-prepared from the original at the current setting first (section 4.3). An upload's original bytes are never sent.
   - **Edit and Resend clones** follow the same rule in the tray: a cloned item prepared at a different max long edge (or with no prepared file) is re-prepared from its original when it's cloned (section 3.6).
5. **Budget** (`RequestPreparer`, at send time):
   - The budget is `bodySize ≤ 19,000,000` bytes: the conservative 20 MB inline limit, minus a margin.
   - If the body is over budget, take the largest input and re-prepare it at `0.75 × its current long edge` with JPEG quality 0.85 (flattening alpha onto white). Repeat until it fits.
   - No input goes below 1024 px long edge. If the body still doesn't fit, the send fails before any network call: "Images too large to send together (N MB). Remove some or lower the max size in Settings."
   - The tray caption shows the projected size live, so this rarely happens.
6. **Limits.** At most 14 input images per request, the shared maximum for all models. A soft warning ("Best results with up to N images on <model>") appears in the tray caption above the model's high-fidelity soft limit: Flash 10, 2.1 10, 3 Pro 5, 2.5 Flash Image 3, none for Flash Lite and custom IDs (section 2.5). It never blocks Send.

### 4.9 Export pipeline (original bytes)
- `ImageFile: Transferable` wraps `(url, utType, suggestedName)`. `transferRepresentation` is **static**, so it can't use the instance's `utType` as the content type. Instead it declares one `FileRepresentation(exportedContentType:)` per output type the app can store (`.jpeg`, `.png`, `.webp`, `.heic`, `.heif`, `.gif`, `.avif`), each gated with `.exportingCondition { $0.utType == <that type> }`, and each returns the **original file URL** using `SentTransferredFile(url, allowAccessingOriginalFile: false)`. So Share and Files see exactly one representation, with the real type. The system copies the file.
- Suggested names look like `ImageGen-2026-10-15-1432-<6-char id>.<ext>`.
- **Save to Photos (`PhotoLibrarySaver`)**
  1. `await PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
  2. In `performChanges`, call `PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: original, options: opts)`, with `opts.originalFilename` set to the suggested name and `shouldMoveFile = false`.
  3. This uses the original bytes and type. It never uses `UIImageWriteToSavedPhotosAlbum` or `UIImage`.
  4. If permission is denied, an alert offers Open Settings.
  5. On success, a "Saved to Photos" toast and haptic.
  6. **Info.plist:** `NSPhotoLibraryAddUsageDescription`.
- **Save to Files:** `.fileExporter(isPresented:document: ImageFileDocument, contentType: utType, defaultFilename:)`, where `ImageFileDocument` is a `FileDocument` whose `FileWrapper(url:)` reads the original file and carries the suggested name (the `Transferable` item form crashed on iOS 26.5). It reports success or error with a toast; a cancel arrives as `CocoaError.userCancelled`.
- **Share:** a `Button` that presents `ActivityShareSheet`, a `UIViewControllerRepresentable` around `UIActivityViewController`. Its single item is an `NSItemProvider` with the `ImageFile` registered (`register(_:)` for `Transferable`), so the share sheet sees the same one representation, with the real type, as Files does. It isn't a `ShareLink`, because `ShareLink` reports neither the tap nor the outcome; the controller's `completionWithItemsHandler` gives the activity type, whether it completed, and any error, which the Share action logs (section 4.13).
- **Copy:** `UIPasteboard.general.setItems([[utType.identifier: originalData]])`, with only the original type. There's no `UIImage` conversion, so no re-encode.

### 4.10 Keychain
- `KeychainStore` stores a generic password: `kSecAttrService = "<bundleID>.gemini"`, `kSecAttrAccount = "api-key"`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with no iCloud sync.
- API: `read() throws -> String?`, `save(_:) throws` (update or add), `delete() throws`. It's `Sendable`, a struct with no state.
- It conforms to `protocol APIKeyStore: Sendable { read(); save(_:); delete() }`. Onboarding, Settings (Replace and Remove Key) and `GenerationService` use only the protocol. The other conformer is `InMemoryKeyStore` (state behind a `Mutex`), used by unit tests and DEBUG mock mode, so those never touch the real Keychain.
- The key is read only by `GeminiEndpoint` at request-build time and by onboarding validation. It's never kept in `AppSettings`, SwiftData, logs or the Details text.

### 4.11 Notifications
- `NotificationPoster` posts `UNNotificationRequest(trigger: nil)` on a terminal state, unless the app is active and that chat is on screen, or the Settings toggle "Notify when a generation finishes in the background" (`notifyOnBackgroundCompletion`, read nonisolated like the other defaults) is off.
  - It checks `AppActivity`, a `Mutex<(isActive: Bool, visibleConversationID: UUID?)>` that the main actor updates from `scenePhase` and `ChatView.onAppear` / `onDisappear`.
  - Content: the title is the chat title. The body is "Image ready", the first 80 characters of the text for a text-only reply, "Request refused: <reason>" (for example "Request refused: IMAGE_SAFETY"), or "Generation failed: <short>".
  - `threadIdentifier` is the conversation ID, so notifications group by chat. `userInfo` holds the conversation ID.
- `AppDelegate` acts as `UNUserNotificationCenterDelegate`:
  - `willPresent` returns `[.banner, .sound]` for chats that aren't visible;
  - `didReceive` sends the conversation ID to `NotificationRouter`, which pushes the chat.
- Authorization (`.alert, .sound`) is requested on first send. When it's denied, the app works normally, and Settings shows the status.

### 4.12 Markdown text
`MarkdownBlocks` is a small in-house block parser:
- It handles ATX headings, `-`/`*`/`1.` lists, fenced code, block quotes and paragraphs.
- Inline styling inside each block uses `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)`.
- Text is selectable with `.textSelection(.enabled)`.
- Links are tappable and open in Safari.
- Images in the Markdown are not rendered.

### 4.13 Activity log
The activity log is for debugging. Every operation the app performs, whether the user or the system started it, is an **action**. Before it does anything, the app logs what is about to happen with all its operative parameters; when it ends, the app logs the result. The Developer menu shows the log (section 3.10).

**Model** (types in `Support/ActivityLogTypes.swift`)
- An action has:
  - an **ID** of 4 lowercase hex digits (`ActionID`). It's the next value of a 16-bit counter, multiplied by an odd constant modulo 2^16 so consecutive IDs look different. The counter is kept in the facade's memory, not in `UserDefaults` (which persists asynchronously, so a kill could lose increments whose entries are already in the file). Instead, the facade seeds it from the file at init: it reads the file's tail (the last 64 KB, and further back only if that holds no begin entry), takes the newest begin entry, inverts the multiplication to get that entry's counter value, and continues from the next one; with no file it starts at 0. An ID that is in the file is therefore never handed out again, and only an ID a killed process never wrote can be reused. Code that stores an ID outside the log (`GenerationRequest.activityActionID`) first awaits `flush()` (Storage and writing, below), so a stored ID always has its begin in the file. IDs are unique among the last 65,536 actions, more than the size-capped file can hold, so an ID names one action within the file. Clearing the log doesn't reset the counter: the Log cleared begin carries it forward;
  - a **name** from the table below ("Send", "Save to Photos", …);
  - an **origin**, `user` or `system`;
  - an optional **parent**. Sub-actions, such as preparing an attachment, preparing a request body, one HTTP attempt or parsing a response, belong to the action that started them.
- An **entry** (`ActivityEntry`) is `{timestamp, actionID, parentID?, name, kind, origin?, outcome?, relatedID?, message}`:
  - `kind` is `begin`, `step` or `result`;
  - `name` is on every entry. The facade sets it for actions it began; for an action adopted from an earlier process (Continuing across processes, below) the store fills it in from its action index;
  - `origin` is set on begin entries only. A caller passes it only for a top-level action; for a sub-action the store copies the parent's origin from its index, which works for parents adopted from an earlier process too;
  - `outcome` is set on result entries only: `success`, `failed`, `refused`, `cancelled` or `interrupted`;
  - `relatedID` is set only on a Late completion's begin: the action of the request it completes;
  - `timestamp` is ISO 8601 with milliseconds.
- **Pairing.** Every action has exactly one begin and exactly one result; steps are optional.
  - A second result for the same action is dropped and reported under the OSLog `store` category.
  - A parent whose sub-actions run asynchronously waits for them before it ends: Attach ends after its last Prepare attachment, and Edit and Resend after its last re-prepare. (A tray item removed while it's being prepared ends its Prepare attachment `cancelled`.) A refresh that follows a key save isn't a sub-action at all: it's its own Models refresh action (table below).
  - If an action's result is written while one of its sub-actions is still open anyway, which is a bug, the store first writes `Result: interrupted · parent finished first` for that sub-action. This is a backstop, not a mechanism: the plan's tests assert that no component's normal path triggers it.
  - A result is guaranteed even when the process is killed: at the next launch the Reconciler closes actions a previous process left open with outcome `interrupted` (section 4.7), except an action still following a non-terminal request (Continuing across processes, below). Rotation and Clear never drop the begin of an open action (Storage and writing, below), so the file always shows which actions are open.
- **Outcomes.** What each outcome means, so Last Error finds what needs attention:
  - `success`: the action did all of its job. A sub-action that failed but was recovered from, such as an Attempt 1 ending HTTP 429 before a successful Attempt 2, doesn't change the parent's outcome.
  - `failed`: it didn't, including a partial failure. An action that handles several items (Attach, Edit and Resend, Delete chat, Delete all chats, Clear thumbnail cache, Janitor) ends `failed` when any item failed, and its result gives the counts of what did succeed, for example `failed in 1.9 s · 2 of 3 imported and prepared · 1 failed: unsupported type public.svg-image`. So a failed Prepare attachment always surfaces in Last Error through its Attach. Items dropped over the 14-image cap are a limit, not a failure: a step and a count in a `success` result.
  - `refused`: the API refused the request (section 2.7 rules 3 and 6).
  - `cancelled`: the user stopped it or dismissed the picker, the exporter or the share sheet.
  - `interrupted`: the process ended, or the system ended the work (a background-task expiry, a system cancel).
  - A Send, Regenerate or Retry ends with its request's terminal state: `succeeded` → `success` (a text-only reply included); `refused` → `refused`; `failed` → `failed`; `empty` (no content, section 2.7 rules 4 and 7) → **`failed`**, with `empty reply` and the finish reason, so an empty reply shows in Last Error; `cancelled` → `cancelled`; `interrupted` → `interrupted`. Parse ends `success`, `refused`, or `failed` for the empty, API error and malformed classes.

**Messages.** Terse natural language, one line.
- **Begin** states what is about to happen and **every** operative parameter: the values that decide what the action does.
- **Result** starts with the outcome word, then the key measurements: duration, HTTP status, sizes, counts, finish reason, refusal reason, error status and message.
- **Steps** record notable intermediate facts: a decision and its reason, a task resumed, a file written.
- Conventions:
  - IDs of records are the first 4 hex digits of the UUID (`img 7f3a`, `req 3f9c`, `chat 08d1`);
  - sizes in MB with one decimal;
  - durations in seconds with one decimal;
  - pixel sizes as `W×H`;
  - API values spelled as the API spells them (`16:9`, `2K`, `BLOCK_NONE`, `IMAGE_OTHER`);
  - the prompt in full, in quotes;
  - fields joined with ` · `.
- Callers build messages with `ActivityMessage`, a string-interpolation type: `"prompt \(private: quoted(prompt))"` marks a segment private for the OSLog mirror. Every piece of user-entered or user-derived text is private: the prompt, chat titles (an automatic title is the start of the first prompt, section 3.3), old and new titles in a rename, message text, copied text, custom model IDs as typed, and API messages and error bodies.
- An input is described by its origin: an upload as `upload img 7f3a, <original W×H MIME MB> → sent <prepared W×H MIME MB>` (or `→ prepare at 2048` when the sent file isn't made yet); a model output, which is sent as its original bytes (section 4.8), as `model output img 9e41, 2752×1536 PNG 6.4 MB, sent as original`.

Examples (as the viewer shows them):

```
14:02:11.384 [Send a1b2] Begin: gemini-3.1-flash-image · 16:9 · 2K · safety BLOCK_NONE · modalities TEXT+IMAGE · input latest (upload img 7f3a, 2752×1536 PNG 6.1 MB → sent 2048×1143 JPEG 0.9 MB) · prompt "make the sky purple"
14:02:11.390   [Prepare request 3c5e] Begin: 1 input · budget 19.0 MB · max long edge 2048 · img 7f3a: reuse prepared file (made at 2048)
14:02:11.396   [Prepare request 3c5e] Result: success in 0.0 s · body.json 1.3 MB · no shrink
14:02:11.398   [Attempt 1 9d21] Begin: POST /v1beta/models/gemini-3.1-flash-image:generateContent · body 1.3 MB · background session · timeouts 300 s idle, 1800 s total · expect ~8 MB
14:02:11.402   [Attempt 1 9d21] Step: upload task 17 resumed
14:02:25.540   [Attempt 1 9d21] Result: success in 14.1 s · HTTP 200 · received 8.6 MB
14:02:25.542   [Parse 5e0f] Begin: HTTP 200 · response-1.part 8.6 MB
14:02:25.590   [Parse 5e0f] Result: success in 0.0 s · 1 image 2752×1536 PNG 6.4 MB · 1 text run (42 chars) · finish STOP
14:02:25.598 [Send a1b2] Step: saved reply: 1 image; request succeeded
14:02:25.599 [Send a1b2] Step: notification not posted: chat is on screen
14:02:25.601 [Send a1b2] Result: success in 14.2 s · HTTP 200 · 1 image 2752×1536 PNG 6.4 MB · 1 text run (42 chars) · finish STOP
14:03:40.210 [Send 4be7] Step: auto-retry 1/2 in 2.0 s: HTTP 429 RESOURCE_EXHAUSTED (RetryInfo 2s)
14:05:12.007 [Send c9d0] Result: refused · IMAGE_OTHER · HTTP 200 in 9.8 s
14:06:30.412 [Send 77c1] Result: failed · empty reply · finish MAX_TOKENS · HTTP 200 in 6.3 s
14:07:02.118 [Attach 2f80] Result: failed in 1.9 s · 2 of 3 imported and prepared · 1 failed: unsupported type public.svg-image
09:15:00.020 [Save to Photos 61aa] Result: interrupted · the app was closed before this finished
```

**What is logged.** Each row is an action name; the parent column names sub-actions. "every parameter" means the full list in the row.

**Logged Actions and Telemetry Scopes**:

- **Application Lifecycle Operations**:
  - *Launch (system origin)*: Records application version, operating system environment, test flags, store initialization metrics, background session recreation, and reconciliation task dispatch. Concludes at completion of `didFinishLaunching`.
  - *Reconcile (system origin)*: Records evaluation of non-terminal requests, active task audit, orphan response re-parsing, and resolution of interrupted operations.
  - *Background Events (system origin)*: Logs session identifiers, background completion throughput, and notification relay latency prior to invoking system handlers.
  - *Janitor (system origin)*: Records maintenance execution parameters, age/size eviction thresholds, file deletion counts across cache directories, and freed storage space.
- **Credential and Model Configuration Operations**:
  - *Save API Key / Validate Key / Remove API Key (user origin)*: Records key configuration entry points, validation endpoints, model count discoveries, and Keychain transaction outcomes without logging sensitive credential bytes or token lengths.
  - *Models Refresh (user or system origin)*: Records catalog availability queries, pagination traversal, model capability delta checks, and timestamp updates.
  - *Add Custom Model (user origin)*: Records custom endpoint identifier verification and catalog registration outcomes.
  - *Settings & Chat Setting Change (user origin)*: Records modifications to global and per-conversation defaults (model, aspect ratio, image size, safety thresholds), capturing parameter coercion and persistence outcomes.
- **Composer and Media Attachment Operations**:
  - *Attach / Prepare Attachment / Tray Change (user origin)*: Records media import sources, asset counts, dimension ceilings, format conversions, EXIF/GPS scrubbing, and tray reordering or eviction.
- **Generation Pipeline Operations**:
  - *Send, Regenerate, and Retry (user origin)*: Top-level generation actions capturing operative model identifiers, aspect ratios, image dimensions, safety rules, input baseline arbitration, prompt lengths, and terminal outcomes.
  - *Prepare Request (pipeline child action)*: Records payload serialization, budget calculation, and progressive input downscaling.
  - *Attempt n (pipeline child action)*: Records HTTP endpoint invocation, payload transmission size, session category, transport timing, status codes, received bytes, and cancellation reasons.
  - *Parse (pipeline child action)*: Evaluates response JSON, extracting typed parts, structured finish reasons, safety refusal descriptions, and API diagnostics.
  - *Late Completion (system origin)*: Handles deferred response delivery for previously interrupted requests, linking to historical operation IDs.
  - *Cancel (user origin)*: Records explicit user cancellation signals and transport task abortion.
- **Export, Clipboard, and Message Management Operations**:
  - *Save to Photos / Save to Files / Share / Copy (user origin)*: Records asset identifiers, MIME types, byte sizes, system authorization statuses, and transfer targets.
  - *Pin / Unpin (user origin)*: Records baseline image selection for subsequent conversational turns.
  - *Edit and Resend (user origin)*: Records prompt restoration, APFS attachment duplication, and baseline pin re-establishment.
  - *Delete Message / New Chat / Rename Chat / Delete Chat / Delete Empty Chat / Delete All Chats (user or system origin)*: Records record removals, associated on-disk file purging, and active task cancellations.
  - *Clear Log (user origin)*: Records log truncation metrics while preserving headers for active in-flight operations.

Not logged: opening, copying and sharing the log (so viewing it never changes Last Action), navigation, scrolling and typing.

**Continuing across processes.** A generation request can finish in a later process (section 4.6), and its action should end with what really happened to it.
- `GenerationRequest.activityActionID` (section 4.3) records the action that follows the request. A relaunched process adopts that ID, so the completion, the parse, the save and the result are logged under the original action, with a step noting the relaunch.
- An HTTP attempt sub-action opened by the earlier process is closed by name, with `result(ofOpenChild: "Attempt 2", of: id, …)`; the store resolves it. The facade doesn't know an adopted action's name or origin, so it leaves them empty. The store fills them in from its action index (Storage and writing, below) before it writes the entry and mirrors it to OSLog, and a sub-action begun under an adopted parent (a Parse, or a new Attempt after the relaunch) takes the parent's origin the same way.
- A completion that arrives after its request was marked `interrupted` (and its action closed) is logged as a new top-level Late completion action whose begin names the request and carries the original action's ID as `relatedID`. It ends with the request's real outcome. The viewer shows it after the original action's lines wherever that action is shown (section 3.10). Last Error judges the original action by its newest Late completion, so a request that was marked interrupted but then succeeded drops out of Last Error. A late completion that fails keeps the original action in Last Error and shows why.

**Storage and writing**
- `Application Support/ImageGen/Logs/activity.jsonl`: JSON Lines, one entry per line, UTF-8.
  - Data protection `completeUntilFirstUserAuthentication`, so background relaunches can write. The `Logs/` directory, the file and every temporary file the store writes are created with that class passed explicitly.
  - Excluded from backup, so the log stays on this device. `isExcludedFromBackup` is a per-item resource value that doesn't survive replacing a file, so the store sets it on the `Logs/` directory (which excludes everything in it) and sets it again on `activity.jsonl` after every create, rotation swap and clear. Nothing uploads the log; it leaves the device only when the user copies or shares it from the viewer.
- **Writing.** `ActivityLog` is the facade: a `final class` that is `Sendable`, with its state in a `Mutex`, callable from any isolation. Its calls are synchronous; they never await, and they hold the lock only briefly.
  - Before taking the lock, a call sanitizes and renders its message on the caller's thread. That's the costly part (a regex pass over a prompt of any length), and it needs no lock.
  - Under the lock, a call only takes the next ID (for a begin), stamps the timestamp and yields the entry into one ordered, unbounded `AsyncStream`, the same pattern as the transport events (section 4.6). So file order is the order calls took the lock, and timestamps never go backwards in the file. Nothing else happens under the lock: no `UserDefaults`, no file I/O and no OSLog call.
  - At init, the facade makes one synchronous, bounded pass over the file's tail. If a crash cut the last line short, it truncates the file back to the last newline, so this process's first entry starts on a line of its own instead of being glued to the fragment. It also seeds the ID counter (Model, above).
  - The `ActivityLogStore` actor is the stream's only consumer and the file's only writer. It appends each entry as one line with a single `write`; there's no fsync per entry, so an entry that has been written survives the app being suspended or killed, though not a power loss.
  - **Control messages travel in the same stream.** `flush()`, `entries(…)`, `openActionsAtLaunch()` and `clear()` don't call the actor directly. Each yields a control message that carries a continuation into the same stream as the entries, and the store answers it when it reaches it. So `entries()` sees every call made before it, and an entry logged before a Clear can never land after the Log cleared action.
  - **The action index.** On load, the store reads the file once and builds an index with one record per action: name, origin, parent, open or closed, outcome, `relatedID`, and the sequence number and byte offset of its first entry. It also keeps a sparse table of sequence numbers to byte offsets, one per 256 entries. It keeps this index, about 100 bytes per action, and not the entries. It updates the index with each entry it writes, uses it to fill in names and origins and to pair results, and answers queries from it. The actions open in the index when it loaded the file, before this process's first entry, are the set `openActionsAtLaunch()` returns to the Reconciler.
- **Flushing before suspension.** A facade call only yields into the stream; the store writes the entry a moment later. If the OS suspends the app in between and then kills it, which is common after a background relaunch, the entry is lost, and the next launch would close a finished action as `interrupted`. So `flush() async` returns once every entry yielded before it is written. It's awaited, with a 1 s cap so a stuck write can't hold things up:
  - by `BackgroundEventsRelay.callAndClear`, after it logs the Background events result and before it calls the system completion handler;
  - by `BackgroundTaskProvider` before it ends any background-task assertion, including in the expiry handler, where the result is logged first and the flush is capped at 0.5 s;
  - by the scene's move to the background, under a short background-task assertion of its own;
  - before an ID is stored outside the log (`GenerationRequest.activityActionID`, Model, above).
- **Size cap.** When the file passes 4 MB, the store rewrites it with the newest whole entries totalling at most 2 MB. It also keeps the begin entry of every action that is still open, even when it's older than that window, in file order ahead of the rest. Without that, an open action's begin could rotate out: the action would lose its name and origin, Last Action couldn't classify it, and if the process then died nobody would close it. The store writes a temporary file and swaps it in atomically, and never splits an entry.
- **Clear.** Clear Log is a control message, so every entry logged before it is written first. The store then replaces the file with one that holds, oldest first, the begin entries of the actions still open (a Send in flight, or one kept open across a relaunch while its request is `retryScheduled` or `inFlight`, with their open sub-actions), followed by the Log cleared action, whose Begin states the size and entry count removed and the open actions kept. The index keeps those actions open, so their later steps and result get their names and pair correctly, and `openActionsAtLaunch()` still finds them after a relaunch. With nothing open, the new file holds only the Log cleared action.
- **`-ResetStore 1`** (DEBUG) doesn't use Clear. `AppEnvironment` deletes `Logs/`, along with the store and files, before it creates the `ActivityLog` (section 4.2). So the run's log starts with its own Launch Begin, and there's no Log cleared action that nobody tapped.
- Delete All Chats doesn't clear the log; Clear Log does.
- **Live updates and reading.**
  - `ActivityLog.changes()` returns an `AsyncStream<ActivityLogStatus>`, coalesced, with one value after each write. A status holds the newest entry's sequence number and the IDs that Last Action and Last Error would pick (nil when none), computed from the index. `DeveloperMenuModel` keeps the latest one for the menu's disabled state.
  - Opening a view is one read. Last Action and Last Error read from the byte offset of the chosen action's first entry to the end of the file, and keep that action's tree and its Late completions. Full Log decodes the whole file, at most 4 MB, once and off the main actor.
  - A refresh then calls `entries(after:)` with the last sequence number seen, which reads only the newer entries. The viewer appends the ones that belong to the view it's showing, and doesn't re-run the selection (section 3.10).

**OSLog mirror.** The store, not the facade, writes each entry to `Logger` as it writes it to the file, after it has filled in the name and origin. So the mirror holds exactly the file's entries: the ones the store writes itself (the backstop's `interrupted` results) are included, and a dropped second result isn't. Each entry goes to one of the existing categories, chosen by the action's name:
- `pipeline`: Send, Regenerate, Retry, Cancel, Edit and Resend, Prepare request, Parse, Reconcile, Late completion;
- `transport`: Attempt, Background events, Models refresh, Validate key, Add custom model;
- `imaging`: Attach, Prepare attachment, Tray change;
- `store`: everything else (Launch, chats, messages, pins, chat and app settings, key storage, exports, Notification permission, Janitor, Log cleared).

Segments marked `\(private:)`, which are all user-entered or user-derived text (the prompt, chat titles, message and copied text, typed custom model IDs) and API messages (Messages, above), go through a `privacy: .private` interpolation; the rest of the line is public. The file holds the full text. The stream carries each message as its sanitized segments, so the store can render both the file text and the mirror's public and private parts.

**Redaction.** Before it takes the lock, every message passes through the injected sanitizer, `Redactor.forLog(secrets:)` (section 4.1). The guarantees:
- Never the API key. Callers never pass it, and `forLog` removes it wherever it appears, whatever the route: a key pasted into a prompt, an API or `URLError` message that echoes it, a key typed into the custom model ID field. It replaces with `<key removed>`:
  - every registered secret. The `SecretRegistry` (`Security/`, a `Mutex`-protected set) holds the stored key, registered when `APIKeyStore` reads or saves it, and a typed key, registered before it's validated. Secrets stay registered for the life of the process, so a removed key is still scrubbed;
  - any text shaped like a Gemini key (`AIza` followed by 35 characters from `[0-9A-Za-z_-]`);
  - any `key=` query value.
- Never headers: callers never pass request or response headers, and `forLog` drops any `x-goog-api-key` text. A `Retry-After` value appears only as the delay it produced.
- Never image bytes or base64: `forLog` replaces `inlineData.data` and `thoughtSignature` values and any base64-like run of 100 or more characters with `<N chars removed>`. A prompt that itself holds such a run, or something shaped like a key, is the only case where the logged prompt differs from the sent one.
- API error bodies are truncated to 2 KB (`Redactor.errorBodyForLog`), with a note of the bytes cut.

A test injects a sentinel key and asserts that it never appears in the log file or in the strings passed to OSLog, whether it arrives as a `key=` echo, in a prompt, in an error message without `key=`, or in the custom model ID field (section 9).

**Queries** (`ActivityLogQuery`, pure): `lastAction` and `lastError` pick an action ID from the index's action records, as defined in section 3.10 (Last Error judging an interrupted action by its newest Late completion). `tree(_:in:)` takes entries in file order and returns the chosen top-level action, all its sub-actions and its Late completions, and `all` returns every entry; an open action is marked in progress. `ActivityLogFormatter` turns entries into the viewer's lines.

---

## 5. Concurrency model (Swift 6)
- **Build settings:**
  - `SWIFT_VERSION = 6.0`, with complete strict concurrency implied.
  - `SWIFT_DEFAULT_ACTOR_ISOLATION` is set **explicitly** to `nonisolated` in `project.yml`. XcodeGen doesn't add the Xcode 26 template's MainActor default anyway, but setting it explicitly protects against toolchain default changes and keeps `@Model` and `@ModelActor` compatible.
  - Approachable-concurrency flags are not enabled. Hops are explicit.

### 5.1 Component Isolation and Actor Architecture

- **Presentation Domain (`@MainActor`)**: Views, `@Observable` view models (`ChatScreenModel`, `AppSettings`, `ModelAvailability`, `LogViewerModel`, `DeveloperMenuModel`), and platform presentation coordinators (`BackgroundEventsRelay`, `NotificationRouter`) execute exclusively on the main actor to guarantee thread-safe UI updates.
- **Relational Domain Models (`@Model`)**: SwiftData entity classes are nonisolated and non-Sendable, confined strictly to the internal `ModelContext` of `DataStore`.
- **Persistence Store (`DataStore`)**: Implements `ModelActor` to bind database mutations to an isolated serial executor. External callers interact exclusively via detached Sendable snapshot structs (`RequestSnapshot`, `InputSnapshot`).
- **Generation Service (`GenerationService`)**: An actor providing authoritative synchronization for generation lifecycles and state transitions. Consumes the transport event stream sequentially to ensure deterministic execution.
- **Transport Subsystem (`URLSessionTransport`, `ResponseAccumulator`)**: Thread-safe Sendable reference types utilizing internal `Synchronization.Mutex` primitives. Delegate callbacks execute on a private serial `OperationQueue`, writing incoming data synchronously and emitting events into a single ordered `AsyncStream`.
- **System and Lifecycle Services (`ConnectivityMonitor`, `BackgroundTaskProvider`)**: Thread-safe coordinators exposing state changes via `@MainActor` callbacks while interfacing with system APIs.
- **Stateless Computational Operations**: Image preprocessing, response parsing, request body serialization, and thumbnail generation execute as nonisolated, concurrent asynchronous routines off the main thread, operating on immutable Sendable inputs.
- **Pure Domain Rules and Utilities**: Configuration resolvers, endpoint builders, retry policies, and input selection heuristics are implemented as deterministic, pure value types.
- **Application Activity Monitoring (`AppActivity`)**: A thread-safe class utilizing mutual exclusion locks to bridge synchronous lifecycle checks across concurrency boundaries.
- **Diagnostic Logging Subsystem**: `ActivityLog` operates as a nonisolated thread-safe facade accepting synchronous logging invocations across any thread context, dispatching serialized events to an actor-isolated `ActivityLogStore` for persistence and rotation.
- **Secret Registry (`SecretRegistry`)**: Thread-safe reference type protected by `Mutex`, allowing lock-free reads during message sanitization across concurrent tasks.

- **The Sendable boundary for a send.** The MainActor builds a `SendDraft`:
  - `conversationID`, `promptText`, `[StagedAttachment]` (with URLs and prepared metadata);
  - plus the `EffectiveSettings` resolved at tap time (model, aspect, size, threshold, categories, modalities).
  
  The draft is then handed to `GenerationService`. Nothing non-Sendable crosses actors.
- **Settings written from the actor.** `GenerationService` never writes `UserDefaults` directly. When the CIVIC fallback fires, it calls an injected `@Sendable () async -> Void` that runs on the main actor and sets `AppSettings.omitCivicIntegrity = true`; `didSet` persists it. The main-actor copy is therefore never stale, and the next send from an open chat resolves four categories. Background code that only needs to read the defaults (Regenerate, Retry rebuilds) uses `AppSettings.readDefaults(UserDefaults)`, a nonisolated read. The activity log keeps nothing in `UserDefaults`: its ID counter is seeded from the log file (section 4.13), so logging from an actor never writes defaults.
- **Cancellation.** `Task` cancellation is checked between budget-shrink iterations and before starting a task. Network cancellation always goes through `URLSessionTask.cancel()`.

---

## 6. Error handling and edge cases

### 6.1 Systematic Error Categorization and Recovery

- **Authentication and Authorization Errors**:
  - *Missing API Key (Condition 1)*: Detected when Keychain contains no credential at launch or request submission. Surfaces onboarding or prompts to configure credentials in Settings. Recovered by saving a valid key and retrying.
  - *Invalid or Rejected Key (Condition 2)*: Detected via HTTP 400 (`API_KEY_INVALID`), 401, or 403. Displays an error card with provider diagnostic message and Settings deep link. Recovered by replacing the key.
  - *Account Limitation (`PUP_LIMITED_DISABLED`, Condition 13)*: Detected via safety refusal payload. Displays an error card noting account limitations. Recovery is restricted to Edit or New Chat; automatic retries are suppressed.
- **Request Configuration and Model Errors**:
  - *Invalid Parameter Configuration (Condition 3)*: Detected via HTTP 400 (`INVALID_ARGUMENT`). Displays API error diagnostics alongside transmitted parameters. Recovered by adjusting overrides and re-submitting.
  - *Deprecated Safety Category (`CIVIC_INTEGRITY`, Condition 4)*: Detected via HTTP 400 referencing the category. Triggers an automatic single-request rebuild omitting the category and persists the exclusion flag.
  - *Model Deprecation or Missing Endpoint (Condition 7)*: Detected via HTTP 404 (`NOT_FOUND`). Displays a model error card offering navigation to model configuration settings.
- **Quota and Resource Constraints**:
  - *Rate Limiting and Quota Exhaustion (Condition 8)*: Detected via HTTP 429 (`RESOURCE_EXHAUSTED`). Displays a countdown indicator during automatic retries, presenting an error card upon retry exhaustion.
  - *Billing Constraints and Prepayment Depletion (Conditions 5, 6)*: Detected via HTTP 400 (`FAILED_PRECONDITION`) or 402. Displays an error card indicating credit or billing exhaustion.
  - *Payload Capacity Exceeded (Condition 19)*: Detected prior to network dispatch if serialized body size exceeds 19 MB following downscaling. Surfaces a warning alert preventing submission until attachments or dimension settings are reduced.
- **Transient Transport and Network Faults**:
  - *Server Errors (Condition 9)*: Detected via HTTP 500, 502, 503, 504, or 408. Managed via automatic exponential backoff retries within the attempt budget, surfacing error cards upon exhaustion.
  - *Network Disconnection and Offline Transitions (Condition 10)*: Monitored via `ConnectivityMonitor` and background URLSession connectivity suspension. Displays network waiting indicators while deferring to the 30-minute overall resource timeout before failing with a retryable timeout card.
  - *Idle Request Timeout (Condition 11)*: Detected via `URLError.timedOut` prior to resource timeout exhaustion. Automatically retried within the attempt budget before presenting a manual retry card.
  - *Truncated or Zero-Byte Response (Condition 33)*: Detected upon transport completion with status 200 but an empty or missing response payload file. Automatically retried within the attempt budget.
- **Model Output and Parsing Anomalies**:
  - *Safety and Content Refusals (Condition 12)*: Detected via prompt block reasons or candidate finish reasons other than normal completion. Displays a refusal card with the exact API reason, providing Retry, Edit, and New Chat actions.
  - *Empty Output or Text-Only Replies (Conditions 14, 15)*: Detected when candidates contain no valid image parts. Displays appropriate diagnostic badges and finish reasons, allowing manual retry or regeneration.
  - *Malformed or Non-JSON Response (Condition 16)*: Detected via JSON decoding failure. Surfaces an unexpected response error card with raw payload details.
  - *Corrupt Image Payload (Condition 17)*: Detected when image decoding fails for an output block. Presents remaining valid parts accompanied by a non-blocking diagnostic notice.
  - *Unmet Resolution Expectations (Condition 18)*: Flagged on metadata displays if synthesized dimensions deviate from requested parameters.
- **Attachment and Asset State Transitions**:
  - *Attachment Import Failures (Condition 20)*: Displays inline warning badges on invalid tray items and blocks dispatch until resolved.
  - *Attachment Overflow (Condition 21)*: Constrains selection to the 14-image limit, surfacing diagnostic notifications when exceeded.
  - *Pinned or Baseline Asset Deletion (Conditions 22, 23)*: Falls back gracefully to preceding conversation baselines or disables regeneration if source dependencies are purged.
  - *Stale Prepared Attachments (Condition 22a)*: Automatically re-prepares image files from originals if dimension thresholds change.
- **Lifecycle, Storage, and System Interruption Faults**:
  - *Process Termination or System Cancellation (Condition 25)*: Detected by `Reconciler` during launch checks when active tasks are absent or cancelled externally. Transitions request state to interrupted, offering manual retry.
  - *Local Storage Exhaustion (Condition 27)*: Detected via `NSFileWriteOutOfSpaceError` during asset persistence. Retains the response payload on disk and displays a storage exhaustion card allowing retry after disk space is cleared.
  - *Crash During Response Parsing (Condition 26)*: Detected during launch reconciliation by the presence of a `.complete` marker file, triggering automatic re-parsing.
  - *In-Flight Deletion or Credential Removal (Conditions 24, 28, 29)*: Cancels active network tasks cleanly or allows current in-flight transfers to finalize before enforcing credential boundaries.
  - *Permission Denials (Conditions 30, 31)*: Directs users to system privacy settings without interrupting application workflow.
  - *UI Concurrency Protection (Condition 32)*: Disables submission controls during active request preparation.
  - *Empty Title Reversion (Condition 34)*: Restores default conversation titles if renamed to whitespace.

**Retry policy (`RetryPolicy`, pure):**
- **Inputs.** `decide(result, autoRetriesUsed:, civicWasSent:, civicFallbackUsed:)`. The counters come from the persisted request (`autoRetriesUsed`, `civicFallbackUsed`, section 4.3), never from memory, so the policy is correct after a relaunch between retries. A transport result carries the elapsed time since the attempt's task began.
- **Retryable**, all sharing **one budget of 2 automatic retries** (so at most 3 automatic attempts):
  - HTTP 408, 429, 500, 502, 503 and 504;
  - `URLError.timedOut` when the elapsed time is under `timeoutIntervalForResource` (1800 s), which is the 300 s idle timeout (#11);
  - `URLError` codes `.networkConnectionLost`, `.notConnectedToInternet` and `.cannotConnectToHost` (on the background session these are rare, because it waits for connectivity itself);
  - an empty body on a 200 (#33).
- **Not retryable:** `URLError.timedOut` with at least 1800 s elapsed (the resource timeout, #10), every other 4xx including 402, cancellations, and parse failures from a non-empty body.
- **Refusals are never retried automatically** (#12, #13). A refusal arrives as a 2xx with a non-empty body, which the policy always finishes; it is then parsed as `.refused` and stored as `refused`. It never uses the retry budget and never triggers the CIVIC fallback. Retrying is the user's choice from the card.
- **Special case, CIVIC_INTEGRITY fallback (section 2.4).** A 400 `INVALID_ARGUMENT` whose message mentions `CIVIC_INTEGRITY`, on a request that sent that category and whose `civicFallbackUsed` is false, gives the decision `rebuildWithoutCivicAndRetry`. The body is rebuilt with four categories and resent at once, and `civicFallbackUsed` is set. It happens at most once per request, and doesn't count against the automatic retry budget.
- **Delay:**
  - if a `google.rpc.RetryInfo.retryDelay` (`"30s"`) appears in `error.details`, or a `Retry-After` header is present, honor it, capped at 60 s;
  - otherwise use `base × 2^autoRetriesUsed` (2 s for the first automatic retry, 4 s for the second), with base 2 s, plus 0–1 s of jitter.
- **Mechanism:** a new upload task from the same `body.json`, with `earliestBegin = now + delay` (section 4.6, Retries). `attempt` and `autoRetriesUsed` both go up by one (the CIVIC rebuild raises only `attempt`), and `nextAttemptAt` is recorded.
- **Retries created in the background are best-effort.** iOS honors `isDiscretionary = false` only for tasks created while the app is in the foreground. A retry task created during a background wake (from a 429/5xx, timeout, empty-200 or CIVIC completion) is treated as discretionary, and the system may defer it, for example until the device is on Wi-Fi or power. Such a request records `nextAttemptCreatedInBackground = true`, and its card reads "Retry scheduled (attempt N/3)" with no countdown. When the app becomes active (`scenePhase == .active`), `GenerationService` takes every `retryScheduled` request with that flag whose task hasn't begun, cancels the task, and recreates it in the foreground with `earliestBegin = max(now, nextAttemptAt)` and the flag cleared, so it runs promptly. Only a task still recorded on the request and still waiting (live, nothing sent) is replaced: one that began or finished while the app was suspended keeps its result. The new task gets the next attempt number, so the replaced task's cancellation, and any event it already queued, fail the attempt check and never touch the new attempt's response file. Activations in quick succession run these passes one after another.
- **Manual Retry** on a terminal card starts a new attempt of the same request: `attempt += 1`, `autoRetriesUsed = 0` (the automatic budget is reset), `civicFallbackUsed` is kept, and the recorded settings and inputs are reused. The body is rebuilt if it was already cleaned up.

**Regenerate vs Retry.** Retry re-runs a request that failed, was interrupted or was refused, in place, in the same reply card. It increments `attempt` and clears the previous outcome's fields (`refusalReason`, `errorStatus`, `errorMessage`, `finishReason`, `details`, notices) before the new attempt, so a refused request that succeeds on Retry is `succeeded` with no stale refusal. Regenerate creates a new reply from a request's recorded inputs and settings, and keeps all earlier results.
- Regenerate reuses the recorded `modelID`, `aspectRatio`, `imageSize`, `safetyThreshold`, `includeTextModality`, prompt and prepared inputs **verbatim**. It does not re-resolve them against the current Settings defaults or the chat's overrides, and does not coerce them again. The one exception: if `omitCivicIntegrity` has been set since, `HARM_CATEGORY_CIVIC_INTEGRITY` is dropped (and the categories actually sent are recorded). The API key is the current one.
- Like Send, Regenerate and Retry are disabled while the chat has a request in flight (one in-flight request per chat, section 4.6).

---

## 7. Security and privacy
- **The API key.** It's stored only in the Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced). It's sent only as the `x-goog-api-key` header to `generativelanguage.googleapis.com` over HTTPS (ATS default, no exceptions). It never appears in a URL, so URLSession and OS logs can't capture it in a URL.
- **Logging.**
  - There are two outputs. The activity log (section 4.13) is a file on the device holding the full prompt text and every operative parameter, shown by the Developer menu (section 3.10). Each entry is mirrored to `Logger` (OSLog) with subsystem `<bundleID>` and categories `pipeline`, `transport`, `store`, `imaging` (plus `smoke` for the opt-in live test).
  - In OSLog, prompts, chat titles and every other piece of user-entered text, and API messages, are logged with `privacy: .private`. Request IDs, states, statuses and sizes are public.
  - Never logged anywhere: the API key, request or response headers, image bytes or base64 (`inlineData`), and thought signatures. API error bodies are cut to 2 KB. `Redactor.forLog(secrets:)` enforces this on every activity-log message: it removes the stored key and any typed key wherever they appear, anything shaped like a Gemini key, and any `key=` value. A test with a sentinel key checks the file and the OSLog strings. A lint rule also flags log calls whose arguments mention the key or the key store; it's a tripwire for mistakes, not the guarantee, which is `forLog`.
  - The activity log stays on the device: `Logs/` is excluded from backup (the flag set on the directory and re-applied to the file after every rotation and clear) and nothing uploads it; it leaves only when the user copies or shares it from the viewer. It keeps prompts after their chat is deleted, until it rotates out or the user taps Clear Log….
  - `Details` text is redacted: base64 data and thought signatures are removed. The key is never in a response body, and a test asserts that.
  - No third-party analytics or crash reporting.
- **Metadata.** EXIF and GPS are removed from uploads before sending, because uploads are always re-encoded. The originals, metadata included, stay on the device for the user's own save and share.
- **Data at rest.** On iOS, data protection with the default class (`completeUntilFirstUserAuthentication`), needed for background writes. Data is included in the device backup, which is encrypted when the user enables it. On the Mac, files sit in the app's sandbox container, protected by the container's permissions and by FileVault when the user has it on; the app adds no encryption of its own, and Time Machine backs the container up under the user's settings. Nothing leaves the device except the requests to Gemini.
- **The pasteboard.** On iOS, reads happen only through the system `PasteButton`, so there's no paste prompt and no reads without user intent. `hasImages` is used only to decide whether to show the button. On the Mac, reads happen only on Cmd-V and Paste Image: pasteboard types are checked first, so an ordinary text paste reads nothing here, and contents are read only when an image or file is present. Whether macOS's pasteboard privacy setting treats these as paste-related hasn't been checked with the setting at Ask.
- **Photos.** Add-only access. The picker runs out of process and needs no read permission.
- **Model output.** Generated images carry a SynthID watermark, a property of the API. This is noted in About.

---

## 8. Performance and memory
- **No full decodes of user photos.** Every downscale and thumbnail uses `CGImageSourceCreateThumbnailAtIndex` with `MaxPixelSize`, which decodes with subsampling. A 48 MP HEIC would decode to about 195 MB in full; the subsampled decode to 2048 px peaks at roughly 20 MB. `UIImage(data:)` on originals is banned; a lint grep is part of the review checklist.
- **Thumbnails.**
  - `ThumbnailService` (an actor) makes 240 px and 1200 px JPEG thumbnails on first request, and larger ones as described below. They're stored in `Caches/Thumbnails` and held in an `NSCache<NSString, UIImage>` with `totalCostLimit = 120 MB` (cost = width × height × 4).
  - Bubble views load asynchronously with `.task(id:)` and show a placeholder sized from the stored pixel dimensions.
  - Model outputs have thumbnails generated immediately following response parsing while payload bytes reside in memory buffers.
  - On the Mac and iPad a reply image drawn large asks for more pixels (`ThumbnailService.displayPixels`, on every platform). The current image stays on screen until they arrive, with no change of frame. The size has to hold for 250 ms before anything is decoded, a size that's no longer wanted is cancelled by its `.task(id:)`, and a request that has been waiting behind other decodes checks for cancellation before it starts. Only rows on screen or near it hold a larger image, because the cache's budget can't limit images that views keep alive; scrolling back gets it from the cache without decoding when it's still there. A row drawn smaller keeps what it holds or takes a larger size from memory, so going smaller decodes nothing that way, and only the first request for a size that's missing reads the original. Decoding runs off the actor, one at a time among sizes up to 1200 px and one at a time among larger ones, so a large decode holds up neither a list thumbnail nor anything already in memory, and a memory hit doesn't wait for the actor at all. A transcript of thirty 4K images scrolled end to end at full display peaked at 666 MB of footprint and settled at 308 MB. These thumbnails fall under the same 300 MB disk trim as the others. Deleting a chat or a message removes its images' thumbnails from disk and memory, and the Janitor removes any left over once the image has no record and the file is past the 10-minute freshness window.
- **Large responses.**
  - A 4K response with interim thought images can reach about 30 MB of JSON. The body is streamed to disk by the delegate, memory-mapped for decoding, and each image is decoded from base64 and written straight away.
  - Peak memory is about 3× the largest image's base64 size plus the mapped file. Parses run one at a time inside `GenerationService`.
- **Large request bodies** are streamed to the file in 48 KiB chunks and never held in memory.
- **The transcript.** Stable IDs (`Message.id`), and each row computes nothing heavy in `body`. The parts JSON is decoded once per message into a cached value on the row's model.
  - The iPhone uses a `LazyVStack`. Desktop macOS and regular-width iPadOS split views lay out every row eagerly (Section 3.11) to guarantee stable scroll offsets during live window resizing. Benchmarks measured on Apple Silicon hardware under release optimization illustrate the performance characteristics across conversation sizes:
    - *Small Conversations (60 messages)*: Eager layout registers 340 ms initial opening latency, 23 ms per resize increment, and 3.5 ms per scroll tick (compared to 150 ms open and 12 ms resize under lazy stacks).
    - *Large Conversations (500 messages)*: Eager layout registers 1.8 s initial open latency, 153 ms per resize step, and 19 ms per scroll tick, maintaining 670 MB to 780 MB memory footprint and 0% idle CPU utilization (compared to 220 ms open and 12 ms resize under lazy stacks).
    - *View Graph Optimizations*: Decoupling scroll offset mutation from reactive SwiftUI view state (`TranscriptUserScrolling`, unobserved reflow coordinate updates) eliminates redundant attribute graph invalidations, reducing wheel event latency by 37% (from 52–64 ms down to 19–29 ms). Restricting pointer hit-testing exclusively to rows within 800 pt of the visible viewport (`FarRowHitTesting`) avoids exhaustive per-frame view hierarchy traversals, yielding an additional 24% reduction in scroll processing overhead.
- **The pending card** costs about 0.5% CPU in the app, down from 35% with a 30 fps `TimelineView`, because its gradient animates in the render server. WindowServer's load doesn't measurably change with it on screen.
- **The viewer** keeps one full-resolution decode at a time. Pages next to the visible one show the 1200 px thumbnail until they're settled.
- **Launch.** The background session is recreated synchronously in `didFinishLaunching`; it's cheap. The Reconciler starts right after it, at utility priority, on every launch, including background relaunches that never draw a frame (section 4.7). The Janitor runs after the first frame, once the Reconciler has finished (section 4.4); on a background relaunch with no UI it simply waits for the next foreground launch.
- **Activity log.**
  - A log call costs the sanitizer pass on the caller's thread, outside the lock (linear in the message length; a long prompt is the worst case), then a short critical section: the ID, the timestamp and a stream yield. Callers on different threads contend only for that critical section, so a long prompt being sanitized on one thread doesn't hold up the main actor. JSON encoding, the file write and the OSLog mirror happen on the `ActivityLogStore` actor, with no fsync per entry.
  - Rotation rewrites at most 2 MB (plus the begins of open actions), once per roughly 2 MB logged.
  - The store keeps an action index (about 100 bytes per action), not the entries, so a background relaunch doesn't hold the log in memory. Building the index reads the file once per launch, off the main actor.
  - The viewer decodes and formats a view once when it opens, off the main actor (at most the 4 MB file for Full Log), then refreshes at most four times a second with only the entries written since the last refresh. It renders the text in `LogTextView` (a read-only `UITextView` with TextKit 2, which lays out only what's visible), so a 4 MB log stays responsive and any range can be selected. Copy and Share take the whole view.
- **Main-thread decode check.** In DEBUG, `ThumbnailService` and `ImageThumbnailView` log, under the `imaging` category, any image decode that runs on the main thread and takes more than 16 ms. There should be none.

---

## 9. Testing strategy
- **Framework:** Swift Testing (`import Testing`, `@Test`, `#expect`, parameterized `arguments:`) in `ImageGenTests` (`bundle.unit-test`, hosted by the app).
- **Networking in tests.** Custom `URLProtocol` classes **can't** be registered on background session configurations. `URLSessionTransport` is therefore built from a `URLSessionConfiguration` passed in:
  - production passes `.background(withIdentifier:)`;
  - tests pass `.ephemeral` with `protocolClasses = [MockURLProtocol.self]`.
  
  The same delegate, accumulator and service code runs in both. `MockURLProtocol` serves canned status, headers and body (optionally in several chunks, or with a delay), and records the requests it receives. Because `earliestBeginDate` is ignored outside background sessions, the transport defers `resume()` itself on non-background configurations through an injected sleeper (section 4.6, Retries); tests assert the recorded `TransportJob.earliestBegin` and `nextAttemptAt` and advance the sleeper by hand.
- **Suites:**
  1. **`InputSelectorTests`:** a table-driven test of every rule in 2.2:
     - attachments vs pin vs latest vs none;
     - latest skipping failed and refused replies;
     - the last ordinal within a message;
     - user upload vs model output recency;
     - the pin cleared after send;
     - the pin ignored when attachments are present;
     - `.noImage` only when the history holds no image (there is no option to skip the latest image);
     - the pinned asset deleted;
     - a pinned or latest **user upload** (and, in `GenerationServiceTests`, that it's sent as its prepared bytes, including after the max long edge setting has changed);
     - `canSend` with ready, pending and failed tray counts.
  2. **`RequestBodyWriterTests`:**
     - the golden JSON for a text-only request and a three-image request, compared structurally with `JSONSerialization`;
     - images before text;
     - the text part omitted when empty;
     - `"512"`, `"2K"` and uppercase-K encoding;
     - `imageSize` omitted for a no-size capability;
     - the CIVIC fallback body;
     - `["IMAGE"]` when text is off;
     - exact predicted body size equals the written size;
     - escaping of quotes, newlines and emoji in prompts;
     - `emptyParts` thrown for no images and no text.
  3. **`EndpointTests`:** the URL contains no `key=`; the header is present; the method is POST; and a snapshot of every logged string contains no key (logger injected).
  4. **`SettingsResolverTests`:**
     - defaults (16:9 / 2K);
     - per-chat overrides;
     - coercion for 3 Pro (1:8 → 16:9, 512 → 1K) and for Flash Lite (2K → 1K, 1:8 → 16:9);
     - `imageSize` omitted for 2.5 Flash Image;
     - an override naming a disabled or removed model resolves to Flash, reported as a coercion;
     - a custom-model capability.
  5. **`ResponseParserTests`:** with fixtures for:
     - text + image, image + text, and two images;
     - adjacent text parts concatenated verbatim, including a sentence split across two parts that must come back unchanged;
     - `ESCALATION` and `PUP_LIMITED_DISABLED` with no parts, both `.refused`;
     - `thought:true` text and images filtered out;
     - `promptFeedback.blockReason` set → `.refused`;
     - `IMAGE_SAFETY` with no content, `IMAGE_OTHER` with no content, and `NO_IMAGE` with no parts, each `.refused` with the reason verbatim;
     - `IMAGE_SAFETY` with a text part → `.refused`, with the text only in `details`, never in the parts;
     - an unrecognized finish reason with no image → `.refused` with that string verbatim;
     - no parts with each of `STOP`, `MAX_TOKENS`, `FINISH_REASON_UNSPECIFIED` and a missing finish reason → `.empty`; a text-only reply with each of the same four → `.success` (the boundary of rule 6);
     - a decodable image with finish `IMAGE_SAFETY` → `.success` with the "Finished: IMAGE_SAFETY" footnote; an only-undecodable image with finish `IMAGE_SAFETY` → `.refused`, with the notice kept;
     - empty candidates;
     - no MIME type, defaulting to JPEG;
     - an undecodable image;
     - malformed JSON;
     - an HTML body;
     - a Google RPC error body;
     - a non-JSON error body.
     
     Also checks that the redacted details contain no base64 longer than 100 characters.
  6. **`RetryPolicyTests`:** the status/error matrix (with idle vs resource `timedOut` told apart by elapsed time), the shared budget, the delay schedule with seeded jitter, the `RetryInfo` and `Retry-After` parsing, and that a refusal (a 2xx with a refusal body) is never retried and never triggers the CIVIC fallback; `GenerationServiceTests` checks the same end to end (one request sent, state `refused`).
  7. **`TransportTests`** (`MockURLProtocol`):
     - chunked body accumulation in order, including a body split across a recreated accumulator (append, never truncate);
     - status capture;
     - cancellation, and the cancel reason carried through;
     - events buffered when nobody is consuming yet, and `.finishedEvents` handled only after a back-to-back `.completed`;
     - deferred resume and the `.began` event;
     - an empty 200 body producing a retry;
     - an end-to-end `GenerationService` run with an in-memory `ModelContainer` (`ModelConfiguration(isStoredInMemoryOnly: true)`) and a temporary `FileStore` root, asserting the reply message parts, the image files written byte-identical to the fixture, and the request state;
     - a reply whose only image part is undecodable: the notice is stored, no `ImageAsset` is created, and the next send with no attachments or pin uses the earlier real image as `.latest` (section 2.6, Q3).
  8. **`ReconcilerTests`:** a fake task list for:
     - a live task kept;
     - an orphan marked interrupted after grace;
     - a late completion overriding interrupted;
     - the `.complete` marker re-parsing;
     - `preparing` marked interrupted;
     - a force-quit cancel (cancel reason set, not app-issued) ending as interrupted, and an app-issued cancel staying cancelled.
  9. **`ImagePreprocessorTests`**, using fixtures made in the tests with ImageIO. The only binaries in the repo are four tiny ones (`sample.heic`, `rotated_exif6.jpg`, `tiny_16x9.png`, `tiny_square.jpg`), generated once by a script in M0:
     - HEIC becomes JPEG, including HEIC with alpha (flattened onto white);
     - the long edge is capped for each of 1536/2048/3072/4096;
     - no upscaling;
     - orientation is applied;
     - GPS is stripped;
     - PNG with alpha keeps PNG;
     - GIF becomes JPEG (WebP only where ImageIO can encode a WebP source, which iOS can't, so that case is gated with `.enabled(if:)`);
     - the budget loop shrinks the largest image first and fails below 1024.
  10. **`ExportTests`:** for each stored MIME type, `ImageFile` exports exactly one representation whose type matches, with byte-identical contents (via `FileRepresentation` export to a temporary location); pasteboard data equals the original bytes. Photos saving is checked manually on the simulator.
  11. **`DataStoreTests`:**
      - cascade deletes remove files;
      - regenerate creates a new reply and keeps the earlier ones;
      - Edit and Resend clones its assets, and a clone prepared at a different max long edge is re-prepared at the current one;
      - the Janitor removes orphans.
  12. **`KeychainStoreTests`:** save, read, update and delete round-trip in the simulator host.
  13. **`ReplyPresentationTests`:** one row per line of the section 3.4 card table, asserting the glyph, the exact title (for example "Request refused: IMAGE_OTHER"), the message line (none for a refusal) and the exact buttons (Retry, Edit, New Chat; Retry, New Chat when the originating user message was deleted; Edit, New Chat for `PUP_LIMITED_DISABLED`, and New Chat alone when its user message was deleted). `ChatScreenModelTests` check that Edit loads the composer and focuses it (for a regenerated reply, with the text of the user message of the source request), and that New Chat creates and opens an empty chat. `GenerationServiceTests` check that a user Retry of a refused request runs it in place and clears the stale refusal fields on success.
  14. **`ActivityLogTests`** (temporary file, injected clock, sanitizer and OSLog sink):
      - ordering under concurrency: many tasks logging at once give a file whose order is the lock order, with every task's own entries in sequence and timestamps that never go backwards; `entries()`, `flush()` and `clear()` called mid-stream see, and are ordered after, every entry logged before them;
      - begin/result pairing: a second result is dropped (and not mirrored); finishing a parent with an open sub-action closes it as interrupted (and that result is mirrored);
      - outcomes: an empty reply's Send ends `failed`; a partial Attach ends `failed` with its counts;
      - Last Action: the newest user-started top-level action with its sub-actions, marked in progress while open, skipping newer system actions, and showing its Late completion;
      - Last Error: the newest failed, refused or interrupted top-level action, refusals and empty replies included, with its sub-actions; cancelled doesn't count; an interrupted action whose Late completion succeeded drops out; none when there's no error;
      - rotation past 4 MB keeps the newest whole entries within 2 MB plus the begins of open actions, and every line still decodes; an open action whose begin is older than the window keeps its name and origin and is still reported open after a reload;
      - clear: with nothing open the file holds only a Log cleared action; with a Send open, the file holds its begin then Log cleared, and the Send's later result is named and paired;
      - persistence: a new instance on the same file reads every entry, and its next ID isn't one already in the file, even when the earlier instance's last begins were written but nothing else of its state survived;
      - open actions left by an earlier instance are reported by `openActionsAtLaunch()`, and closing them writes interrupted results (the Reconciler wiring is in `ReconcilerTests`); entries under an adopted ID get the name and origin from the index, in the file and in the mirror;
      - a truncated last line is cut off, and the entry appended after it survives a reload;
      - the file's protection class and backup exclusion, after the first create, after a rotation and after a clear;
      - the formatter's exact line format and indentation.
  15. **`ActivityLogRedactionTests`:** with a key-shaped sentinel API key in the `InMemoryKeyStore` (and a second run with a sentinel that isn't key-shaped, so the registry is tested on its own), run a send, a 429-then-success, an error response that echoes `key=<sentinel>` and has a 5 KB body, an error whose message holds the sentinel without `key=`, a `URLError` description holding it, a prompt holding it, a custom model ID field holding it, a response with a thought signature, and a key validation. Then assert that neither the log file nor any string passed to OSLog contains the sentinel, `x-goog-api-key`, a base64 run of 100 or more characters, or a thought signature, and that the error body is cut to 2 KB. `RedactorTests` cover `forLog` directly.
  16. **`LogViewerModelTests`** and **`DeveloperMenuModelTests`:** the three views and their selection rules, Last Error disabled when there's none (from `DeveloperMenuModel`, updated without opening a sheet), live updates while open that append only new entries and stay on the action the sheet opened with, Clear Log's confirmation and the new log with Log cleared, the shared file being plain text equal to the view, and opening, copying or sharing adding no entries.
  
  **Instrumentation checks.** Every suite whose component owns actions asserts its log lines through a real `ActivityLog` on a temporary file. It checks the Begin parameters, the result outcome with its key measurement, and the pairing. For example, `GenerationServiceTests` check the Send Begin (model, aspect, size, threshold, modalities, input selection, full prompt), each Attempt and the Result; `ReconcilerTests` check that orphaned actions are closed as interrupted and that the action of a still-live request stays open and is continued after a relaunch; `ExportTests` check the save lines (bytes, MIME type, authorization) and the Share result from the share sheet's completion; `BackgroundEventsRelayTests` check that the log is flushed before the system completion handler is called. The full list is in the plan.
- **Live smoke test** (opt-in): `@Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil))`. It runs one 512 text-to-image request with Flash and one edit of the result, checks the returned dimensions against the expected class, and logs whether TEXT+IMAGE honored 2K (R3). The default modality follows that measurement, per the user's R3 decision: if 2K comes back in the 1K class, the default switches to `["IMAGE"]` (section 2.4; the plan's M9 decision step), and this sentence is updated to record the result. Never run in CI by default. Results (2026-10-16, measured twice, the second in M9): 2K was honored with TEXT+IMAGE both times (2752×1536 for 16:9 / 2K; 512×512 for 1:1 / 512), so R3 is settled as not capped and the default stays `["TEXT","IMAGE"]`.
- **Checking each milestone in the simulator:**
  - `xcodegen generate`, then `xcodebuild … test` and `build`;
  - install and launch on an iOS 26+ simulator (iPhone 17 Pro class), and for anything that touches layout an iPad simulator too (`IMAGEGEN_SIM`);
  - screenshot flows driven by deterministic launch arguments: `-UITestMockGemini` swaps the transport for a `MockGeminiURLProtocol`-backed ephemeral session and an in-memory API key, and `-SeedDemoData` loads sample chats.
  - The mock lives in the app target under `DebugSupport/` (`#if DEBUG`), because a launched app can't load test-bundle code. It generates responses in code (a JPEG at the pixel size from the plan's `MockImageSizes` table for the requested aspect and size, inside a real `generateContent` JSON shape; the table follows the documented sizes but corrects one apparent doc error, 21:9 at 512), so no fixture files ship in the app. Scenarios (refused, 429-then-success, low resolution, and so on) are chosen with `-MockScenario`. The full option list is in IMPLEMENTATION_PLAN.md section 2.6.
  
  The plan specifies the screenshots expected at each milestone.
- **On the device** (final milestone): a real key; background completion (start a 4K generation, lock the phone, receive the notification; and a multi-photo send that needs budget shrinking, then lock or switch apps at once, which exercises the background-task assertion); force-quit gives Interrupted; Save to Photos and Files and then a byte comparison; HEIC upload; checking memory during a 48 MP upload in Instruments; and the Developer menu: after a background completion, Last Action shows the Send with its result; after a force-quit or a rejected key, Last Error shows it; a shared log doesn't contain the key.

---

## 10. Build and project conventions
- **`project.yml`:**
  - XcodeGen 2.46+.
  - Application targets `ImageGen` (iOS 26.0, `TARGETED_DEVICE_FAMILY = "1,2"`, iPhone and iPad) and `ImageGenMac` (macOS 26.0, `PRODUCT_NAME = ImageGen`, sandboxed), and `bundle.unit-test` targets `ImageGenTests` and `ImageGenMacTests`, both compiling `ImageGenTests/`. Schemes are `ImageGen` and `ImageGenMac`. `ImageGen/` is shared; `Platforms/iOS` and `Platforms/macOS` are per-target.
  - `SWIFT_VERSION: 6.0`.
  - `info.properties` holds `NSPhotoLibraryAddUsageDescription`, `UILaunchScreen` and `UISupportedInterfaceOrientations` (on iPhone, portrait and the two landscape orientations) and `UISupportedInterfaceOrientations~ipad` (all four).
  - No `UIBackgroundModes`: a background URLSession doesn't need one. No BGTask identifiers in v1.
- **Signing:** the checked-in `Config/Base.xcconfig` is referenced through `configFiles`. It sets `IMAGEGEN_BUNDLE_ID = com.andrewpurtell.imagegen` (used as `PRODUCT_BUNDLE_IDENTIFIER`), an empty `DEVELOPMENT_TEAM`, and ad-hoc simulator signing, then does `#include? "Local.xcconfig"`. The git-ignored `Config/Local.xcconfig` holds the user's `DEVELOPMENT_TEAM`, and `Config/Local.xcconfig.example` documents it. The optional include matters because XcodeGen refuses a `configFiles` path that doesn't exist, and simulator builds need no team.
- **Commands** (wrapped by `scripts/*.sh`, which also select `DEVELOPER_DIR`; see IMPLEMENTATION_PLAN.md section 1.4):
  - `xcodegen generate`
  - `xcodebuild -project ImageGen.xcodeproj -scheme ImageGen -destination 'platform=iOS Simulator,name=<available iPhone or iPad>' test` (`scripts/test.sh` runs on `IMAGEGEN_SIM`, a simulator name or UDID, or else on `ImageGen-Sim`)
  - for the device: `-destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates`, where `<UDID>` is the **hardware** UDID (`hardwareProperties.udid` from `xcrun devicectl list devices --json-output -`, or an `id=` from `xcodebuild -showdestinations`), not the CoreDevice identifier in the `Identifier` column of `devicectl list devices`
- The generated `ImageGen.xcodeproj` is git-ignored. `project.yml` is the source of truth.
