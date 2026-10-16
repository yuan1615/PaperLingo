import AppKit
import PDFKit
import SwiftUI
import PaperCore

struct PDFReader: NSViewRepresentable {
    let url: URL
    let paper: Paper
    @ObservedObject var store: AppStore
    let zoomCommand: Int
    let search: String
    func makeCoordinator() -> Coordinator { Coordinator(store:store,paper:paper) }
    func makeNSView(context: Context) -> PDFView {
        let view=PDFView(); view.autoScales=true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.displaysPageBreaks=true; view.pageBreakMargins=NSEdgeInsets(top:20,left:16,bottom:20,right:16)
        view.backgroundColor=NSColor(red:0.94,green:0.94,blue:0.92,alpha:1)
        view.document=PDFDocument(url:url)
        context.coordinator.view=view
        context.coordinator.selectionPopover.attach(to: view)
        context.coordinator.selectionPopover.selectionSettled = { [weak coordinator = context.coordinator] in coordinator?.selectionChanged() }
        context.coordinator.observe(view)
        if let page=view.document?.page(at:paper.page) { view.go(to:page) }
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.paper.id != paper.id {
            context.coordinator.paper=paper; view.document=PDFDocument(url:url); view.autoScales=true
            if let p=view.document?.page(at:paper.page) { view.go(to:p) }
        }
        if let jump=store.jumpPage, let p=view.document?.page(at:jump) {
            view.go(to:p); DispatchQueue.main.async { store.jumpPage=nil }
        }
        if context.coordinator.zoom != zoomCommand {
            if zoomCommand > context.coordinator.zoom { view.zoomIn(nil) } else { view.zoomOut(nil) }
            context.coordinator.zoom=zoomCommand
        }
        if context.coordinator.query != search {
            context.coordinator.query=search
            if search.isEmpty { view.highlightedSelections=[] }
            else {
                let results=view.document?.findString(search,withOptions:[.caseInsensitive]) ?? []
                results.forEach { $0.color=NSColor.systemYellow.withAlphaComponent(0.45) }
                view.highlightedSelections=results
                if let first=results.first { view.go(to:first) }
            }
        }
    }
    static func dismantleNSView(_ view:PDFView,coordinator:Coordinator) {
        coordinator.work?.cancel()
        coordinator.selectionPopover.invalidate()
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        coordinator.observers.removeAll()
        coordinator.view=nil
    }
    @MainActor final class Coordinator: NSObject {
        let store: AppStore
        var paper: Paper
        weak var view: PDFView?
        var zoom=0
        var query=""
        var observers:[NSObjectProtocol]=[]
        var work:DispatchWorkItem?
        let selectionPopover: SelectionPopoverController
        init(store:AppStore,paper:Paper) { self.store=store; self.paper=paper; selectionPopover = SelectionPopoverController(store: store) }
        func observe(_ view: PDFView) {
            observers.append(NotificationCenter.default.addObserver(forName:.PDFViewSelectionChanged,object:view,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.selectionChanged() }
            })
            observers.append(NotificationCenter.default.addObserver(forName:.PDFViewPageChanged,object:view,queue:.main) { [weak self] _ in
                Task { @MainActor in
                    guard let self,let document=self.view?.document,let page=self.view?.currentPage else { return }
                    self.store.savePage(document.index(for:page),for:self.paper.id)
                }
            })
        }
        func selectionChanged() {
            work?.cancel()
            if NSEvent.pressedMouseButtons & 1 != 0 { selectionPopover.dismiss(); return }
            let next=DispatchWorkItem { [weak self] in
                guard let self,self.store.route == .reading,self.store.selectedPaperID == self.paper.id, let view = self.view else { return }
                guard let selection=view.currentSelection,let text=selection.string,!TextTools.clean(text).isEmpty,let page=selection.pages.first else {
                    self.selectionPopover.dismiss(); self.store.clearSelection(); return
                }
                let index=self.view?.document?.index(for:page) ?? 0
                self.store.updateSelection(text,context:TextTools.context(in:page.string ?? text,selection:text),page:index)
                let line = selection.selectionsByLine().last ?? selection
                if let endPage = line.pages.last {
                    self.selectionPopover.show(anchoredTo: view.convert(line.bounds(for: endPage), from: endPage))
                }
            }
            work=next; DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:next)
        }
        deinit { work?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct TextReader: NSViewRepresentable {
    let text:String
    @ObservedObject var store:AppStore
    let fontSize:CGFloat
    let search:String
    func makeCoordinator() -> Coordinator { Coordinator(store:store) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.drawsBackground=false
        let view=NSTextView(); view.isEditable=false; view.isSelectable=true; view.isRichText=false; view.drawsBackground=false
        view.textContainerInset=NSSize(width:48,height:38)
        view.autoresizingMask=[.width]; view.isVerticallyResizable=true; view.isHorizontallyResizable=false
        view.textContainer?.widthTracksTextView=true; view.textContainer?.lineFragmentPadding=0
        view.delegate=context.coordinator; scroll.documentView=view
        context.coordinator.view=view; update(view,coordinator:context.coordinator)
        context.coordinator.selectionPopover.attach(to: view)
        context.coordinator.selectionPopover.selectionSettled = { [weak coordinator = context.coordinator] in coordinator?.updateSelection() }
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) { if let view=scroll.documentView as? NSTextView { update(view,coordinator:context.coordinator) } }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        coordinator.selectionTask?.cancel()
        coordinator.selectionPopover.invalidate()
        coordinator.view?.delegate=nil
        coordinator.view=nil
    }
    private func update(_ view:NSTextView,coordinator:Coordinator) {
        if coordinator.text != text || coordinator.fontSize != fontSize {
            coordinator.text=text; coordinator.fontSize=fontSize
            let paragraph=NSMutableParagraphStyle(); paragraph.lineSpacing=10; paragraph.paragraphSpacing=18
            view.textStorage?.setAttributedString(NSAttributedString(string:text,attributes:[.font:NSFont(name:"Georgia",size:fontSize) ?? NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor(red:0.16,green:0.20,blue:0.18,alpha:1),.paragraphStyle:paragraph]))
            view.scrollToBeginningOfDocument(nil)
        }
        if coordinator.query != search {
            coordinator.query=search
            if !search.isEmpty {
                let range=(text as NSString).range(of:search,options:.caseInsensitive)
                if range.location != NSNotFound { view.showFindIndicator(for:range); view.scrollRangeToVisible(range) }
            }
        }
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        let store:AppStore
        weak var view:NSTextView?
        var text="",query=""
        var fontSize:CGFloat=0
        var selectionTask:Task<Void,Never>?
        let selectionPopover: SelectionPopoverController
        init(store:AppStore) { self.store=store; selectionPopover = SelectionPopoverController(store: store) }
        func textViewDidChangeSelection(_ notification:Notification) {
            updateSelection()
        }
        func updateSelection() {
            selectionTask?.cancel()
            if NSEvent.pressedMouseButtons & 1 != 0 { selectionPopover.dismiss(); return }
            let paperID=store.selectedPaperID
            selectionTask=Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(120))
                guard !Task.isCancelled,let self,let view=self.view else {return}
                let selectedRange=view.selectedRange(),source=view.string
                guard selectedRange.length>0,let range=Range(selectedRange,in:source) else {
                    self.selectionPopover.dismiss(); self.store.clearSelection(); return
                }
                let selected=String(source[range])
                let context=await Task.detached(priority:.userInitiated) {TextTools.context(in:source,range:selectedRange)}.value
                guard !Task.isCancelled,self.view?.selectedRange()==selectedRange,
                      self.store.route == .reading,self.store.selectedPaperID == paperID else {return}
                self.store.updateSelection(selected,context:context,page:0)
                if let manager = view.layoutManager, let container = view.textContainer {
                    let glyphs = manager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
                    guard glyphs.length > 0 else { return }
                    var lastLine = NSRange()
                    _ = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location + glyphs.length - 1, effectiveRange: &lastLine)
                    let rect = manager.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, lastLine), in: container)
                        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
                    self.selectionPopover.show(anchoredTo: rect)
                }
            }
        }
        deinit {selectionTask?.cancel()}
    }
}
