//
//  InProgressSessionControls.swift
//  WorkoutSessionKit
//
//  The "In Progress" section every app's workout summary shows for a session
//  that hasn't ended: Resume / Complete / Discard, with the two confirmation
//  alerts. Extracted from progYog's WorkoutSummaryView (mirrored verbatim into
//  splits and clubs) so the flow lives in one place.
//
//  Model-agnostic on purpose: the host owns persistence (CoreData / SwiftData)
//  and navigation, so it passes the three actions in. Resume typically flips a
//  `@State` that presents the app's session view; Complete stamps `endedAt` and
//  saves; Discard deletes the session (the host dismisses first, since deleting
//  a model still on screen can trap). Drop this into the summary `List` when
//  `session.endedAt == nil` — it carries its own confirm alerts.
//

import SwiftUI

public struct InProgressSessionControls: View {
    let onResume: () -> Void
    let onComplete: () -> Void
    let onDiscard: () -> Void
    let completePrompt: String
    let completeMessage: String
    let discardPrompt: String
    let discardMessage: String

    @State private var completeAlert = false
    @State private var discardAlert = false

    public init(
        onResume: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        completePrompt: String = "Complete session?",
        completeMessage: String = "Marks this session finished with the rounds already logged.",
        discardPrompt: String = "Discard session?",
        discardMessage: String = "Permanently removes this in-progress session and its logged sets."
    ) {
        self.onResume = onResume
        self.onComplete = onComplete
        self.onDiscard = onDiscard
        self.completePrompt = completePrompt
        self.completeMessage = completeMessage
        self.discardPrompt = discardPrompt
        self.discardMessage = discardMessage
    }

    public var body: some View {
        Section("In Progress") {
            Button { onResume() } label: {
                Label("Resume", systemImage: "play.circle.fill")
            }
            Button { completeAlert = true } label: {
                Label("Complete", systemImage: "checkmark.circle.fill")
            }
            Button(role: .destructive) { discardAlert = true } label: {
                Label("Discard", systemImage: "trash")
            }
        }
        .alert(completePrompt, isPresented: $completeAlert) {
            Button("Complete") { onComplete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(completeMessage)
        }
        .alert(discardPrompt, isPresented: $discardAlert) {
            Button("Discard", role: .destructive) { onDiscard() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(discardMessage)
        }
    }
}
