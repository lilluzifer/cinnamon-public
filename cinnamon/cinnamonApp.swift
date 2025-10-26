//
//  cinnamonApp.swift
//  cinnamon
//
//  Created by Alexandru on 27.09.25.
//

import SwiftUI

@main
struct cinnamonApp: App {
    init() {
        TimelineSelfTests.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandMenu("Debug") {
                Button("Toggle A/V Sync Diagnostics") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleDiagnostics"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Divider()
                
                Text("Cmd+Shift+D: Start/Stop diagnostics")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
