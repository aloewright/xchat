// macOSApp.swift
// xchat – macOS app entry point

import SwiftUI

@main
struct xchatApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
                .frame(minWidth: 600, minHeight: 500)
                .tint(.blue)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                // Future: file-based conversation export
            }
        }

        Settings {
            SettingsView(viewModel: ChatViewModel())
                .frame(width: 440)
        }
    }
}
