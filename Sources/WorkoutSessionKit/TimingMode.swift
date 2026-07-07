//
//  TimingMode.swift
//  WorkoutSessionKit
//
//  How a single slot is timed. Covers the shapes seen across the workout apps:
//  a straight timed hold, a per-side hold (left then right), and sliced holds
//  (N equal segments — e.g. progYog's isometric slices).
//

import Foundation

public enum TimingMode: Sendable, Equatable {
    /// One timed hold of `seconds`.
    case hold(seconds: Int)
    /// `secondsEach` on the left, then the same on the right.
    case perSide(secondsEach: Int)
    /// `count` back-to-back segments of `seconds` each.
    case slices(count: Int, seconds: Int)

    /// Number of timed segments the slot runs through.
    public var segmentCount: Int {
        switch self {
        case .hold:                     return 1
        case .perSide:                  return 2
        case let .slices(count, _):     return max(count, 1)
        }
    }

    /// Seconds for a given 0-based segment.
    public func seconds(forSegment index: Int) -> Int {
        switch self {
        case let .hold(seconds):        return seconds
        case let .perSide(secondsEach): return secondsEach
        case let .slices(_, seconds):   return seconds
        }
    }

    /// Total on-clock seconds for the whole slot.
    public var totalSeconds: Int {
        (0..<segmentCount).reduce(0) { $0 + seconds(forSegment: $1) }
    }

    public var isPerSide: Bool {
        if case .perSide = self { return true }
        return false
    }
}
