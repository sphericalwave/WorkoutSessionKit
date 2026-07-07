//
//  WorkoutSlot.swift
//  WorkoutSessionKit
//
//  A value snapshot of the exercise to perform in one slot of a round. Apps
//  build these from their own @Model types (the engine never sees SwiftData /
//  CoreData), mirroring how SetLogKit takes a `RatedSkillInfo` snapshot.
//

import Foundation

public struct WorkoutSlot: Identifiable, Sendable, Equatable {
    /// Stable identifier from the app's model (e.g. skill UUID string).
    public let id: String
    public let name: String
    /// Progression level/depth, for display and progression rules.
    public let level: Int
    public let instructions: String
    public let imageName: String?
    public let timing: TimingMode

    public init(
        id: String,
        name: String,
        level: Int = 1,
        instructions: String = "",
        imageName: String? = nil,
        timing: TimingMode
    ) {
        self.id = id
        self.name = name
        self.level = level
        self.instructions = instructions
        self.imageName = imageName
        self.timing = timing
    }
}

/// Audio/haptic cues the engine emits at key moments. Apps map these to their
/// sound layer (e.g. WorkoutAudioKit's `AudioCue`) — the engine stays decoupled.
public enum SessionCue: Sendable, Equatable {
    case roundStart
    case countdownTick        // final 3-2-1 seconds of a segment
    case segmentBoundary      // e.g. side switch / slice change (mid-slot)
    case slotEnd              // slot fully done
    case roundEnd
}
