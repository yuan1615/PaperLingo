import AppKit
import Foundation
import PDFKit
import PaperCore
import UniformTypeIdentifiers

enum Route: String, CaseIterable { case reading = "阅读空间", library="研究库", vocabulary = "生词本", review = "今日练习", settings = "设置" }

@MainActor final class AppStore: ObservableObject {
    @Published var route: Route = .library
    @Published var papers: [Paper] = []
    @Published var words: [Vocabulary] = []
    @Published var selectedPaperID: String?
    @Published var selection = ""
    @Published var context = ""
    @Published var translation = ""
    @Published var selectedPage = 0
    @Published var translating = false
    @Published var importing = false
    @Published var error: String?
    @Published var toast: String?
    @Published var showLink = false
    @Published var reviewedToday = 0
    @Published var jumpPage: Int?
    @Published var queue: [Vocabulary] = []
    @Published var reviewIndex = 0
    @Published var revealed = false
    @Published var listening = false
    @Published var lookupSaved = false
    @Published var records:[String:PaperRecord]=[:]
    @Published var digests:[String:PaperDigest]=[:]
    @Published var researchNotes:[PaperNote]=[]
    @Published var textStatuses:[String:PaperTextStatus]=[:]
    @Published var ledgers:[String:ResearchLedger]=[:]
    @Published var experimentReviews:[String:ExperimentReview]=[:]
    @Published var catalogPaperID:String?
    @Published var noteEditor:PaperNote?
    @Published var metadataEditor:Paper?
    @Published var pendingPaperDeletion:Paper?
    @Published var researchBusy=false
    @Published var researchPaperID:String?
    @Published var researchMessage=""
    @Published var researchProgress=0.0
    @Published var researchError:String?
    @Published var extractingLibrary=false
    @Published var libraryQuery=""
    @Published var searchHits:[ResearchSearchHit]=[]
    @Published var searching=false
    @Published var searchMessage=""
    @Published var libraryStatusFilter="全部状态"
    @Published var libraryCategoryFilter="全部分类"
    @Published var libraryTagFilter="全部标签"
    @Published var libraryFavoritesOnly=false
    @Published var librarySort="最近加入"
    var researchTask:Task<Void,Never>?
    var textIndexTask:Task<Void,Never>?
    var searchTask:Task<Void,Never>?
    var semanticSearchQuery:String?
    var hasUnsavedResearchEdits=false
    var shuttingDown=false
    var allowEngineRestore=true
    let researchClient=ResearchClient()
    let dataURL: URL
    var db: Database?
    private var selectionVersion = UUID()
    private var translatedPaper: Paper?
    private var translatedPage = 0
    private var translatedContext = ""
    private var translatedText = ""
    let engines = EngineManager()
    let audio = AudioService()
    let layout = ReaderLayout()
    let reminders = Reminders()
    var selectedPaper: Paper? { papers.first { $0.id == selectedPaperID } }
    var dueWords: [Vocabulary] { Scheduler.queue(words, limit: Int.max) }
    var currentCard: Vocabulary? { queue.indices.contains(reviewIndex) ? queue[reviewIndex] : nil }
    init() {
        let env = ProcessInfo.processInfo.environment["PAPERLINGO_DATA_DIR"]
        let configURL=Bundle.main.url(forResource:"runtime",withExtension:"json")
        let config=configURL.flatMap{try? Data(contentsOf:$0)}.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:String]}
        let directory=env ?? config?["data"]
        dataURL = directory.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperLingo")
        do {
            try FileManager.default.createDirectory(at: dataURL.appendingPathComponent("Papers"), withIntermediateDirectories: true)
            db = try Database(url: dataURL.appendingPathComponent("library.sqlite"))
            try reload()
            selectedPaperID = UserDefaults.standard.string(forKey: "lastPaperID") ?? papers.first?.id
            if selectedPaper == nil { selectedPaperID = papers.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    func reload() throws {
        guard let db else { throw AppError.message("数据库未打开，请检查数据目录权限。") }
        papers=try db.papers();words=try db.vocabulary();reviewedToday=try db.reviewsToday()
        records=try db.paperRecords();digests=try db.latestDigests();researchNotes=try db.allNotes();textStatuses=try db.textStatuses()
        ledgers=try db.ledgers();experimentReviews=try db.experimentReviews()
    }
    func open(_ paper: Paper, page: Int? = nil) {
        audio.stop(); selectedPaperID=paper.id; route = .reading; clearSelection()
        jumpPage=page ?? paper.page; selectedPage=page ?? paper.page
        UserDefaults.standard.set(paper.id, forKey: "lastPaperID")
        do {try db?.markPaperOpened(paper.id);records[paper.id]=try db?.paperRecord(paper.id)} catch {self.error=error.localizedDescription}
    }
    func fileURL(_ paper: Paper) -> URL { dataURL.appendingPathComponent("Papers").appendingPathComponent(paper.filename) }
    func choosePDF() {
        let panel = NSOpenPanel(); panel.allowedContentTypes=[.pdf]; panel.allowsMultipleSelection=true
        panel.begin { response in
            if response == .OK { Task { @MainActor in for url in panel.urls { self.importPDF(url) } } }
        }
    }
    @discardableResult func importPDF(_ url: URL, source: String = "") -> Bool {
        do {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw AppError.message("无法读取此 PDF，文件可能已损坏或需要密码。") }
            let id=UUID().uuidString, filename="\(id).pdf"
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback=URL(string:source)?.deletingPathExtension().lastPathComponent
            let p = Paper(id: id, title: title?.isEmpty == false ? title! : (fallback?.isEmpty == false ? fallback! : url.deletingPathExtension().lastPathComponent), filename: filename, kind: "PDF", source: source)
            let target = fileURL(p)
            try FileManager.default.copyItem(at: url, to: target)
            do { try db?.addPaper(p) } catch { try? FileManager.default.removeItem(at: target); throw error }
            try reload(); open(p)
            if TextTools.clean(document.string ?? "").isEmpty { toast="此 PDF 没有文字层，需要先 OCR 才能选词。" }
            return true
        } catch { self.error=error.localizedDescription; return false }
    }
    func importLink(_ input: String) async {
        guard !importing else { return }
        error=nil
        importing=true; defer { importing=false }
        do {
            guard var url=URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AppError.message("请输入完整的 http 或 https 网页链接。") }
            if ["arxiv.org","www.arxiv.org"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/abs/") {
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!; c.path=url.path.replacingOccurrences(of: "/abs/", with: "/pdf/"); c.query=nil; c.fragment=nil; url=c.url!
            }
            var request=URLRequest(url:url); request.timeoutInterval=60; request.setValue("PaperLingo/1.0 (personal research reader)", forHTTPHeaderField:"User-Agent")
            let (temporary,response)=try await URLSession.shared.download(for:request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http=response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AppError.message("网页暂时无法访问。可以用浏览器保存为 PDF 后导入。") }
            let size = try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size < 100_000_000 else { throw AppError.message("文件超过 100 MB，请下载后作为本地 PDF 导入。") }
            let data=try Data(contentsOf:temporary)
            if data.prefix(4) == Data("%PDF".utf8) { if importPDF(temporary,source:input) { showLink=false }; return }
            guard ["text/html","application/xhtml+xml","text/plain"].contains(response.mimeType?.lowercased() ?? "") else {throw AppError.message("这个链接返回的内容不是 PDF 或 HTML 网页，请检查链接。")}
            guard size < 8_000_000, let html=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else { throw AppError.message("链接没有返回可阅读的 PDF 或网页正文。") }
            let (title,body)=HTMLReader.extract(html)
            guard body.count > 80 else { throw AppError.message("网页正文太少，可能依赖登录或动态加载。请在浏览器打印为 PDF 后导入。") }
            let id=UUID().uuidString
            let p=Paper(id:id,title:title.isEmpty ? url.host! : title,filename:"\(id).txt",kind:"WEB",source:input)
            try body.write(to:fileURL(p),atomically:true,encoding:.utf8)
            do { try db?.addPaper(p) } catch { try? FileManager.default.removeItem(at:fileURL(p)); throw error }
            try reload(); open(p); showLink=false
        } catch { self.error=error.localizedDescription }
    }
    func updateSelection(_ text: String, context: String, page: Int) {
        let cleaned=TextTools.clean(text)
        guard !cleaned.isEmpty, cleaned != selection || page != selectedPage else { return }
        selectionVersion=UUID(); selection=cleaned; self.context=context; selectedPage=page; translation=""; lookupSaved=false
    }
    func clearSelection() { selectionVersion=UUID(); selection=""; context=""; translation=""; lookupSaved=false }
    func translate() async {
        guard !translating, !selection.isEmpty else { return }
        guard !researchBusy else {toast="本地大模型正在整理论文；完成或取消后即可翻译。阅读、笔记和关键词检索仍可使用。";return}
        guard selection.count<=4000 else { error="一次最多翻译 4000 字符，请选取一个单词、短语或段落。"; return }
        translating=true; defer { translating=false }
        let text=selection, token=selectionVersion, paper=selectedPaper, page=selectedPage, surrounding=context
        do {
            let model=UserDefaults.standard.string(forKey:"translationModel") ?? "translategemma:4b"
            let result=try await LocalAPI.translate(text,model:model)
            let save=TextTools.kind(text) != "句子"
            try db?.record(text:text,translation:result,context:surrounding,paper:paper,page:page,save:save)
            try reload(); Task { await reminders.schedule(words) }
            if selectionVersion == token {
                translation=result; lookupSaved=save; translatedText=text; translatedContext=surrounding; translatedPaper=paper; translatedPage=page
            }
        } catch { self.error="翻译失败：\(error.localizedDescription) 请在设置中检查 TranslateGemma 是否就绪。" }
    }
    func saveSentence() {
        guard !translation.isEmpty, !lookupSaved, translatedText==selection else { return }
        do { try db?.promote(text:translatedText,translation:translation,context:translatedContext,paper:translatedPaper,page:translatedPage); try reload(); lookupSaved=true; Task { await reminders.schedule(words) } }
        catch { self.error=error.localizedDescription }
    }
    func savePage(_ page: Int, for id: String) {
        guard let index=papers.firstIndex(where:{$0.id==id}), papers[index].page != page else { return }
        do { try db?.updatePage(id,page:page); papers[index].page=page } catch { self.error=error.localizedDescription }
    }
    func deletePaper(_ p: Paper) {
        guard researchPaperID != p.id else {error="请先取消这篇论文的整理任务，再移除论文。";return}
        do { try db?.deletePaper(p.id); try reload(); try? FileManager.default.removeItem(at:fileURL(p)); if selectedPaperID==p.id { selectedPaperID=papers.first?.id; clearSelection() };if catalogPaperID==p.id {catalogPaperID=nil};searchHits.removeAll{$0.paperID==p.id} }
        catch { self.error=error.localizedDescription }
    }
    func deleteWord(_ word: Vocabulary) {
        do { try db?.deleteWord(word.id); try reload(); Task { await reminders.schedule(words) } } catch { self.error=error.localizedDescription }
    }
    func beginReview(listening: Bool) {
        audio.stop(); self.listening=listening; queue=Scheduler.queue(words); reviewIndex=0; revealed=false
    }
    func grade(_ grade: Grade) {
        guard revealed, let word=currentCard else { return }
        do { try db?.review(word,grade:grade,mode:listening ? "listening" : "recognition"); try reload(); audio.stop(); reviewIndex+=1; revealed=false; Task { await reminders.schedule(words) } }
        catch { self.error=error.localizedDescription }
    }
    func exportBackup() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.json]; panel.nameFieldStringValue="PaperLingo-backup.json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            struct Backup: Codable {
                var version=3;var exported=Date()
                var papers:[Paper];var vocabulary:[Vocabulary]
                var records:[PaperRecord];var notes:[PaperNote];var digests:[PaperDigest]
                var ledgers:[ResearchLedger];var experimentReviews:[ExperimentReview]
            }
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Backup(papers:papers,vocabulary:words,records:papers.map{record(for:$0)},notes:researchNotes,digests:Array(digests.values),ledgers:Array(ledgers.values),experimentReviews:Array(experimentReviews.values))).write(to:url,options:.atomic)
            toast="词库、论文档案和笔记已导出。PDF 与完整日志仍需备份数据目录。"
        } catch { self.error=error.localizedDescription }
    }
    func loadExample() {
        do {
            let text="""
            Reading research, one idea at a time

            A practice passage · PaperLingo

            This short passage is a built-in reading exercise, not a published paper.

            Understanding a research paper requires more than recognizing individual words. Readers need to connect unfamiliar terminology with the surrounding context and gradually build a mental model of the argument.

            A robust representation should generalize beyond the training distribution. In practice, however, a model may rely on spurious correlations rather than learning the underlying structure of the problem.

            To evaluate this hypothesis, we compare several baselines under controlled conditions. The results suggest that incorporating prior knowledge can improve sample efficiency, particularly when labeled data are scarce.

            Reading with intention

            Select “spurious correlations” and click 翻译 in the learning panel. Try listening to the whole sentence, then add it to your review queue. When you encounter the same expression again, its lookup frequency will increase automatically.

            Learning is an iterative process. Repeated retrieval, spaced over time, helps turn unfamiliar expressions into knowledge that can be used with confidence.
            """
            if let existing=papers.first(where:{$0.source=="paperlingo://practice"}) { open(existing); return }
            let p=Paper(title:"Reading research, one idea at a time",filename:"practice.txt",kind:"WEB",source:"paperlingo://practice")
            try text.write(to:fileURL(p),atomically:true,encoding:.utf8); try db?.addPaper(p); try reload(); open(p)
        } catch { self.error=error.localizedDescription }
    }
}
