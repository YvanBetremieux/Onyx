import SwiftUI
import AppKit
import RecorderCore

public struct OnboardingWindow: View {
    enum Step {
        case welcome, mic, screen, models,
             calendarPermission, calendarPicker,
             done
    }
    @State private var step: Step = .welcome
    let onCompleted: () -> Void
    let settings: SettingsStore

    public init(onCompleted: @escaping () -> Void,
                settings: SettingsStore = SettingsStore()) {
        self.onCompleted = onCompleted
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .welcome:
                Text("Welcome to Onyx").font(.largeTitle)
                Text("Offline meeting recorder + transcript").foregroundColor(.secondary)
                Button("Continue") { step = .mic }
            case .mic:
                Text("Microphone access").font(.title)
                Button("Grant microphone") {
                    Task {
                        _ = await PermissionsChecker.micGranted()
                        step = .screen
                    }
                }
            case .screen:
                Text("Screen recording").font(.title)
                Text("Required to capture system audio (Zoom, Meet, Huddle…)")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Grant screen recording") {
                    PermissionsChecker.requestScreenRecording()
                    step = .models
                }
            case .models:
                ModelDownloadView { step = .calendarPermission }
            case .calendarPermission:
                CalendarPermissionView { granted in
                    step = granted ? .calendarPicker : .done
                }
            case .calendarPicker:
                CalendarPickerView(settings: settings) { step = .done }
            case .done:
                Text("You're ready").font(.title)
                Button("Start using Onyx") {
                    UserDefaults.standard.set(true, forKey: "onboardingDone")
                    UserDefaults.standard.set(true, forKey: "onboardingV2Done")
                    onCompleted()
                    NSApplication.shared.keyWindow?.close()
                }
            }
        }
        .padding(40).frame(width: 480, height: 380)
    }
}
