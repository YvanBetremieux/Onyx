import AVFoundation
import ScreenCaptureKit
import CoreGraphics

public enum PermissionsChecker {
    public static func micGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { ok in c.resume(returning: ok) }
            }
        default: return false
        }
    }

    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
