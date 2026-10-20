import AppKit
import CoreGraphics
import PaperCore
import SwiftUI

/// A separate app identity and data directory keep these native UI checks out of the user's library.
@MainActor final class ReviewLayoutChecks: NSObject, NSApplicationDelegate {
    let work = URL(fileURLWithPath: CommandLine.arguments[1])
    var window: NSWindow!
    var store: AppStore!
    var checks: [String] = []
    let sentence = "The unfamiliar expression occurs in a deliberately long synthetic sentence, " + String(repeating: "whose complete context remains available while the reader listens, ", count: 24) + "ending with END-OF-COMPLETE-SENTENCE."

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); finish(nil) } catch { finish(error) }
        }
    }
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError.message(name) }
        checks.append(name); print("PASS \(name)"); fflush(stdout)
    }
    func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        let found = (root as? T).map { [$0] } ?? []
        return found + root.subviews.flatMap { views(type, in: $0) }
    }
    func speechButtonPoints() throws -> [NSPoint] {
        let root=window.contentView!,scroll=try scrollView()
        let card=scroll.convert(scroll.bounds,to:root)
        guard let bitmap=root.bitmapImageRepForCachingDisplay(in:card) else {throw AppError.message("No card bitmap")}
        root.cacheDisplay(in:card,to:bitmap)
        var best:(count:Int,x:CGFloat,y:CGFloat)?
        for y in stride(from:0,to:bitmap.pixelsHigh,by:3) {
            var matches:[Int]=[]
            for x in stride(from:0,to:bitmap.pixelsWide,by:3) {
                guard let color=bitmap.colorAt(x:x,y:y) else {continue}
                if abs(color.redComponent-0.21)<0.10 && abs(color.greenComponent-0.39)<0.07 && abs(color.blueComponent-0.31)<0.08 {matches.append(x)}
            }
            if matches.count>30,matches.count>(best?.count ?? 0),let first=matches.first,let last=matches.last {
                best=(matches.count,CGFloat(first+last)/2,CGFloat(y))
            }
        }
        guard let best else {
            if let png=bitmap.representation(using:.png,properties:[:]) {try png.write(to:work.appendingPathComponent("card-diagnostic.png"))}
            for view in views(NSScrollView.self,in:root) {print("SCROLL",view.bounds,view.visibleRect,view.convert(view.bounds,to:root),view.accessibilityIdentifier())}
            throw AppError.message("Prominent source speech button is not visible")
        }
        let x=card.minX+best.x/CGFloat(bitmap.pixelsWide)*card.width
        let offset=best.y/CGFloat(bitmap.pixelsHigh)*card.height
        let y=root.isFlipped ? card.minY+offset : card.maxY-offset
        // Keep both bitmap orientations for SDKs that cache flipped hosting views differently.
        return [y,card.minY+card.maxY-y].map {window.convertPoint(toScreen:root.convert(NSPoint(x:x,y:$0),to:nil))}
    }
    func clickSpeech(expected:String) async throws {
        for point in try speechButtonPoints() {
            click(screen:point);await settle()
            if store.audio.playing && store.audio.currentText == expected {return}
            store.audio.stop()
        }
        throw AppError.message("Native source speech button did not play the expected text")
    }
    func click(screen point: NSPoint) {
        let local = window.convertPoint(fromScreen:point)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = NSEvent.mouseEvent(with:type,location:local,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }
    func controlPoint(fromRight offset: CGFloat) throws -> NSPoint {
        let scroll = try scrollView()
        let frame = window.convertToScreen(scroll.convert(scroll.bounds,to:nil))
        return NSPoint(x:frame.maxX-offset,y:frame.maxY+36)
    }
    func gradingPixels() throws -> Data {
        let root = window.contentView!, scroll = try scrollView()
        let card = scroll.convert(scroll.bounds,to:root)
        let rect = root.isFlipped ? NSRect(x:card.minX,y:card.maxY+4,width:card.width,height:root.bounds.height-card.maxY-4) : NSRect(x:card.minX,y:0,width:card.width,height:card.minY-4)
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in:rect) else {throw AppError.message("Cannot capture grading controls")}
        root.cacheDisplay(in:rect,to:bitmap)
        guard let pixels = bitmap.bitmapData else {throw AppError.message("Cannot read grading pixels")}
        return Data(bytes:pixels,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    func scrollView() throws -> NSScrollView {
        guard let scroll = views(NSScrollView.self, in: window.contentView!).max(by: { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }) else {
            throw AppError.message("Missing review scroll view")
        }
        return scroll
    }
    func geometry() throws -> [NSRect] {
        let scroll = try scrollView()
        return [scroll.convert(scroll.bounds, to: nil), scroll.contentView.bounds]
    }
    func unchanged(_ reference: [NSRect]) throws -> Bool {
        let current = try geometry()
        return zip(reference, current).allSatisfy { a, b in
            abs(a.minX-b.minX) < 0.5 && abs(a.minY-b.minY) < 0.5 && abs(a.width-b.width) < 0.5 && abs(a.height-b.height) < 0.5
        }
    }
    func snapshot(_ name: String) throws {
        let view = window.contentView!
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Cannot capture UI") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let context = CGContext(data:nil,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue), let image = bitmap.cgImage else { throw AppError.message("Cannot composite UI") }
        let rect = CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
        context.setFillColor(NSColor.white.cgColor); context.fill(rect); context.draw(image,in:rect)
        guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:]) else { throw AppError.message("Cannot save UI") }
        try data.write(to:work.appendingPathComponent(name + ".png"))
    }
    func run() async throws {
        UserDefaults.standard.set("system",forKey:"speechProvider")
        store = AppStore(); store.layout.sidebarVisible = true
        let paper = Paper(id:"review-layout-fixture",title:"Synthetic review fixture",filename:"fixture.txt",kind:"WEB")
        try store.db!.addPaper(paper)
        try store.db!.record(text:"unfamiliar",translation:"不熟悉的",context:sentence,paper:paper,page:0)
        try store.reload(); store.queue = store.words; store.route = .review
        store.reviewContext = sentence; store.revealed = true
        window = NSWindow(contentRect:NSRect(x:80,y:80,width:860,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "PaperLingo isolated review layout checks"
        window.contentView = NSHostingView(rootView:RootView(store:store).preferredColorScheme(.light))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        await settle()
        try snapshot("review-original-button")
        let scroll = try scrollView(), frame = window.convertToScreen(scroll.convert(scroll.bounds,to:nil))
        let sourcePoint = try speechButtonPoints()[0]
        try check(frame.contains(sourcePoint),"Original sentence button is visible without scrolling in an 860 × 620 window")
        try await clickSpeech(expected:sentence)
        try check(store.audio.playing && store.audio.currentText == sentence,"Original sentence button plays the complete source after a native click")
        click(screen:try controlPoint(fromRight:60)); await settle()
        try check(store.audio.paused,"Pause control pauses actual system speech")
        click(screen:try controlPoint(fromRight:60)); await settle()
        try check(!store.audio.paused && store.audio.playing,"Resume control resumes actual system speech")
        click(screen:try controlPoint(fromRight:24)); await settle()
        try check(!store.audio.playing && !store.audio.busy,"Stop control ends speech")

        for size in [NSSize(width:860,height:620),NSSize(width:1100,height:800),NSSize(width:1440,height:900)] {
            window.setContentSize(size); await settle()
            let scroll = try scrollView()
            let end = max(0,(scroll.documentView?.bounds.height ?? 0)-scroll.contentView.bounds.height)
            scroll.contentView.scroll(to:NSPoint(x:0,y:end/2)); scroll.reflectScrolledClipView(scroll.contentView)
            await settle()
            let reference = try geometry(), grades = try gradingPixels()
            try check(end > 100,"Long source remains scrollable at \(Int(size.width)) × \(Int(size.height))")
            let states: [(String, () -> Void)] = [
                ("first segment",{self.store.audio.busy=true;self.store.audio.label="OmniVoice"}),
                ("playing",{self.store.audio.busy=false;self.store.audio.playing=true;self.store.audio.totalParts=8;self.store.audio.currentPart=1;self.store.audio.currentText=self.sentence}),
                ("next segment",{self.store.audio.busy=true;self.store.audio.playing=false;self.store.audio.currentPart=2}),
                ("paused",{self.store.audio.paused=true}),
                ("error",{self.store.audio.busy=false;self.store.audio.playing=false;self.store.audio.error=String(repeating:"合成诊断错误：连接中断，请重试。",count:20)}),
                ("stopped",{self.store.audio.stop()})
            ]
            for (name,change) in states {
                change(); await settle()
                try check(try unchanged(reference) && gradingPixels() == grades,"Card size, scroll position and grading region stay fixed during \(name) at \(Int(size.width)) × \(Int(size.height))")
                if name == "playing" {
                    try snapshot("review-\(Int(size.width))-playing")
                    click(screen:try controlPoint(fromRight:96)); await settle()
                    try check(NSApp.windows.contains(where:{$0.isVisible && NSStringFromClass(type(of:$0)).contains("Popover")}),"Playback details open on demand at \(Int(size.width))")
                    try check(try unchanged(reference),"Opening playback details preserves review geometry at \(Int(size.width))")
                    // A native Escape event closes the transient details popover.
                    let target = NSApp.keyWindow ?? window!
                    let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:target.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
                    NSApp.postEvent(escape,atStart:false)
                    await settle()
                }
            }
            scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView); await settle()
            try snapshot("review-\(Int(size.width))-idle")
        }
        window.setContentSize(NSSize(width:860,height:620))
        store.listening=true; store.revealed=false; await settle()
        let listeningGeometry=try geometry(), revealPixels=try gradingPixels()
        store.audio.busy=true; await settle(); try snapshot("review-listening")
        try check(try unchanged(listeningGeometry) && gradingPixels() == revealPixels,"Listening mode preserves its card and reveal button during generation")
        store.audio.stop(); store.listening=false; store.revealed=true
        var fullSentence=store.queue[0]
        fullSentence.text="This is a complete synthetic sentence for the playback check."
        fullSentence.kind="句子"; fullSentence.context=fullSentence.text
        store.queue=[fullSentence]; store.reviewContext=fullSentence.text; await settle()
        try snapshot("review-sentence")
        try await clickSpeech(expected:fullSentence.text)
        try check(store.audio.playing && store.audio.currentText == fullSentence.text,"Saved sentence cards expose their own complete-source playback button")
        store.audio.stop(); store.stopReviewContext()
    }
    func finish(_ error: Error?) {
        store?.audio.stop(); store?.stopReviewContext()
        let report: [String:Any] = ["passed":error == nil,"checks":checks,"error":error?.localizedDescription ?? "","scope":"Separate app identity and synthetic data; native mouse events, system speech, pixel comparisons and programmatic scroll position; synthesis states are injected without model inference."]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:work.appendingPathComponent("review-verification.json")); print(String(decoding:data,as:UTF8.self))
        }
        fflush(stdout); exit(error == nil ? 0 : 1)
    }
}

@main struct ReviewLayoutChecksMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = ReviewLayoutChecks(); app.delegate=delegate; app.run()
    }
}
