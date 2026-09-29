import SwiftUI

struct MenuBarIcon: View {
    let state: AppState.UIState
    var body: some View {
        switch state {
        case .idle:         Image(systemName: "mic")
        case .recording:    Image(systemName: "record.circle").foregroundColor(.red)
        case .transcribing: Image(systemName: "hourglass").foregroundColor(.yellow)
        }
    }
}
