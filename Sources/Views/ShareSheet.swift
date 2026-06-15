// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Thin UIKit bridge for the system share sheet (`UIActivityViewController`).
/// Presented from the UI layer with the temporary file URL produced by `ImageExporter`.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
