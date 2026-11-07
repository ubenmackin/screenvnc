# ScreenVNC — Architecture Blueprint

Pure SwiftUI VNC viewer for connecting to macOS Screen Sharing from iOS and iPadOS.

Repository: https://github.com/ubenmackin/screenvnc

Owner: This document owns the subsystem layout, the RFB engine, and the commenting guidelines.
The RFB section below covers the implemented custom engine plus roadmap extensions.
This slice ships app shell plus navigation plus the custom VNC engine.

---

## 1. Soul plus Design Theses

ScreenVNC is a pure SwiftUI VNC viewer targeting macOS Screen Sharing. It does one
job: let a user enter a connection profile, connect to a Mac, see the remote
framebuffer, and send keyboard plus pointer input back.

1. **Mac-first interop**: macOS Screen Sharing is the reference server. Protocol
   choices, auth choices, and encoding choices are justified by what macOS speaks.
2. **Native SwiftUI start to finish**: SwiftUI lifecycle with zero UIKit bridging.
   No UIViewController wrappers, no hosted views. Layout flows from traits and
   safe-area guides.
3. **Thin viewer, thick platform**: RFB stays behind a narrow VNC subsystem seam.
   Rendering, input, and settings never parse wire bytes directly.
4. **Profiles over prefs**: a connection profile (host, port, credentials,
   display options) is the unit of reuse. Validation lives in one place.
5. **Framebuffer purity**: the rendered desktop image is a function of
   framebuffer updates plus display traits. Views never mutate session state.
6. **Input as translation**: every local gesture or key event translates once
   into an RFB input event at the contract boundary, then crosses into VNC.

---

## 2. Tech Stack

- **Language**: Swift 6 language mode with strict concurrency.
- **Deployment**: iOS 27.1.
- **Project generation**: XcodeGen from a declarative `project.yml`. The generated
  `.xcodeproj` is never edited by hand or committed; regenerate on file changes.
- **UI lifecycle**: SwiftUI lifecycle (`App` plus `Scene` plus `View`) with zero
  UIKit bridging.
- **RFB implementation**: custom native Swift RFB engine — `VNCClient` actor over
  `Network.framework` `NWConnection` with handshake, security, and
  encoding handling inside `Sources/VNC`.
- **Persistence**: JSON file in Application Support mirrored to
  `NSUbiquitousKeyValueStore` for connection profiles plus Keychain for
  credentials plus lightweight `UserDefaults` keys for viewer preferences.
- **Async model**: Swift concurrency (`async`/`await`, `Actor`-isolated session
  objects, `@MainActor` view models).

Alternatives considered:

- RoyalVNC: rejected as archived. It is unmaintained and is not a dependency.
- TailVNC plus Pocket-Mac: reference-only. Consulted for UX plus interop notes,
  never vendored and never depended upon.
