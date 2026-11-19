import AppKit
import PaperCore
import SwiftUI

struct SpeakingConversationView: View {
    @ObservedObject var session: SpeakingSession
    let mode: SpeakingPracticeMode
    let canUseStarter: Bool
    let useStarter: (String) -> Void
    @State private var jumpRequest = 0
    @State private var followsLatest = true

    var body: some View {
        Group {
            if session.transcript.isEmpty {
                starter
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(session.transcript) { turn in SpeakingMessageRow(turn: turn) }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: 900).frame(maxWidth: .infinity)
                    .background {
                        ConversationScrollObserver(jumpRequest: jumpRequest) { followsLatest = $0 }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button { jumpRequest += 1 } label: { Label("回到最新", systemImage: "arrow.down") }
                            .buttonStyle(.bordered).accessibilityIdentifier("speaking.latest").padding(10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.43))
    }

    private var starterText: String {
        switch mode {
        case .paper: return "Can we talk through the main idea of this paper?"
        case .vocabulary: return "Can you help me use this word in a sentence?"
        case .free: return "Could you ask me a question about my day?"
        }
    }

    private var starter: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 23, weight: .regular)).foregroundStyle(Palette.green)
                .frame(width: 46, height: 46).background(Palette.pale, in: Circle()).accessibilityHidden(true)
            if session.inputMode == .keyboard {
                Text("想从这句开始吗？").font(.headline)
                Button { useStarter(starterText) } label: {
                    HStack(spacing: 8) {
                        Text(starterText).multilineTextAlignment(.leading)
                        Image(systemName: "arrow.down.left").font(.caption)
                    }.padding(.horizontal, 4).padding(.vertical, 2)
                }.disabled(!canUseStarter).buttonStyle(.bordered)
                    .help("将这句话填入输入框，编辑后发送。")
            } else {
                Text("你可以这样开口").font(.headline)
                Text(starterText).font(.system(size: 16, design: .serif))
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
        }.padding(.horizontal, 24)
    }
}

// AppKit owns the actual scroll offset on macOS. Follow document growth until the
// reader moves away from the end, including when the current caption wraps.
private struct ConversationScrollObserver: NSViewRepresentable {
    let jumpRequest: Int
    let onFollowChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onFollowChange = onFollowChange
        if view.lastJump != jumpRequest {
            view.lastJump = jumpRequest
            view.following = true
        }
        view.scheduleLayoutCheck()
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        var onFollowChange: ((Bool) -> Void)?
        var lastJump = 0
        var following = true
        private var reported = true
        private var scheduled = false
        private var lastOffset: CGFloat?
        private weak var observedDocument: NSView?
        private weak var scroller: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { scheduleLayoutCheck() }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scroller = nil
            observedDocument = nil
            lastOffset = nil
        }

        func scheduleLayoutCheck() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in self?.afterLayout() }
        }

        private func afterLayout() {
            scheduled = false
            guard window != nil, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            if scroller !== scroll || observedDocument !== document {
                detach()
                scroller = scroll
                observedDocument = document
                lastOffset = clip.bounds.minY
                clip.postsBoundsChangedNotifications = true
                document.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                center.addObserver(self, selector: #selector(viewportMoved), name: NSView.boundsDidChangeNotification, object: clip)
                center.addObserver(self, selector: #selector(documentResized), name: NSView.frameDidChangeNotification, object: document)
            }
            if following {
                let bottom = bottomOffset(clip)
                if abs(clip.bounds.minY - bottom) > 1 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
                    scroll.reflectScrolledClipView(clip)
                }
            }
            if reported != following {
                reported = following
                onFollowChange?(following)
            }
        }

        private func bottomOffset(_ clip: NSClipView) -> CGFloat {
            clip.isFlipped ? max(clip.documentRect.minY, clip.documentRect.maxY - clip.bounds.height) : clip.documentRect.minY
        }

        @objc private func documentResized() { scheduleLayoutCheck() }

        @objc private func viewportMoved() {
            guard let clip = scroller?.contentView else { return }
            let offset = clip.bounds.minY
            if abs(bottomOffset(clip) - offset) <= 2 {
                following = true
            } else if let lastOffset, clip.isFlipped ? offset < lastOffset - 0.5 : offset > lastOffset + 0.5 {
                following = false
            }
            lastOffset = offset
            scheduleLayoutCheck()
        }
    }
}

struct SpeakingMessageRow: View {
    let turn: SpeakingTurn
    var save: (() -> Void)?
    private var isCoach: Bool { turn.role == .assistant }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isCoach { Spacer(minLength: 42) }
            VStack(alignment: isCoach ? .leading : .trailing, spacing: 5) {
                Text(isCoach ? "教练" : "我").font(.caption.weight(.semibold)).foregroundStyle(Palette.green)
                if turn.text.isEmpty {
                    Text(isCoach ? "正在回答…" : "正在听…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(turn.text)
                        .font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                if let save {
                    Button(action: save) { Label("保存这句", systemImage: "bookmark") }
                        .controlSize(.small).buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isCoach ? Color.white : Palette.pale, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line).allowsHitTesting(false)
            }
            .frame(maxWidth: 605, alignment: isCoach ? .leading : .trailing)
            if isCoach { Spacer(minLength: 42) }
        }.frame(maxWidth: .infinity, alignment: isCoach ? .leading : .trailing)
    }
}
