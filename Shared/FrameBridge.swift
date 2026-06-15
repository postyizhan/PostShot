// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Loopback transport used to hand frames from the broadcast extension to the main app
/// WITHOUT an App Group (which is unavailable under free-signed sideloads — see CaptureView
/// diagnostics). Both processes live on the same device, so a TCP connection over 127.0.0.1
/// crosses the process boundary that the sandbox would otherwise block for shared files.
///
/// The main app runs the listener (server); the extension connects as a client and streams.
enum FrameBridge {
    static let host = "127.0.0.1"
    /// Fixed high port both sides agree on. (No discovery channel exists without App Group.)
    static let port: UInt16 = 52890
}
