import Foundation
import PaperCore

// Standalone assertions keep the checks runnable with Command Line Tools, without full Xcode/XCTest.
var failures=0
func fail(_ message:String,file:StaticString=#filePath,line:UInt=#line) {failures+=1;print("FAIL \(file):\(line): \(message)")}
func XCTAssertEqual<T:Equatable>(_ actual:@autoclosure () throws -> T,_ expected:T,file:StaticString=#filePath,line:UInt=#line) {
    do {let value=try actual();if value != expected {fail("\(value) != \(expected)",file:file,line:line)}} catch {fail(error.localizedDescription,file:file,line:line)}
}
func XCTAssertEqual(_ actual:Double,_ expected:Double,accuracy:Double,file:StaticString=#filePath,line:UInt=#line) {if abs(actual-expected)>accuracy {fail("\(actual) != \(expected)",file:file,line:line)}}
func XCTAssertTrue(_ actual:@autoclosure () throws -> Bool,file:StaticString=#filePath,line:UInt=#line) {do {if try !actual() {fail("Expected true",file:file,line:line)}}catch{fail(error.localizedDescription,file:file,line:line)}}

final class PaperCoreTests {
    func database() throws -> (Database,URL) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return (try Database(url:dir.appendingPathComponent("test.sqlite")),dir)
    }
    func testPDFNormalizationAndClassification() {
        XCTAssertEqual(TextTools.key("  General-\nization!  "),"generalization")
        XCTAssertEqual(TextTools.key("state-of-the-art"),"state-of-the-art")
        XCTAssertEqual(TextTools.kind("representation"),"单词")
        XCTAssertEqual(TextTools.kind("in contrast to"),"短语")
        XCTAssertEqual(TextTools.kind("The model converges quickly."),"句子")
        XCTAssertEqual(TextTools.context(in:"A robust model\n generalizes well. Another sentence.",selection:"robust"),"A robust model generalizes well.")
    }
    func testContextUsesActualOccurrenceAndBoundedWindow() {
        let prefix=String(repeating:"Earlier robust estimates. ",count:40000)
        let text=prefix+"🧠 The robust learner adapts quickly. Final sentence."
        let range=(text as NSString).range(of:"robust",options:.backwards)
        let start=Date()
        XCTAssertEqual(TextTools.context(in:text,range:range),"🧠 The robust learner adapts quickly.")
        print("Context in a \(text.utf8.count)-byte article: \(Date().timeIntervalSince(start))s")
        XCTAssertEqual(TextTools.context(in:text,range:NSRange(location:NSNotFound,length:2)),"")
        XCTAssertEqual(TextTools.context(in:text,range:NSRange(location:2,length:Int.max)),"")
        let emoji="First sentence. The 🧠 model learns."
        XCTAssertEqual(TextTools.context(in:emoji,range:(emoji as NSString).range(of:"🧠")),"The 🧠 model learns.")
    }
    func testBundledRuntimeRelocationAndWritableStore() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let resources=root.appendingPathComponent("Mac A/PaperLingo.app/Contents/Resources")
        let assets=resources.appendingPathComponent("Runtime")
        let fm=FileManager.default
        try fm.createDirectory(at:assets.appendingPathComponent("ollama-models/blobs"),withIntermediateDirectories:true)
        try fm.createDirectory(at:assets.appendingPathComponent("ollama-models/manifests/registry/library/model"),withIntermediateDirectories:true)
        try Data("weights".utf8).write(to:assets.appendingPathComponent("ollama-models/blobs/sha256-test"))
        try Data("manifest".utf8).write(to:assets.appendingPathComponent("ollama-models/manifests/registry/library/model/4b"))
        let support=root.appendingPathComponent("New User/Library/Application Support")
        let initial=RuntimePaths(configuration:["runtime":"bundled"],resources:resources,applicationSupport:support,environment:[:])
        XCTAssertEqual(initial.assets.path,assets.path)
        XCTAssertEqual(initial.modelURL("models/OmniVoice").path,assets.appendingPathComponent("models/OmniVoice").path)
        try initial.prepare()
        XCTAssertEqual(try Data(contentsOf:initial.ollamaModels.appendingPathComponent("blobs/sha256-test")),Data("weights".utf8))
        XCTAssertEqual(try Data(contentsOf:initial.ollamaModels.appendingPathComponent("manifests/registry/library/model/4b")),Data("manifest".utf8))
        let relocated=root.appendingPathComponent("Different Mac/PaperLingo.app/Contents/Resources")
        try fm.createDirectory(at:relocated.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.moveItem(at:resources,to:relocated)
        let moved=RuntimePaths(configuration:["runtime":"bundled"],resources:relocated,applicationSupport:support,environment:[:])
        try moved.prepare()
        XCTAssertEqual(moved.work.path,initial.work.path)
        XCTAssertEqual(try Data(contentsOf:moved.ollamaModels.appendingPathComponent("blobs/sha256-test")),Data("weights".utf8))
        let linked=try fm.destinationOfSymbolicLink(atPath:moved.ollamaModels.appendingPathComponent("blobs/sha256-test").path)
        XCTAssertEqual(URL(fileURLWithPath:linked).resolvingSymlinksInPath().path,moved.assets.appendingPathComponent("ollama-models/blobs/sha256-test").resolvingSymlinksInPath().path)
        XCTAssertTrue(!fm.fileExists(atPath:moved.assets.appendingPathComponent("logs").path))
    }
    func testDevelopmentRuntimePathsRemainCompatible() {
        let p=RuntimePaths(configuration:["runtime":"/development/.runtime"],resources:URL(fileURLWithPath:"/App/Resources"),applicationSupport:URL(fileURLWithPath:"/User/Library"),environment:[:])
        XCTAssertEqual(p.assets.path,"/development/.runtime")
        XCTAssertEqual(p.work,p.assets)
        XCTAssertEqual(p.modelURL("/old/snapshot").path,"/old/snapshot")
        let override=RuntimePaths(configuration:["runtime":"bundled"],resources:URL(fileURLWithPath:"/App/Resources"),applicationSupport:URL(fileURLWithPath:"/User/Library"),environment:["PAPERLINGO_RUNTIME_DIR":"/isolated/runtime","PAPERLINGO_ENGINE_WORK_DIR":"/isolated/work"])
        XCTAssertEqual(override.assets.path,"/isolated/runtime");XCTAssertEqual(override.work.path,"/isolated/work")
    }
    func testRepeatedLookupHasOneCardAndRealFrequency() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let paper=Paper(title:"Research",filename:"test.pdf",kind:"PDF")
        try db.addPaper(paper)
        let now=Date(timeIntervalSince1970:1700000000)
        try db.record(text:"Robust",translation:"稳健的",context:"A robust model.",paper:paper,page:2,now:now)
        try db.record(text:"robust",translation:"鲁棒的",context:"Robust estimation.",paper:paper,page:7,now:now.addingTimeInterval(30))
        let words=try db.vocabulary()
        XCTAssertEqual(words.count,1);XCTAssertEqual(words[0].lookups,2);XCTAssertEqual(words[0].lapses,0)
        XCTAssertEqual(words[0].page,7);XCTAssertEqual(words[0].context,"Robust estimation.")
        XCTAssertEqual(words[0].paperID,paper.id)
    }
    func testEmptyTranslationNeverCreatesCard() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        try db.record(text:"robust",translation:"  ",context:"",paper:nil,page:0)
        XCTAssertTrue(try db.vocabulary().isEmpty)
    }
    func testSentencePromoteDoesNotDoubleCount() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        try db.record(text:"A robust model.",translation:"稳健的模型。",context:"",paper:nil,page:0,save:false)
        XCTAssertTrue(try db.vocabulary().isEmpty)
        try db.promote(text:"A robust model.",translation:"稳健的模型。",context:"",paper:nil,page:0)
        try db.promote(text:"A robust model.",translation:"稳健的模型。",context:"",paper:nil,page:0)
        XCTAssertEqual(try db.vocabulary().count,1);XCTAssertEqual(try db.vocabulary()[0].lookups,1)
    }
    func testGradesAndDueQueue() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let now=Date(timeIntervalSince1970:1700000000)
        for word in ["robust","sparse","latent"] {try db.record(text:word,translation:"测试",context:"",paper:nil,page:0,now:now)}
        let initial=try db.vocabulary()
        try db.review(initial[0],grade:.again,mode:"listening",now:now)
        try db.review(initial[1],grade:.good,mode:"recognition",now:now)
        let words=try db.vocabulary()
        XCTAssertEqual(Scheduler.queue(words,at:now).count,1)
        XCTAssertEqual(Scheduler.queue(words,at:now.addingTimeInterval(601)).count,2)
        let failed=words.first{$0.id==initial[0].id}!
        XCTAssertEqual(failed.lapses,1);XCTAssertEqual(failed.stage,0)
        XCTAssertEqual(failed.due.timeIntervalSince(now),600,accuracy:0.1)
        XCTAssertEqual(Scheduler.queue(words,at:now.addingTimeInterval(601)).first?.id,failed.id)
    }
    func testKnownWordLookupBecomesDueAgain() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let now=Date(timeIntervalSince1970:1700000000)
        try db.record(text:"robust",translation:"稳健",context:"",paper:nil,page:0,now:now)
        let word=try db.vocabulary()[0]
        try db.review(word,grade:.easy,mode:"recognition",now:now)
        XCTAssertTrue(Scheduler.queue(try db.vocabulary(),at:now).isEmpty)
        try db.record(text:"robust",translation:"稳健",context:"",paper:nil,page:0,now:now.addingTimeInterval(60))
        XCTAssertEqual(Scheduler.queue(try db.vocabulary(),at:now.addingTimeInterval(60)).count,1)
    }
    func testPersistenceAndSourceRemovalPreservesWords() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        let paper=Paper(title:"Research",filename:"a.pdf",kind:"PDF")
        try db.addPaper(paper);try db.updatePage(paper.id,page:11)
        try db.record(text:"latent",translation:"潜在的",context:"Latent variables",paper:paper,page:11)
        let reopened=try Database(url:dir.appendingPathComponent("test.sqlite"))
        XCTAssertEqual(try reopened.papers()[0].page,11)
        XCTAssertEqual(try reopened.vocabulary()[0].text,"latent")
        try db.deletePaper(paper.id)
        XCTAssertEqual(try db.vocabulary()[0].paperTitle,"Research")
    }
    func testStageBoundsAndDailyCap() throws {
        let now=Date(timeIntervalSince1970:1700000000)
        XCTAssertEqual(Scheduler.next(stage:100,grade:.good,now:now).due.timeIntervalSince(now),60*86400)
        XCTAssertEqual(Scheduler.next(stage:-8,grade:.easy,now:now).stage,2)
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        for i in 0..<25 {try db.record(text:"word\(i)",translation:"词",context:"",paper:nil,page:0,now:now)}
        XCTAssertEqual(Scheduler.queue(try db.vocabulary(),at:now).count,20)
    }
    func testWebImportExtractsReadableArticle() {
        let html="<html><head><title>Research &amp; Reading</title></head><body><nav>Navigation</nav><article><h1>Model &amp; data</h1><p>A &quot;robust&quot; model &#8212; with context.</p><script>doNotInclude()</script><p>Next paragraph.</p></article><footer>Footer</footer></body></html>"
        let (title,body)=HTMLReader.extract(html)
        XCTAssertEqual(title,"Research & Reading")
        XCTAssertTrue(body.contains("A \"robust\" model — with context."))
        XCTAssertTrue(body.contains("Next paragraph."))
        XCTAssertTrue(!body.contains("Navigation") && !body.contains("doNotInclude") && !body.contains("Footer"))
    }
    func testLookupOfSavedSentenceIncrementsFrequency() throws {
        let (db,dir)=try database();defer{try? FileManager.default.removeItem(at:dir)}
        try db.promote(text:"A robust model.",translation:"稳健的模型。",context:"",paper:nil,page:0)
        try db.record(text:"A robust model.",translation:"稳健的模型。",context:"",paper:nil,page:0,save:false)
        XCTAssertEqual(try db.vocabulary()[0].lookups,2)
    }
}

