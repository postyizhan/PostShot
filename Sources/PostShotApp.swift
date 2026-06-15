// PostShot 驿站截图 — 开源免费的 iOS 长截图拼接 App
// Copyright (C) 2026 PostShot contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

@main
struct PostShotApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("拼图", systemImage: "photo.on.rectangle.angled") }
                CaptureView()
                    .tabItem { Label("录制", systemImage: "record.circle") }
            }
        }
    }
}
