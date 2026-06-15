// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Self-contained App Group health check the MAIN APP can run without the extension.
///
/// Under a free-signed sideload, the App Group entitlement may not be active, or 爱思/AltStore
/// may rewrite the group id inconsistently between the app and the extension. If the app can't
/// even get its own container URL, App-Group sharing is dead and the extension's frames can
/// never arrive. This isolates that question to a check the app runs on itself.
enum AppGroupDiagnostics {

    struct Report {
        let containerAvailable: Bool
        let containerPath: String
        let writeReadOK: Bool
        let detail: String
    }

    static func run() -> Report {
        guard let container = AppGroup.containerURL else {
            return Report(
                containerAvailable: false,
                containerPath: "(nil)",
                writeReadOK: false,
                detail: "App Group 容器为 nil —— 权限未生效或 group id 被改写"
            )
        }

        // Round-trip a probe file in the app's own view of the container.
        let probe = container.appendingPathComponent("appgroup_probe.txt")
        let token = "ok-\(Int(Date().timeIntervalSince1970))"
        do {
            try token.write(to: probe, atomically: true, encoding: .utf8)
            let readBack = try String(contentsOf: probe, encoding: .utf8)
            let ok = readBack == token
            return Report(
                containerAvailable: true,
                containerPath: container.path,
                writeReadOK: ok,
                detail: ok ? "容器可读写 ✅" : "写入与读回不一致"
            )
        } catch {
            return Report(
                containerAvailable: true,
                containerPath: container.path,
                writeReadOK: false,
                detail: "容器存在但读写失败:\(error.localizedDescription)"
            )
        }
    }
}
