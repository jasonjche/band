# AGENTS.md — working on Band

Band is a personal, **iOS-only**, offline companion for the **WHOOP 5.0** strap. It is a fork of
[NOOP](https://github.com/ryanbr/noop). It pairs over Bluetooth, stores everything in on-device
SQLite, and computes sleep / recovery / strain / HRV locally. There is **no server, no account, no
cloud, no telemetry**.

Hard limits: no hosted service, no phone-home analytics, no WHOOP firmware / decompiled app code /
logos, no DRM circumvention. Clean-room interoperability with hardware the user owns. Licensing is
[PolyForm Noncommercial 1.0.0](LICENSE).

[`docs/BUILD.md`](docs/BUILD.md) covers signing. [`docs/IOS.md`](docs/IOS.md) covers the iOS target.
[`docs/SCOPE.md`](docs/SCOPE.md) names WHOOP-app features that stay out of scope.

## Architecture

Core logic lives in **Swift packages**. The iOS app is a thin layer over them.

| Layer | Path | What lives here |
|---|---|---|
| Protocol (pure) | `Packages/WhoopProtocol` | BLE frame parse, CRC, command/event/packet decode. **No CoreBluetooth.** Also builds the `whoop-decode` CLI. |
| Storage | `Packages/WhoopStore` | GRDB/SQLite persistence: migrations, streams, caches. |
| Analytics (pure) | `Packages/StrandAnalytics` | HRV / recovery / strain / sleep / correlation math. Database-free. |
| Import | `Packages/StrandImport` | WHOOP CSV + Apple Health importers. |
| Design system | `Packages/StrandDesign` | SwiftUI palette / components / charts. |
| Shared app | `Strand/` | `BLE/` (CoreBluetooth), `Collect/`, `Data/` (Repository), screens, native UI. |
| iOS app | `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*` | `StrandiOSApp` (@main), tab shell, widgets, watch app. |

`project.yml` is the **XcodeGen source of truth**; `Strand.xcodeproj/` is generated — never hand-edit
or commit it. Re-run `xcodegen generate` after adding/removing files or editing `project.yml`.

Wire-level and math-level code belongs in `Packages/`, covered by `swift test` with no app, no strap,
no CoreBluetooth. Never add `import AppKit` / `import UIKit` / `import CoreBluetooth` under
`Packages/`.

## Build and test

```bash
# Swift packages (fastest; no Xcode, no strap):
cd Packages/WhoopProtocol && swift build && swift test
# also WhoopStore, StrandAnalytics, StrandImport, StrandDesign

# BandCheck unit suite (no health data):
swift test --package-path Tools/BandCheck

# App (needs Xcode). project.yml is the source of truth:
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
```

Toolchain: Swift ≥ 5.9 (ships with Xcode on macOS). iOS 17+ / iOS 26 SDK for Liquid Glass.

`swift-packages.yml` does **not** compile the app targets. App Swift under `Strand/`, `StrandiOS/`,
widgets and watch is validated by `app-build.yml`. BLE behaviour cannot be CI-tested — validate on a
real strap.

## BLE safety contract

The strap is real hardware. The outbound set in `Strand/BLE/Commands.swift` (`WhoopCommand`) is a
**curated, reversible subset**. Do not add firmware/DFU, ship-mode, power-cycle, force-trim,
fuel-gauge reset, or anything that can brick, wipe, or permanently alter the device. `rebootStrap` is
the narrow exception: a restart that keeps stored data, confirmation-gated, never sent automatically.
A write whose effect cannot be shown to reverse is treated as destructive until proven otherwise.

A new non-trivial command is issue-first: justify reversibility, confirmation-gate it, never send it
automatically, and document payload plus on-device verification before any code.

**Gate on the full integrity verdict.** Inbound frames are rejected unless `parsed.ok` is true
(header checksum, payload CRC32, structural size). Do not add a weaker CRC-only side check. Evidence-
preserving archive readers are the documented exception — a failed verdict there is a reason to keep
the frame, not drop it. Never skip a CRC check to make a capture work.

**Keep the BLE path stable.** Do not reorder the connect handshake. Offload is gated on
`connectHandshakeDone`; `SET_CLOCK` must precede arming the firmware alarm. Do not `ENTER`
high-frequency sync; send `exitHighFreqSync` defensively on connect. Prefer `.withoutResponse`
writes; use `.withResponse` only where an ack is required.

CRC-gate every inbound frame. No hardcoded hex frame bytes in app code — protocol facts live in the
decoders/schema.

## `didBond`

`didBond` is load-bearing well beyond the handshake. Check every reader before you make a strap
deliberately not bond. At least three independent mechanisms treat "connected but never bonded" as a
fault: the bond watchdog, the never-bonded detector that counts self-drops toward pausing
auto-reconnect, and the bond-refusal give-up latch. A change that legitimately leaves a strap
unbonded silently re-arms all of them. Not-bonding is only evidence of a fault when we were actually
*trying* to bond.

## A diagnostic may only assert what it can attribute

Prefer silence, or name the gap, over a line that claims more than it observed. Do not let a path go
quiet: replacing a wrong line with no line removes the evidence. Gate per-connect readouts behind the
Test Centre domain; leave rare-event evidence (a state transition, a mismatch) always-on.

## Two readouts of one fact must not disagree

The same rule, one layer up: it applies to what a screen states, not only to what a log line claims.
Three defences, in order: do not show the fact twice; when it must appear twice, resolve both from
ONE gated funnel and ONE clock, passed in rather than read separately; gate that funnel on whether
the thing will actually happen.

## Other hard rules

- **Design system is law.** UI uses only design tokens — `StrandPalette` / `StrandFont` / shared
  components. No hardcoded colors, fonts, or spacing.
- **Migrations.** Add a versioned migration + a test; never mutate an existing migration. Prefer
  additive/transactional changes over window-wide deletes or backfill rewrites.
- **Deriving a physiological signal from raw sensor data — validate against the artifact, not one
  match.** WHOOP optical/motion buffers are fixed-N-samples-per-record, so autocorrelation/spectral
  methods can manufacture a peak at the record period that *looks* physiological. A single "matched
  WHOOP" night is not validation. Prove the method tracks a varying input. Until it does, land it as
  instrumentation or behind a default-off Experimental toggle — never as the default, never feeding a
  downstream gate on thin evidence.
- **Device / strap model resolution.** Map a registry `model` label to a family through the one
  canonical resolver (`DeviceFamily.forRegistryModel`). Reads must thread the registry's **active**
  strap id, not a raw BLE address.
- **`doc_comment_lint` reports at the wrong line on purpose.** The baseline is a per-file count of
  grandfathered sites. Adding one new detached doc comment makes the file overflow, and failures
  print against other, pre-existing sites. Look at what you just inserted.

## BandCheck gate

`Tools/BandCheck` replays Band's scorers over a WHOOP CSV export and a read-only copy of the phone
database. It fails if a change makes any gated score worse. Thresholds live in
`Tools/BandCheck/thresholds.json`. An algorithm change ships only when it improves agreement on
held-out days.

```bash
swift run --package-path Tools/BandCheck bandcheck \
  --db <copy of whoop.sqlite> --export <WHOOP export dir>
```
