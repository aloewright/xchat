// iOSApp.swift
// xchat – iOS app entry point

import SwiftUI

@main
struct xchatApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
                .tint(.blue)
        }
    }
}
