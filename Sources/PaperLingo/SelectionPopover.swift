import AppKit
import Combine
import PaperCore
import SwiftUI

@MainActor private final class SelectionPopoverLayout: ObservableObject {
    @Published var width: CGFloat = 390
    @Published var textHeight: CGFloat = 170
}

/// Lives with the native reader. The popover overlays the document and never
/// participates in its layout, so a translation cannot move the paper.
@MainActor final class SelectionPopoverController {
    private let store: AppStore
    private let popover = NSPopover()
    private weak var sourceView: NSView?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private let layout = SelectionPopoverLayout()
    private var anchorRect: NSRect?
    var selectionSettled: (() -> Void)?
    var isShown: Bool { popover.isShown }

    init(store: AppStore) {
        self.store = store
        // AppKit's transient behavior can dismiss a result on background scroll.
        // Keep ownership of dismissal so wheel/trackpad scrolling is harmless.
        popover.behavior = .applicationDefined
        popover.appearance = NSAppearance(named: .aqua)
        popover.animates = false
        let content = NSHostingController(rootView: SelectionActionPopover(store: store, layout: layout) { [weak self] in self?.dismiss() })
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        store.$selection.dropFirst().sink { [weak self] text in if text.isEmpty { self?.dismiss() } }.store(in: &subscriptions)
        store.$route.dropFirst().sink { [weak self] route in if route != .reading { self?.dismiss() } }.store(in: &subscriptions)
        store.$selectedPaperID.dropFirst().sink { [weak self] _ in self?.dismiss() }.store(in: &subscriptions)
    }
    func attach(to view: NSView) {
        sourceView = view
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) == nil }
            return consumed ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                if let window = event.object as? NSWindow, window === self?.sourceView?.window { self?.updateLayout() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let view = sourceView else { return event }
        let inReader = event.window === view.window
        let inPopover = event.window === popover.contentViewController?.view.window
        guard inReader || inPopover else { return event }
        if event.type == .keyDown, event.keyCode == 53, popover.isShown {
            dismiss()
            return nil
        }
        guard inReader else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            var hit = view.window?.contentView.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
            while let candidate = hit {
                if candidate is NSScroller { return event }
                hit = candidate.superview
            }
            dismiss()
        case .leftMouseUp:
            if view.visibleRect.contains(point) {
                DispatchQueue.main.async { [weak self] in self?.selectionSettled?() }
            }
        default: break
        }
        return event
    }
    private func updateLayout() {
        guard let view = sourceView else { return }
        layout.width = max(270, min(390, (view.window?.contentLayoutRect.width ?? 440) - 48))
        layout.textHeight = max(68, min(170, ((view.window?.contentLayoutRect.height ?? 650) - 260) / 2))
        if popover.isShown, let anchorRect {
            let visible = view.visibleRect
            let point = NSPoint(x: min(max(anchorRect.midX, visible.minX + 1), visible.maxX - 1),
                                y: min(max(anchorRect.midY, visible.minY + 1), visible.maxY - 1))
            popover.positioningRect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        }
    }
    func show(anchoredTo rect: NSRect) {
        guard let view = sourceView, view.window != nil, store.route == .reading, !store.selection.isEmpty,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let anchor = rect.insetBy(dx: -3, dy: -3).intersection(view.visibleRect)
        guard !anchor.isNull, anchor.width > 0, anchor.height > 0 else { dismiss(); return }
        updateLayout()
        anchorRect = anchor
        if popover.isShown { popover.positioningRect = anchor }
        else { popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY) }
    }
    func dismiss() { popover.close(); anchorRect = nil }
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
    @ObservedObject var layout: SelectionPopoverLayout
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("英文原文").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起选区操作 · Esc")
            }
            completeText(store.selection, serif: true, identifier: "selection.original")
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
                    }.disabled(store.context.isEmpty || store.context == store.selection || store.context.count > 4000 || store.translating || store.researchBusy)
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
                Text("中文译文").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                completeText(store.translation, serif: false, identifier: "selection.translation")
                if store.lookupSaved {
                    Label("已加入词库", systemImage: "checkmark.circle").foregroundStyle(Palette.green).font(.system(size: 10))
                } else {
                    Button("加入复习") { store.saveSentence() }.buttonStyle(.bordered).font(.system(size: 11))
                }
            } else if store.researchBusy || store.selection.count > 4000 {
                Text(store.researchBusy ? "论文摘要完成后可翻译；系统语音仍可使用。" : "一次最多翻译 4,000 字符，请缩小选区。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Text("原文与译文可滚动查看 · 滚动正文时保留 · Esc 收起")
                .font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(12).frame(width: layout.width).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Palette.ink).tint(Palette.green)
            .accessibilityElement(children: .contain).accessibilityLabel("选区操作")
    }
    private func completeText(_ text: String, serif: Bool, identifier: String) -> some View {
        let font = NSFont.systemFont(ofSize: 13)
        let descriptor = serif ? font.fontDescriptor.withDesign(.serif) ?? font.fontDescriptor : font.fontDescriptor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let bounds = NSAttributedString(string: text, attributes: [
            .font: NSFont(descriptor: descriptor, size: 13) ?? font, .paragraphStyle: paragraph
        ]).boundingRect(with: NSSize(width: layout.width - 48, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ScrollView {
            Text(text).font(.system(size: 13, design: serif ? .serif : .default)).lineSpacing(5)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
                .accessibilityIdentifier(identifier)
        }.scrollIndicators(.visible).frame(height: min(layout.textHeight, max(24, ceil(bounds.height) + 12)))
    }
}
