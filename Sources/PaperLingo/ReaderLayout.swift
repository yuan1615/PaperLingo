import SwiftUI

@MainActor final class ReaderLayout: ObservableObject {
    @Published var sidebarVisible = UserDefaults.standard.object(forKey:"readerSidebarVisible") as? Bool ?? true {
        didSet {UserDefaults.standard.set(sidebarVisible,forKey:"readerSidebarVisible")}
    }
    @Published var assistantVisible = UserDefaults.standard.object(forKey:"readerAssistantVisible") as? Bool ?? true {
        didSet {UserDefaults.standard.set(assistantVisible,forKey:"readerAssistantVisible")}
    }
    @Published var focused = false
}

/// A full rectangular target, including the padding and space between icons.
struct ReadingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Palette.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
