// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import ReplayKit

/// Wraps `RPSystemBroadcastPickerView` so the app can present the system broadcast
/// start/stop control inline. Tapping it lets the user start the screen broadcast that
/// drives our broadcast upload extension.
struct BroadcastPickerButton: UIViewRepresentable {
    /// Bundle id of the broadcast upload extension — preselects our extension in the picker.
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
