import AppKit
import Combine
import PaperCore
import SwiftUI

/// Lives with the native reader. The popover overlays the document and never
/// participates in its layout, so a translation cannot move the paper.
@MainActor final class SelectionPopoverController {
    private let store: AppStore
    private let popover = NSPopover()
    private weak var sourceView: NSView?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    var selectionSettled: (() -> Void)?

    init(store: AppStore) {
        self.store = store
        popover.behavior = .transient
        popover.animates = false
        let content = NSHostingController(rootView: SelectionActionPopover(store: store) { [weak self] in self?.dismiss() })
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        store.$selection.dropFirst().sink { [weak self] text in if text.isEmpty { self?.dismiss() } }.store(in: &subscriptions)
        store.$route.dropFirst().sink { [weak self] route in if route != .reading { self?.dismiss() } }.store(in: &subscriptions)
    }
    func attach(to view: NSView) {
        sourceView = view
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) == nil }
            return consumed ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                if let window = event.object as? NSWindow, window === self?.sourceView?.window { self?.dismiss() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            // A popover may briefly become key itself. Only dismiss when the app loses focus.
            DispatchQueue.main.async { if !NSApp.isActive { self?.dismiss() } }
        })
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let view = sourceView, event.window === view.window else { return event }
        if event.type == .keyDown, event.keyCode == 53, popover.isShown {
            dismiss()
            return nil
        }
        if event.type == .keyDown, [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) {
            dismiss() // Keyboard scrolling; selection delegates may show a newly changed selection afterwards.
        }
        let point = view.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown: dismiss()
        case .scrollWheel:
            if view.visibleRect.contains(point) { dismiss() }
        case .leftMouseUp:
            if view.visibleRect.contains(point) {
                DispatchQueue.main.async { [weak self] in self?.selectionSettled?() }
            }
        default: break
        }
        return event
    }
    func show(anchoredTo rect: NSRect) {
        guard let view = sourceView, view.window != nil, store.route == .reading, !store.selection.isEmpty,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let anchor = rect.insetBy(dx: -3, dy: -3).intersection(view.visibleRect)
        guard !anchor.isNull, anchor.width > 0, anchor.height > 0 else { dismiss(); return }
        if popover.isShown { popover.positioningRect = anchor }
        else { popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY) }
    }
    func dismiss() { popover.close() }
    func invalidate() {
        dismiss()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        subscriptions.removeAll(); selectionSettled = nil; sourceView = nil
    }
    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private struct SelectionActionPopover: View {
    @ObservedObject var store: AppStore
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(store.selection).font(.system(size: 12, weight: .medium, design: .serif)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起选区操作 · Esc")
            }
            HStack(spacing: 8) {
                Button { Task { await store.translate() } } label: {
                    Label(store.translating ? "翻译中…" : "翻译", systemImage: "character.bubble")
                }.disabled(store.translating || store.researchBusy || store.selection.count > 4000)
                Button { store.audio.speak(store.selection) } label: { Label("朗读", systemImage: "speaker.wave.2") }
                Menu {
                    Button("慢速朗读") { store.audio.speak(store.selection, slow: true) }
                    Button("翻译所在句") {
                        let sentence = store.context
                        store.updateSelection(sentence, context: sentence, page: store.selectedPage)
                        Task { await store.translate() }
                    }.disabled(store.context.isEmpty || store.context == store.selection || store.translating || store.researchBusy)
                    Divider()
                    Button("保存选区到笔记") {
                        dismiss()
                        if let paper = store.selectedPaper { store.newNote(paper, fromSelection: true) }
                    }
                    Button("复制原文") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.selection, forType: .string)
                        dismiss()
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25).help("慢速、原句与笔记")
                Spacer(minLength: 0)
            }.buttonStyle(.bordered).controlSize(.regular).font(.system(size: 12))
            if store.translating {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机翻译").font(.system(size: 11)) }
            } else if !store.translation.isEmpty {
                Divider()
                ScrollView {
                    Text(store.translation).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(160, max(42, CGFloat(store.translation.count / 24 + 1) * 23)))
                if store.lookupSaved {
                    Label("已加入词库", systemImage: "checkmark.circle").foregroundStyle(Palette.green).font(.system(size: 10))
                } else {
                    Button("加入复习") { store.saveSentence() }.buttonStyle(.bordered).font(.system(size: 11))
                }
            } else if store.researchBusy || store.selection.count > 4000 {
                Text(store.researchBusy ? "论文摘要完成后可翻译；系统语音仍可使用。" : "一次最多翻译 4,000 字符，请缩小选区。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(12).frame(width: 330).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Palette.ink).tint(Palette.green)
            .accessibilityElement(children: .contain).accessibilityLabel("选区操作")
    }
}