let suite=PaperCoreTests()
let checks:[(String,() throws -> Void)] = [
    ("PDF normalization",suite.testPDFNormalizationAndClassification),
    ("Selection context locality and Unicode",suite.testContextUsesActualOccurrenceAndBoundedWindow),
    ("Bundled runtime relocation and writable metadata",suite.testBundledRuntimeRelocationAndWritableStore),
    ("Development runtime compatibility",suite.testDevelopmentRuntimePathsRemainCompatible),
    ("Lookup deduplication and frequency",suite.testRepeatedLookupHasOneCardAndRealFrequency),
    ("Empty translation rejection",suite.testEmptyTranslationNeverCreatesCard),
    ("Sentence promotion",suite.testSentencePromoteDoesNotDoubleCount),
    ("Grades and priority queue",suite.testGradesAndDueQueue),
    ("Known word lookup resets due time",suite.testKnownWordLookupBecomesDueAgain),
    ("Persistence and removed sources",suite.testPersistenceAndSourceRemovalPreservesWords),
    ("Stage bounds and daily cap",suite.testStageBoundsAndDailyCap),
    ("Web article extraction",suite.testWebImportExtractsReadableArticle),
    ("Saved sentence lookup frequency",suite.testLookupOfSavedSentenceIncrementsFrequency)
]
for (name,run) in checks {
    let before=failures
    do {try run()} catch {fail("\(name): \(error.localizedDescription)")}
    print("\(failures==before ? "PASS" : "FAIL") \(name)")
}
print("\(checks.count) checks, \(failures) failures")
if failures>0 {exit(1)}
