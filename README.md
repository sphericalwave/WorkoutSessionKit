# WorkoutSessionKit

App-agnostic driver for a rounds x slots workout with per-segment timing (hold /
per-side / slices). The engine owns the clock, phase, and cue emission; the host app
owns persistence and progression via the value snapshots it feeds in.

## Requirements

- iOS 17+ / macOS 14+
- Swift 5.9+

## Installation

```swift
.package(url: "https://github.com/sphericalwave/WorkoutSessionKit.git", branch: "main")
```

## Overview

- `WorkoutSessionEngine` — the driver. Typical loop:
  ```swift
  engine.start()                        // begins slot 0
  // ...runs left 30s -> cue(.segmentBoundary) -> right 30s -> cue(.slotEnd)...
  phase == .awaitingLog                 // app shows its log sheet
  // ...app persists the set + applies progression...
  engine.advance()                      // -> next slot / round / finished
  ```
- `WorkoutSlot` — a value snapshot of the exercise to perform in one slot of a round; apps build these from their own model types, the engine never sees SwiftData/CoreData
- `TimingMode` — hold / per-side / slices timing configuration for a slot
- `SessionCue` — cues emitted by the engine (segment boundary, slot end, etc.)
- `InProgressSessionControls` — SwiftUI controls for an in-progress session

## Dependencies

None.
