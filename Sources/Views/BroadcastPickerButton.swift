// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import SwiftUI
import UIKit

/// Wraps `RPSystemBroadcastPickerView` so the app can present the system broadcast
/// start/stop control inline with adaptive monochrome or active-recording tint.
struct BroadcastPickerButton: UIViewRepresentable {
    /// Bundle id of the broadcast upload extension — preselects our extension in the picker.
    let extensionBundleID: String
    var isCapturing: Bool = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        applyTint(to: picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = extensionBundleID
        applyTint(to: uiView)
    }

    private func applyTint(to picker: RPSystemBroadcastPickerView) {
        let color: UIColor = isCapturing ? .systemRed : .label
        picker.tintColor = color
        for subview in picker.subviews {
            subview.tintColor = color
            if let button = subview as? UIButton {
                button.tintColor = color
            }
        }
    }
}
