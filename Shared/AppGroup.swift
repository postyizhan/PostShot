// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Identifiers and paths shared between the main app and the broadcast upload extension.
///
/// The App Group is what lets the sandboxed extension hand captured frames to the main app:
/// the extension writes PNG frames into the group container, the app reads them back after
/// recording stops. Both targets must carry the `com.apple.security.application-groups`
/// entitlement with this exact identifier.
enum AppGroup {
    /// Must match the entitlement in both PostShot.entitlements and the extension's entitlements,
    /// and the value declared in project.yml.
    static let identifier = "group.com.postshot.app"

    /// Shared container root for this app group, or nil if the entitlement is missing/misconfigured.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Directory where the broadcast extension drops captured frames for the app to pick up.
    static var framesDirectory: URL? {
        containerURL?.appendingPathComponent("frames", isDirectory: true)
    }
}
