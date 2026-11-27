// SPDX-License-Identifier: AGPL-3.0-or-later
// PostShot 驿站截图 — 开源免费的 iOS 长截图拼接 App
// Copyright (C) 2026 PostShot contributors

import SwiftUI

@main
struct PostShotApp: App {
    @StateObject private var bridgeServer = FrameBridgeServer()
    @StateObject private var keepAlive    = AudioKeepAlive()
    @StateObject private var settings     = AppSettings()
    @State private var selectedTab = 0
    @State private var showOnboarding = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView(selectedTab: $selectedTab)
                    .tabItem { Label("拼图", systemImage: "photo.on.rectangle.angled") }
                    .tag(0)
                AutoStitchView(selectedTab: $selectedTab)
                    .tabItem { Label("自动", systemImage: "wand.and.stars") }
                    .tag(1)
                CaptureView(server: bridgeServer)
                    .tabItem { Label("录制", systemImage: "record.circle") }
                    .tag(2)
            }
            .tint(DesignTokens.accentBlue)
            .environmentObject(settings)
            .environmentObject(bridgeServer)
            .onAppear(perform: appDidAppear)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView { preferredTab in
                    if let preferredTab {
                        selectedTab = preferredTab
                    }
                }
                .environmentObject(settings)
            }
        }
    }

    private func appDidAppear() {
        keepAlive.start()
        bridgeServer.onBroadcastStarted = {
            if selectedTab != 2 { selectedTab = 2 }
        }
        bridgeServer.onBroadcastReady = { [weak keepAlive] in
            keepAlive?.playStartCue()
        }
        bridgeServer.onBroadcastFinished = {
            if selectedTab != 2 { selectedTab = 2 }
        }
        bridgeServer.start()

        if !settings.hasCompletedOnboarding {
            showOnboarding = true
        }
    }
}