- rootshellVNC (https://github.com/kitknox/rootshell-vnc): evaluated and not
  vendored; custom `NWConnection` engine is the intentional implementation.

---

## 3. Display plus Input Model

The viewer adapts to portrait plus landscape through SwiftUI traits
(`horizontalSizeClass`, `verticalSizeClass`, `dynamicTypeSize`) and safe-area
insets. No hardcoded dimensions enter layout math.

- **Portrait**: compact-width phones show a single-column flow: connection list,
  connect action, then a fitted desktop view with an collapsible input bar.
  The desktop scales to fit width; pinch zooms into a scrollable detail region.
- **Landscape**: wider traits promote a two-region layout: desktop canvas plus a
  slim accessory strip (keyboard toggle, modifier keys, pointer mode). The canvas
  keeps aspect fill within safe-area bounds.
- **Trait handling**: size-class changes reflow the same view hierarchy. No state
  loss on rotation. Sticky chrome is avoided; controls overlay with materials and
  dismiss on interaction.
- **Pointer model**: direct touch drag maps to pointer move, tap maps to click,
  long-press maps to right-click, two-finger drag maps to scroll. An optional
  trackpad-relative mode maps drags to deltas.
- **Keyboard model**: system keyboard plus a modifier bar (Control, Option,
  Command) feeds key events through the input translation contract.

---

## 4. Subsystem map

Mirrors the TASK-001 directory layout. Each directory has a single owner and a
narrow public seam.

```
Sources/
├── App/                  # SwiftUI App plus Scene plus root navigation plus launch state
├── Connection/           # Connection profiles, validation, saved hosts, connect flow
├── VNC/                  # RFB session engine (custom NWConnection client)
├── Rendering/            # Framebuffer views, scaling, invalidation-driven redraw
└── Settings/             # Viewer preferences, display options, diagnostics
Tests/
└── VNC/                  # Unit plus view-model tests (ScreenVNC test bundle)
ScreenVNCUITests/         # Out-of-process UI tests (launch plus connect flows)
Support/
└── TestPlans/            # Test plans plus tooling configuration
Assets.xcassets/          # App icons, accent colors, image catalogs
```

- **App**: owns launch, navigation, and dependency wiring. No networking here.
- **Connection**: owns profile storage plus connection profile validation. Sole
  place that accepts or rejects a host/port/credential triple.
- **VNC**: owns session lifecycle plus wire protocol (handshake, security,
  encodings, pixel format) via the custom `NWConnection` engine.
- **Rendering**: owns framebuffer invalidation handling and scaling. Redraws only
  on invalidated rects.
- **Settings**: owns user preferences and display defaults. No session logic.
- **Tests/VNC/**: owns fast deterministic unit coverage for validation plus view models.
- **ScreenVNCUITests**: owns end-to-end launch plus mocked connect journeys.
- **Support/TestPlans**: owns test plans plus tooling configuration.
- **Assets.xcassets**: owns icons plus catalogs. No code.

---

## 5. Contracts

Three narrow contracts connect the subsystems. Callers delegate; they never
re-implement the owning subsystem.

### 5.1 Connection profile validation

- Owner: `Connection`.
- Input: host string, port (default 5900), credential presence, display options.
- Rules: host must be a non-empty DNS name or IP literal; port must be 1-65535;
  Apple auth variants require a username plus password; stored profiles revalidate
  on load and drop invalid entries to a quarantined default.
- Consumers: `App` (connect button enablement) and `VNC` (dial guard). Neither
  duplicates the rules.

### 5.2 Framebuffer invalidation

- Owner: `Rendering`.
- Input: framebuffer update rects plus new pixel buffers from `VNC`.
- Rules: updates apply in arrival order; overlapping rects coalesce; views redraw
  only the union of dirty rects; DesktopSize changes resize the canvas and clear
  dirty state before the next paint.
- Consumers: `VNC` posts updates; `Rendering` coalesces and paints. Views never
  fetch wire state directly.

### 5.3 Input event translation

- Owner: `VNC` (translation seam) with gestures owned by `Rendering`.
- Input: local tap, drag, scroll, and key events with view-space coordinates.
- Rules: coordinates normalize to remote framebuffer space at the boundary;
  pointer mode (direct vs relative) is applied once during translation; key events
  map modifiers plus keycodes in one function; translated events queue in order.
- Consumers: `Rendering` captures gestures; `Settings` supplies pointer mode;
  `VNC` queues translated events for the future session.

---

## 6. RFB Interop — Implemented Engine plus Roadmap (macOS Interop)

Custom `NWConnection` engine in `Sources/VNC` implements the core wire path.
Remaining items below extend that engine. All wire work lands inside `VNC`
behind the contracts above.

- **Protocol versions**: 3.3 plus 3.7 plus 3.8. Owner: `VNC`. Negotiate highest
  mutually supported version; 3.8 preferred against macOS Screen Sharing.
- **Security types**: None (1) plus VNC DES (2) plus Apple DH (30) plus
  Apple RSA AES (33). Owner: `VNC`. None is loopback-only; VNC DES covers legacy
  password auth; Apple DH plus Apple RSA AES cover macOS user plus credential
  flows.
- **Encodings**: Raw plus CopyRect plus Zlib plus Tight plus ZRLE plus Hextile.
  Owner: `VNC` (decode) plus `Rendering` (paint). Raw is the fallback; CopyRect
  accelerates moves; Zlib plus Tight plus ZRLE compress full-color desktop; Hextile
  covers legacy servers.
- **Pseudo-encodings**: Cursor plus DesktopSize plus ExtendedDesktopSize plus
  LastRect. Owner: `VNC` (negotiation) plus `Rendering` (cursor plus resize).
  Cursor enables remote cursor rendering; DesktopSize plus ExtendedDesktopSize
  drive canvas resize; LastRect terminates update batches.
- **Sequencing**: version handshake, then auth selection, then init exchange,
  then encoding negotiation, then steady-state update loop. Each step runs
  in the `VNC` engine behind the contract seams above.
- **Non-goals in this slice**: no UI-driven socket churn outside `VNC`, no
  vendored crypto or RFB packages; hardening of DH exchange and decoder
  edge cases remains roadmap. Engine speaks to servers via `VNC`.

---

## 7. Engineering Standards

### Test target matrix

- **Tests** (`bundle.unit-test`): profile validation, view-model state,
  invalidation coalescing, input translation math. Fast, deterministic, no network.
- **ScreenVNCUITests** (`bundle.ui-testing`): app launch, profile create plus
  connect against mocks, portrait plus landscape rotations. Out-of-process only.
- **Test plans**: `Support/TestPlans/ScreenVNC.xctestplan` runs all suites;
  `Support/TestPlans/ScreenVNCFast.xctestplan` runs unit suites only and excludes
  UI tests by design.
- **Commands**:
  ```bash
  xcodegen generate
  xcodebuild test -scheme ScreenVNC -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:ScreenVNCTests
  ```

### Architectural invariants

- **Sequential simulator execution**: parallel testing stays disabled
  (`parallelizable == false` on every test target). Simulators run sequentially
  with randomized ordering for determinism.
- **No hardcoded dimensions**: layouts use traits, safe areas, and geometry
  readers. Never branch on device models or fixed point sizes.
- **No private APIs**: RFB plus rendering plus input use public SDKs only —
  `Network`, `CryptoKit`/`CommonCrypto`, `Compression`, `LocalAuthentication`
  — plus system SwiftUI/Combine; no private APIs and no vendored RFB package.
- **Single-owner rules**: `Connection` alone validates profiles; `Rendering`
  alone coalesces framebuffer invalidation; `VNC` alone translates input events;
  `App` alone wires dependencies; `Settings` alone owns preferences. Call sites
  delegate and never re-implement.
- **Project hygiene**: adding, moving, or removing files requires regenerating
  via XcodeGen. Generated projects are never hand-edited.

---

## Code Commenting Guidelines

- File Headers: Every source plus test file starts with a 1-2 line header `// <Subsystem> — <Purpose plus role>.`
- Max 3 Lines: Every comment stays at most 3 lines.
- Intent Over Mechanics: Comments explain rationale plus edge cases, never restate mechanics.
- No Planning-Artifact References: Comments never mention task IDs, session IDs, PR numbers, plan identifiers, transient planning artifacts.
