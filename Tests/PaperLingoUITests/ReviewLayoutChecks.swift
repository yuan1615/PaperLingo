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
    func sourceRepairChecks() async throws {
        let paper=Paper(id:"wrap-repair",title:"Synthetic wrapped source",filename:"wrapped.txt",kind:"WEB")
        let source="Prior sentence. The efﬁcient experi-\nmental system uses state-\nof-the-art inputs [2]. Next sentence."
        try source.write(to:store.fileURL(paper),atomically:true,encoding:.utf8)
        try store.db!.addPaper(paper)
        try store.db!.record(text:"experimental",translation:"实验的",context:"The efficient experimental system uses stateof-the-art inputs [2].",paper:paper,page:0)
        try store.reload()
        let word=store.words[0],before=try store.db!.vocabulary()
        await store.prepareVocabularyContext(word)
        let recovered=store.vocabularyContext(for:word)
        try check(recovered == "The efficient experimental system uses state-of-the-art inputs [2].","Vocabulary recovers a complete source with line breaks, ligatures and compound hyphens repaired")
        try check(try store.db!.vocabulary() == before,"Repairing a legacy display context preserves stored quotes and learning statistics")
        let prepare=store.audio.prepareForSpeech
        store.audio.prepareForSpeech=nil
        store.audio.speak(recovered);store.audio.togglePause()
        try check(store.audio.currentText == "The efficient experimental system uses state-of-the-art inputs.","The shared playback path removes citations only from its speech copy")
        store.audio.stop();store.audio.prepareForSpeech=prepare
        try store.db!.deleteWord(word.id);try store.db!.deletePaper(paper.id);try store.reload()
    }
    func practiceChecks() throws {
        let earlier=Date().addingTimeInterval(-3600)
        for index in 0..<30 {try store.db!.record(text:"practice-\(index)",translation:"合成练习词",context:"An isolated practice fixture.",paper:nil,page:0,now:earlier)}
        try store.reload()
        for word in store.words.prefix(3) {try store.db!.review(word,grade:.good,mode:"recognition")}
        try store.db!.review(store.words[3],grade:.again,mode:"recognition")
        try store.reload()
        let words=store.words,due=store.dueWords.map(\.id),reviews=try store.db!.reviewsToday()
        store.route = .review;store.beginReview(listening:false)
        try check(store.queue.count == 20 && Set(store.queue.map(\.id)).count == 20 && store.queue.allSatisfy{due.contains($0.id)},"A practice group samples 20 distinct due cards and excludes future reviews")
        for listening in [true,false,true,false] {
            let previous=store.queue.map(\.id)
            store.revealed=true
            store.beginReview(listening:listening)
            try check(store.queue.map(\.id) != previous && store.reviewIndex == 0 && !store.revealed && store.listening == listening,"Starting a new \(listening ? "listening" : "recognition") group changes the order and resets its card state")
        }
        try check(try store.db!.vocabulary() == words && store.db!.reviewsToday() == reviews && store.dueWords.map(\.id) == due,"Random group creation preserves learning records and deterministic due counts")
        let group=store.queue.map(\.id),forgotten=store.currentCard!.id
        store.revealed=true;store.grade(.again)
        try check(store.queue.map(\.id) == group && store.reviewIndex == 1 && !store.revealed,"Grading advances the current group without reshuffling its remaining cards")
        store.setReviewMode(listening:true)
        try check(store.queue.map(\.id) == group && store.reviewIndex == 1 && store.listening && !store.revealed,"Changing recognition/listening mode preserves the current group and progress")
        store.revealed=true;store.setReviewMode(listening:true)
        try check(store.revealed,"Selecting the already active mode preserves the revealed answer")
        let current=store.currentCard!.id
        store.reviewContext="A previously recovered complete source sentence."
        let routes:[Route]=[.reading,.library,.vocabulary,.settings]
        for route in routes {
            store.route=route;store.openReview()
            try check(store.queue.map(\.id) == group && store.reviewIndex == 1 && store.currentCard?.id == current && store.listening && store.revealed && store.reviewContext == "A previously recovered complete source sentence.","Returning from \(route.rawValue) resumes the current card, order, mode, source and revealed answer")
        }
        let prepare=store.audio.prepareForSpeech
        store.audio.prepareForSpeech=nil;store.route = .reading
        store.audio.speak("A reading from another page.");store.audio.togglePause();store.openReview()
        try check(!store.audio.playing && store.revealed && store.currentCard?.id == current,"Returning to practice stops another page's audio without resetting the card")
        store.audio.prepareForSpeech=prepare
        store.reviewIndex=store.queue.count;store.revealed=false
        store.route = .settings;store.openReview()
        try check(store.currentCard == nil && store.reviewIndex == group.count && store.queue.map(\.id) == group,"Returning to a completed group keeps its completion state")
        store.beginReview(listening:false)
        try check(!store.queue.contains{$0.id == forgotten},"A just-forgotten card waits for its existing ten-minute retry interval")
        try check(store.queue.map(\.id) != group && store.reviewIndex == 0 && !store.revealed,"Explicitly starting another group creates a fresh randomized session")
        let removed=store.currentCard!
        try store.db!.deleteWord(removed.id);try store.reload()
        store.revealed=true;store.route = .vocabulary;store.openReview()
        try check(!store.queue.contains{$0.id == removed.id} && store.reviewIndex == 0 && !store.revealed,"Resuming safely skips a card deleted while on another page")
        store.stopReviewContext()
        for word in words {try store.db!.deleteWord(word.id)}
        try store.reload();store.queue=[];store.reviewIndex=0
    }
    func run() async throws {
        UserDefaults.standard.set("system",forKey:"speechProvider")
        store = AppStore(); store.layout.sidebarVisible = true
        try await sourceRepairChecks()
        try practiceChecks()
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
