import SwiftUI
import AppKit
import RecorderCore

public struct OnboardingWindow: View {
    enum Step {
        case welcome, mic, screen, models,
             calendarPermission, calendarPicker,
             browserAutomation, claudeBinary,
             done
    }
    @State private var step: Step
    @State private var micDenied: Bool = false
    @State private var screenGranted: Bool = false
    let onCompleted: () -> Void
    let settings: SettingsStore

    public init(onCompleted: @escaping () -> Void,
                settings: SettingsStore = SettingsStore()) {
        self.onCompleted = onCompleted
        self.settings = settings
        // Fast-forward past Chantier 1 steps if V1 is already done.
        let v1Done = UserDefaults.standard.bool(forKey: "onboardingDone")
        _step = State(initialValue: v1Done ? .calendarPermission : .welcome)
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
                if micDenied {
                    Text("Microphone access was denied. Please allow it in System Settings.")
                        .foregroundColor(.red).multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                    Button("Re-check") {
                        Task {
                            let granted = await PermissionsChecker.micGranted()
                            if granted {
                                micDenied = false
                                step = .screen
                            }
                        }
                    }
                } else {
                    Button("Grant microphone") {
                        Task {
                            let granted = await PermissionsChecker.micGranted()
                            if granted {
                                step = .screen
                            } else {
                                micDenied = true
                            }
                        }
                    }
                }
            case .screen:
                Text("Screen recording").font(.title)
                Text("Required to capture system audio (Zoom, Meet, Huddle…)")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                if screenGranted {
                    Text("Screen recording is enabled.").foregroundColor(.green)
                    Button("Continue") { step = .models }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Grant screen recording") {
                        PermissionsChecker.requestScreenRecording()
                        // Re-check immediately; user may have already granted before
                        screenGranted = PermissionsChecker.screenRecordingGranted()
                        if screenGranted { step = .models }
                    }
                    Button("Re-check after granting in Settings") {
                        screenGranted = PermissionsChecker.screenRecordingGranted()
                        if screenGranted { step = .models }
                    }
                    Button("Skip") { step = .models }
                        .foregroundColor(.secondary)
                }
            case .models:
                ModelDownloadView { step = .calendarPermission }
            case .calendarPermission:
                CalendarPermissionView { granted in
                    step = granted ? .calendarPicker : .browserAutomation
                }
            case .calendarPicker:
                CalendarPickerView(settings: settings) { step = .browserAutomation }
            case .browserAutomation:
                BrowserAutomationView { step = .claudeBinary }
            case .claudeBinary:
                ClaudeBinaryView(settings: settings) { step = .done }
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
        .padding(40).frame(width: 500, height: 400)
    }
}
