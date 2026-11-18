import SwiftUI

/// A button for work that takes a moment. Pressing it swaps the label for a
/// spinner at once and ignores further presses until the work returns, so a
/// slow job cannot be started twice. The iOS app has the same control.
struct BusyButton<Label: View>: View {
    var role: ButtonRole?
    /// Busy for a reason this button did not start, such as the same job
    /// begun from elsewhere.
    var isBusy: Bool
    let action: () async -> Void
    let label: () -> Label

    @State private var running = false

    init(role: ButtonRole? = nil, isBusy: Bool = false,
         action: @escaping () async -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.role = role
        self.isBusy = isBusy
        self.action = action
        self.label = label
    }

    var body: some View {
        let busy = running || isBusy
        Button(role: role) {
            guard !running, !isBusy else { return }
            running = true
            Task { @MainActor in
                await action()
                running = false
            }
        } label: {
            label()
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.mini) } }
        }
        .disabled(busy)
    }
}

extension BusyButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, isBusy: Bool = false,
         action: @escaping () async -> Void) {
        self.init(role: role, isBusy: isBusy, action: action) { Text(title) }
    }
}
