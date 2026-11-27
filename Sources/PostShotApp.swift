// SPDX-License-Identifier: AGPL-3.0-or-later
// PostShot 驿站截图 — 开源免费的 iOS 长截图拼接 App
// Copyright (C) 2026 PostShot contributors

import SwiftUI

@main
struct PostShotApp: App {
    @StateObject private var bridgeServer = FrameBridgeServer()
    @StateObject private var keepAlive = AudioKeepAlive()
    @State private var selectedTab = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView()
                    .tabItem { Label("拼图", systemImage: "photo.on.rectangle.angled") }
                    .tag(0)
                AutoStitchView()
                    .tabItem { Label("自动", systemImage: "wand.and.stars") }
                    .tag(1)
                CaptureView(server: bridgeServer)
                    .tabItem { Label("录制", systemImage: "record.circle") }
                    .tag(2)
            }
            .onAppear {
                let ka = keepAlive
                ka.start()
                bridgeServer.onBroadcastStarted = {
                    if selectedTab != 2 {
                        selectedTab = 2
                    }
                }
                bridgeServer.onBroadcastReady = { [weak ka] in
                    ka?.playStartCue()
                }
                bridgeServer.onBroadcastFinished = {
                    if selectedTab != 2 {
                        selectedTab = 2
                    }
                }
                bridgeServer.start()
            }
        }
    }
}
