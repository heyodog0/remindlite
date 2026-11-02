// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

// Opens/closes the RemindLite panel without clicking the menu-bar item — for
// screenshots (launch with --demo for sample data).
// Usage: swift Scripts/toggle-panel.swift [reminders|calendar|event|new-event]
import Foundation

let screen = CommandLine.arguments.dropFirst().first
DistributedNotificationCenter.default().postNotificationName(
    .init("com.heyodog0.remindlite.togglePanel"), object: screen,
    userInfo: nil, deliverImmediately: true)
