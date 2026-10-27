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
    func addWords(_ expressions:[String])throws {
        for text in expressions {try store.db!.record(text:text,translation:"合成测试",context:"The \(text) expression is part of an isolated language fixture.",paper:nil,page:0)}
        try store.reload()
    }
    func accessibilityElement(_ id:String,in node:Any,depth:Int=0)->NSAccessibilityProtocol? {
        guard depth<30,let element=node as? NSAccessibilityProtocol else {return nil}
        if element.accessibilityIdentifier() == id {return element}
        for child in element.accessibilityChildren() ?? [] {
            if let found=accessibilityElement(id,in:child,depth:depth+1) {return found}
        }
        return nil
    }
    func clickBatchButton()throws {
        let point:NSPoint
        if let button=accessibilityElement("vocabulary.startBatch",in:window.contentView!) {
            let frame=button.accessibilityFrame()
            point=window.convertPoint(fromScreen:NSPoint(x:frame.midX,y:frame.midY))
        } else {
            // SwiftUI can omit virtual identifiers after a conditional control
            // changes. Use the button position verified in the 1100x800 render.
            let root=window.contentView!
            let y=root.isFlipped ? root.bounds.minY+252 : root.bounds.maxY-252
            point=root.convert(NSPoint(x:root.bounds.maxX-106,y:y),to:nil)
        }
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1),
              let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0) else {throw AppError.message("No mouse event")}
        // AppKit buttons consume mouse-up from their tracking loop during mouseDown.
        NSApp.postEvent(up,atStart:false)
        window.sendEvent(down)
    }
    func batchChecks()async throws {
        store.engines.analysisReady=true
        let preserved=try store.db!.vocabulary()
        try addWords(["adaptive","sparse","compact"])
        try store.db!.promote(text:"This is a saved sentence for testing.",translation:"合成整句",context:"This is a saved sentence for testing.",paper:nil,page:0)
        try store.reload()
        let sentence=store.words.first{$0.kind == "句子"}!
        let expected=store.unexplainedWords.count
        let before=try await status(),beforeCalls=before["calls"] as! Int
        let beforeUnloads=(before["events"] as! [[String:Any]]).filter{$0["kind"] as? String == "unload"}.count
        try await configure()
        store.startWordExplanationBatch();store.startWordExplanationBatch()
        store.focusVocabulary([])
        try await until {self.store.wordExplanationTask == nil}
        let after=try await status()
        let requests=Array((after["requests"] as! [[String:Any]]).dropFirst(beforeCalls))
        let unloads=(after["events"] as! [[String:Any]]).filter{$0["kind"] as? String == "unload"}.count
        try check(store.wordExplanationBatch?.completed == expected && store.unexplainedWords.isEmpty,"One batch fills every uncached word and phrase, even when the visible list is empty")
        try check(try await calls() == beforeCalls+expected && store.explanation(for:sentence) == nil,"Batch skips valid caches and sentences; repeated clicks cannot duplicate requests")
        try check(requests.allSatisfy{$0["keep_alive"] as? Int == 60} && unloads == beforeUnloads+1,"A continuous batch reuses the model and unloads once when finished")
        let original=try store.db!.vocabulary().filter{word in preserved.contains{$0.id == word.id}}
        try check(original == preserved,"Batch generation preserves all pre-existing vocabulary and learning records")

        try addWords(["faulty","recoverable"])
        _=try await LocalAPI.request(port:port,path:"/test/configure",body:["outcomes":["faulty":"invalid"]])
        var count=try await calls();store.startWordExplanationBatch()
        try await until {self.store.wordExplanationTask == nil}
        try check(store.wordExplanationBatch?.failed == 1 && store.wordExplanationBatch?.completed == 1,"A malformed explanation is counted as failed while remaining words continue")
        store.resumeWordExplanationIfNeeded();await settle(900)
        try check(try await calls() == count+2 && store.unexplainedWords.map(\.text) == ["faulty"],"Failed items remain unprocessed and never enter an automatic retry loop")
        _=try await LocalAPI.request(port:port,path:"/test/configure",body:["outcomes":[:]])
        count=try await calls();store.startWordExplanationBatch()
        try await until {self.store.wordExplanationTask == nil}
        try check(try await calls() == count+1 && store.unexplainedWords.isEmpty,"Clicking batch again retries only the previously failed item")

        try addWords(["pendingalpha","pendingbeta","pendinggamma"])
        try await configure(delay:0.25)
        store.startWordExplanationBatch()
        try await until {(self.store.wordExplanationBatch?.completed ?? 0)>0}
        store.pauseWordExplanation();await store.yieldWordExplanation()
        let completed=store.wordExplanationBatch!.completed,remaining=store.unexplainedWords.count
        count=try await calls();store.resumeWordExplanationIfNeeded();await settle(900)
        let cancelledCalls=try await calls()
        try check(completed>0 && remaining>0 && !store.batchingWordExplanations && cancelledCalls == count,"Cancelling a batch keeps completed results and suppresses idle resumption")
        try await configure();store.startWordExplanationBatch()
        try await until {self.store.wordExplanationTask == nil}
        try check(try await calls() == count+remaining && store.unexplainedWords.isEmpty,"Restarting a cancelled batch only processes its unfinished words")

        try addWords(["handoff","yielding"])
        try await configure(delay:10)
        count=try await calls();store.startWordExplanationBatch()
        try await until {try await self.calls()>count}
        try await configure()
        store.updateSelection("batch-priority",context:"Translation interrupts a batch.",page:0)
        await store.translate()
        try await until {self.store.wordExplanationTask == nil}
        let events=try await status()["events"] as! [[String:Any]]
        let kinds=events.compactMap{$0["kind"] as? String}
        let translation=kinds.lastIndex(of:"translation")!
        try check(kinds[translation-1] == "unload" && store.wordExplanationBatch?.completed == 2 && store.unexplainedWords.map(\.text) == ["batch-priority"],"Foreground translation waits for cleanup, then the batch resumes its interrupted item and remaining queue")
        try check(store.wordExplanationBatch?.total == 2,"New lookups made during a batch are left for the next explicit batch click")

        try addWords(["queued"])
        count=try await calls();store.researchBusy=true;store.startWordExplanationBatch()
        await settle(650)
        try check(try await calls() == count,"A queued batch does not load its model while paper work is busy")
        store.researchBusy=false
        try await until {self.store.wordExplanationTask == nil}
        try check(store.unexplainedWords.isEmpty,"A queued batch starts automatically after foreground work becomes idle")

        try addWords(["departure"])
        try await configure(delay:10)
        count=try await calls();store.startWordExplanationBatch()
        try await until {try await self.calls()>count}
        store.route = .reading;await store.yieldWordExplanation()
        let active=try await status()["active"] as! Int
        try check(!store.batchingWordExplanations && active == 0,"Leaving vocabulary cancels the batch and releases the model")
        store.route = .vocabulary;store.resumeWordExplanationIfNeeded();await settle(650)
        try check(try await calls() == count+1,"Returning to vocabulary cannot silently restart a cancelled batch")
        try await configure();store.startWordExplanationBatch()
        try await until {self.store.wordExplanationTask == nil}
        try check(try await status()["max_active"] as! Int == 1,"All single, batch and preemption requests remain serial")
    }
    func run()async throws {
        UserDefaults.standard.set("system",forKey:"speechProvider")
        let client=ResearchClient(port:port)
        store=AppStore(researchClient:client,translationPort:port)
        if ProcessInfo.processInfo.environment["PAPERLINGO_REFERENCE_VOICE_FIXTURE"] == "1" {
            try check(store.engines.voiceCatalog?.voices.count == 3,"The app loads its bundled reference voice catalog")
            try check(store.audio.referenceVoice == store.engines.referenceVoice && store.audio.voiceCatalogSignature == store.engines.voiceCatalog?.signature,"Speech receives the app-session voice and exact catalog signature")
            let next=EngineManager()
            try check(next.referenceVoice?.id != store.engines.referenceVoice?.id,"A new app session selects a different reference when alternatives exist")
        }
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

        try await batchChecks()

        store.route = .vocabulary;store.expandedWordID=a.id
        window=NSWindow(contentRect:NSRect(x:80,y:80,width:860,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView=NSHostingView(rootView:RootView(store:store).preferredColorScheme(.light))
        window.title="PaperLingo isolated vocabulary checks";window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        await settle(600);try snapshot("vocabulary-860")
        window.setContentSize(NSSize(width:1100,height:800));await settle();try snapshot("vocabulary-1100")
        try check(store.explanation(for:a) != nil,"The vocabulary view displays its cached explanation immediately")
        try addWords(["buttontrigger"]);try await configure(delay:0.3);await settle()
        try snapshot("vocabulary-batch-pending")
        try clickBatchButton()
        await settle(80)
        try check(store.batchingWordExplanations,"The visible batch button starts processing through native mouse events")
        await settle(80);try snapshot("vocabulary-batch-running")
        try await until {self.store.wordExplanationTask == nil}
        try check(store.unexplainedWords.isEmpty,"The native button saves the requested explanation")
        await settle();try snapshot("vocabulary-batch-complete")
        let cachedCalls=try await calls()
        store.queue=[a];store.reviewContext=a.context;store.revealed=true;store.route = .review
        await settle(500);try snapshot("review-cached-explanation")
        try check(try await calls() == cachedCalls,"Review reuses cached explanation without invoking the analysis model")
        if ProcessInfo.processInfo.environment["PAPERLINGO_REFERENCE_VOICE_FIXTURE"] == "1" {
            let initial=store.engines.referenceVoice!
            let other=store.engines.voiceCatalog!.voices.first{$0.id != initial.id}!
            let prepare=store.audio.prepareForSpeech
            store.audio.prepareForSpeech=nil
            UserDefaults.standard.set("system",forKey:"speechProvider")
            store.audio.speak("This is an isolated playback check. Switching the selected speaker should stop this reading and clear the remaining sentences.")
            store.audio.togglePause()
            try check(store.audio.playing && store.audio.paused,"A paused reading is active before the manual speaker change")
            try check(!store.selectReferenceVoice(id:"missing") && store.audio.playing && store.engines.referenceVoice == initial,"Unknown speaker identifiers preserve the current voice and playback")
            try check(!store.selectReferenceVoice(id:initial.id) && store.audio.playing && store.audio.paused,"Selecting the current speaker does not interrupt playback")
            try check(store.selectReferenceVoice(id:other.id) && !store.audio.playing && !store.audio.busy && !store.audio.paused && store.audio.currentText.isEmpty,"Changing speakers immediately stops playback and clears its state")
            try check(store.engines.referenceVoice == other && store.audio.referenceVoice == other && store.audio.voiceCatalogSignature == store.engines.voiceCatalog?.signature,"The selected speaker and catalog are synchronized for the next reading")
            try check(UserDefaults.standard.string(forKey:"lastReferenceVoiceID") == other.id,"Manual selection updates the most recently used speaker")
            store.audio.prepareForSpeech={try? await Task.sleep(for:.milliseconds(300))}
            store.audio.speak("This queued reading should never start after a speaker change.")
            try check(store.audio.busy && store.selectReferenceVoice(id:initial.id),"A speaker can change while speech waits for model cleanup")
            await settle(400)
            try check(!store.audio.busy && !store.audio.playing && store.audio.currentText.isEmpty && store.audio.referenceVoice == initial,"Cancelled speech cannot resume with the old or new speaker")
            store.audio.prepareForSpeech=prepare
            let next=EngineManager()
            try check(next.referenceVoice?.id != initial.id,"A new session avoids the last manually selected speaker")
            let selected=store.engines.referenceVoice
            store.engines.stop();await settle(200)
            try check(store.engines.referenceVoice == selected && store.audio.referenceVoice == selected,"Stopping an engine preserves the voice for the current app session")
            UserDefaults.standard.set("omnivoice",forKey:"speechProvider");store.route = .settings
            window.setContentSize(NSSize(width:1100,height:1000));await settle(400)
            try snapshot("settings-reference-voice")
        }

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
