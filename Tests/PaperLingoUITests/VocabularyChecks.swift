import AppKit
import CoreGraphics
import PaperCore
import SwiftUI

@MainActor final class VocabularyChecks:NSObject,NSApplicationDelegate {
    let work=URL(fileURLWithPath:CommandLine.arguments[1])
    let port=Int(ProcessInfo.processInfo.environment["PAPERLINGO_TEST_MODEL_PORT"]!)!
    var store:AppStore!
    var window:NSWindow!
    var checks:[String]=[]
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task { @MainActor in do {try await run();finish(nil)} catch {finish(error)} }
    }
    func check(_ condition:Bool,_ message:String)throws {
        guard condition else {throw AppError.message(message)}
        checks.append(message);print("PASS",message);fflush(stdout)
    }
    func settle(_ ms:Int=250)async {try? await Task.sleep(for:.milliseconds(ms));window?.contentView?.layoutSubtreeIfNeeded();window?.displayIfNeeded()}
    func until(_ predicate:()async throws->Bool)async throws {
        let deadline=Date().addingTimeInterval(6)
        while Date()<deadline {if try await predicate(){return};await settle(50)}
        throw AppError.message("Native vocabulary check timed out")
    }
    func status()async throws->[String:Any] {
        try JSONSerialization.jsonObject(with:await LocalAPI.request(port:port,path:"/test/status")) as! [String:Any]
    }
    func calls()async throws->Int {try await status()["calls"] as! Int}
    func configure(_ outcome:String="valid",delay:Double=0.05,unloadDelay:Double=0)async throws {
        _=try await LocalAPI.request(port:port,path:"/test/configure",body:["outcome":outcome,"delay":delay,"unloadDelay":unloadDelay])
    }
    func snapshot(_ name:String)throws {
        let view=window.contentView!
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw AppError.message("No bitmap")}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let context=CGContext(data:nil,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue),let image=bitmap.cgImage else {throw AppError.message("No image context")}
        let rect=CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
        context.setFillColor(NSColor.white.cgColor);context.fill(rect);context.draw(image,in:rect)
        guard let image=context.makeImage(),let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw AppError.message("No PNG")}
        try data.write(to:work.appendingPathComponent(name+".png"))
    }
    func run()async throws {
        UserDefaults.standard.set("system",forKey:"speechProvider")
        let client=ResearchClient(port:port)
        store=AppStore(researchClient:client,translationPort:port)
        store.engines.analysisReady=true
        let paper=Paper(id:"vocab-fixture",title:"Synthetic language fixture",filename:"fixture.txt",kind:"WEB")
        let source="A robust estimate remains stable under small perturbations. In contrast to the baseline, the method does not require labels."
        try source.write(to:store.fileURL(paper),atomically:true,encoding:.utf8)
        try store.db!.addPaper(paper)
        try store.db!.record(text:"robust",translation:"稳健的",context:"A robust estimate remains stable under small perturbations.",paper:paper,page:0)
        try store.db!.record(text:"in contrast to",translation:"与……相比",context:"In contrast to the baseline, the method does not require labels.",paper:paper,page:0)
        try store.reload()
        var a=store.words.first{$0.text=="robust"}!,b=store.words.first{$0.text=="in contrast to"}!
        store.route = .vocabulary;store.showWordDetails(a)
        try await until {self.store.wordExplanationTask == nil}
        try check(store.explanation(for:a) != nil,"Entering an expanded word generates a contextual explanation")
        try check(try store.db!.vocabulary().first{$0.id==a.id} == a,"Explanation generation preserves lookup frequency, translation and review records")
        let request=try await status()["last_request"] as! [String:Any]
        let options=request["options"] as! [String:Any]
        try check(request["think"] as? Bool == false && request["keep_alive"] as? Int == 0 && options["num_predict"] as? Int == 384 && options["num_ctx"] as? Int == 3072,"Model request disables thinking and bounds output, context and residence")
        let before=try await calls()
        store.showWordDetails(b);await settle(100);store.showWordDetails(a)
        try await until {self.store.wordExplanationTask == nil}
        try check(try await calls() == before,"Rapid switching cancels debounce; reopening a cached word makes no model call")
        let reopened=AppStore(researchClient:client,translationPort:port)
        try check(reopened.explanation(for:a) == store.explanation(for:a),"Contextual explanation persists across store reopening")
        store.engines.modelDigests[ResearchModels.analysis]="changed-model"
        try check(store.explanation(for:a) == nil,"A changed model signature invalidates its cached explanation")
        store.engines.modelDigests.removeValue(forKey:ResearchModels.analysis)


        let changed="The robust structure resisted mechanical stress."
        try changed.write(to:store.fileURL(paper),atomically:true,encoding:.utf8)
        try store.db!.record(text:a.text,translation:a.translation,context:changed,paper:paper,page:0)
        try store.reload();a=store.words.first{$0.id==a.id}!
        try check(store.explanation(for:a) == nil,"A new paper context invalidates the old explanation")
        store.showWordDetails(a);try await until {self.store.wordExplanationTask == nil}
        var saved=store.explanation(for:a)!
        let regeneratedCalls=try await calls()
        try check(saved.sourceContext == changed && regeneratedCalls == before+1,"Changed context is regenerated once using the new source")
        try await configure("invalid");store.showWordDetails(a,force:true)
        try await until {self.store.wordExplanationTask == nil}
        try check(store.wordExplanationError != nil && store.explanation(for:a) == saved,"Malformed output shows an error and preserves the previous valid explanation")
        try await configure();store.showWordDetails(a,force:true)
        try await until {self.store.wordExplanationTask == nil}
        try check(store.wordExplanationError == nil,"Explicit retry recovers without an automatic retry loop")
        saved=store.explanation(for:a)!

        try await configure(delay:10)
        var count=try await calls();store.showWordDetails(b)
        try await until {try await self.calls()>count}
        store.audio.speak("Speech takes priority over vocabulary explanations.")
        store.audio.togglePause()
        try await until {self.store.audio.playing}
        try check(store.wordExplanationTask == nil && store.explanation(for:b) == nil,"Speech preempts a pending explanation without caching a late response")
        let speechEvents=try await status()["events"] as! [[String:Any]]
        try check(speechEvents.last?["kind"] as? String == "unload","Speech starts only after analysis-model cleanup")
        try check(store.audio.paused,"Pause requested during model cleanup remains in effect when speech starts")

        store.audio.stop()
        try await configure()
        count=try await calls();store.researchBusy=true;store.showWordDetails(b)
        await settle(1150)
        try check(try await calls() == count,"Background explanation waits while a paper task owns the models")
        store.researchBusy=false;try await until {self.store.wordExplanationTask == nil}
        try check(store.explanation(for:b) != nil,"A waiting word resumes when paper work finishes")

        try await configure(delay:10)
        count=try await calls();store.showWordDetails(a,force:true)
        try await until {try await self.calls()>count}
        store.updateSelection("priority",context:"Translation has priority.",page:0)
        await store.translate()
        try check(store.translation == "即时译文","Reading translation remains on the translation model")
        let events=try await status()["events"] as! [[String:Any]]
        let kinds=events.compactMap{$0["kind"] as? String}
        try check(kinds.suffix(2).elementsEqual(["unload","translation"]),"Translation waits for explanation cleanup before starting its own model")
        try check(store.explanation(for:a) == saved,"A cancelled refresh retains the cached context explanation")
        try await configure(delay:10,unloadDelay:0.25)
        count=try await calls();store.showWordDetails(a,force:true)
        try await until {try await self.calls()>count}
        store.updateSelection("first-selection",context:"The first selection is requested.",page:0)
        let deferredTranslation=Task {await self.store.translate()}
        await settle(50)
        store.updateSelection("second-selection",context:"The second selection is not requested.",page:0)
        await deferredTranslation.value
        let lastTranslation=try await status()["last_translation"] as! [String:Any]
        let prompt=(lastTranslation["messages"] as! [[String:Any]])[0]["content"] as! String
        try check(prompt.contains("first-selection") && !prompt.contains("second-selection") && store.translation.isEmpty,"Selection changes during model cleanup cannot redirect an earlier translation or show a stale result")
        try await configure(delay:10)


        count=try await calls();store.showWordDetails(a,force:true)
        try await until {try await self.calls()>count}
        store.route = .reading;await store.yieldWordExplanation()
        let activeAfterExit=try await status()["active"] as! Int
        try check(store.wordExplanationTask == nil && activeAfterExit==0,"Leaving the vocabulary page cancels inference and releases the model")
        let start=Date()
        do {_=try await client.explainWord(WordExplanationInput(expression:"robust",context:changed),timeout:0.15);throw AppError.message("Timeout was ignored")}
        catch {try check(error.localizedDescription.contains("超时"),"A hard deadline cancels a stalled generation")}
        await client.unload(ResearchModels.analysis)
        try check(Date().timeIntervalSince(start)<2,"Deadline cleanup does not wait for the fixture's ten-second inference")
        try await configure("length")
        do {_=try await client.explainWord(WordExplanationInput(expression:"robust",context:changed));throw AppError.message("Output limit was ignored")}
        catch {try check(error.localizedDescription.contains("上限"),"Truncated model output is rejected")}
        try await configure("long")
        do {_=try await client.explainWord(WordExplanationInput(expression:"robust",context:changed));throw AppError.message("Long output was ignored")}
        catch {try check(error.localizedDescription.contains("过长"),"Verbose output is rejected without silently clipping its meaning")}

        try await configure()
        let noContext=try await client.explainWord(WordExplanationInput(expression:"robust",context:""))
        try check(noContext.inContext == "未提供原句，无法判断文中具体含义","Missing source context cannot produce invented contextual claims")
        try await configure(delay:10)
        try store.db!.record(text:"transient",translation:"短暂的",context:"A transient signal appears briefly.",paper:nil,page:0)
        try store.reload();let uncached=store.words.first{$0.text=="transient"}!
        count=try await calls();store.route = .vocabulary;store.showWordDetails(uncached)
        try await until {try await self.calls()>count}
        store.pauseWordExplanation();await store.yieldWordExplanation()
        let pausedCount=try await calls();store.resumeWordExplanationIfNeeded();await settle(900)
        try check(try await calls() == pausedCount,"Explicit cancellation is not undone by automatic idle resumption")
        count=try await calls();store.showWordDetails(uncached)
        try await until {try await self.calls()>count}
        store.stopLocalEngines();await store.yieldWordExplanation()
        let stoppedCount=try await calls();store.resumeWordExplanationIfNeeded();await settle(900)
        try check(try await calls() == stoppedCount,"Stopping local engines suppresses automatic explanation resumption")

        try await configure()

        store.route = .vocabulary;store.expandedWordID=a.id
        window=NSWindow(contentRect:NSRect(x:80,y:80,width:860,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView=NSHostingView(rootView:RootView(store:store).preferredColorScheme(.light))
        window.title="PaperLingo isolated vocabulary checks";window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        await settle(600);try snapshot("vocabulary-860")
        window.setContentSize(NSSize(width:1100,height:800));await settle();try snapshot("vocabulary-1100")
        try check(store.explanation(for:a) != nil,"The vocabulary view displays its cached explanation immediately")
        let cachedCalls=try await calls()
        store.queue=[a];store.reviewContext=a.context;store.revealed=true;store.route = .review
        await settle(500);try snapshot("review-cached-explanation")
        try check(try await calls() == cachedCalls,"Review reuses cached explanation without invoking the analysis model")

    }
    func finish(_ error:Error?) {
        store?.shuttingDown=true;store?.cancelWordExplanation();store?.audio.stop()
        let report:[String:Any]=["passed":error==nil,"checks":checks,"error":error?.localizedDescription ?? "","scope":"Isolated native app, synthetic learning database, loopback HTTP fixture and system speech; no real-model inference"]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:work.appendingPathComponent("vocabulary-verification.json"));print(String(decoding:data,as:UTF8.self))}
        fflush(stdout);exit(error==nil ? 0:1)
    }
}
@main struct VocabularyChecksMain {
    @MainActor static func main() {let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=VocabularyChecks();app.delegate=delegate;app.run()}
}
