// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// App Group shared-container identity for the main app ↔ broadcast extension pair.
///
/// BACKGROUND: v2 originally planned to hand frames via an App Group shared container, but an early
/// diagnostic reported a nil container under free-signed sideloads, so the project switched to a
/// loopback socket (see `FrameBridge`). Deep research (2026-06-16) found that nil was likely caused
/// by the App Group entitlement never being *declared* — the repo had no .entitlements file at all —
/// rather than an absolute free-tier prohibition. This type re-introduces a PROPERLY declared group
/// so we can verify on-device whether the container actually resolves. The socket path is untouched;
/// this is a parallel diagnostic, not a switch-over.
///
/// If the container resolves (non-nil) under free signing, v2 can move to the App-Group architecture
/// where the extension writes frames to disk and the host reads them AFTER recording — eliminating
/// the "both processes alive simultaneously" constraint that kills the socket on host suspension.
enum AppGroup {

    /// The shared App Group identifier. Both targets declare this in their .entitlements; free Apple
    /// ID accounts are capped at 3 groups, and the group identity is bound to the signing team prefix.
    static let identifier = "group.com.postshot.app"

    /// The shared-container URL for the group, or `nil` if the system did not provision it (the
    /// failure mode this whole exercise is testing for).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// True when the shared container is usable — i.e. the entitlement was honored at install time.
    static var isAvailable: Bool {
        containerURL != nil
    }

    /// Human-readable container path for on-device diagnostics, or a clear nil marker.
    static var diagnosticPath: String {
        containerURL?.path ?? "(nil — 容器不可用)"
    }
}
