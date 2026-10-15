import AppKit
import PaperCore
import SwiftUI
import UniformTypeIdentifiers

enum Palette {
    static let ink=Color(red:0.14,green:0.22,blue:0.19)
    static let green=Color(red:0.21,green:0.39,blue:0.31)
    static let muted=Color(red:0.49,green:0.54,blue:0.50)
    static let cream=Color(red:0.98,green:0.975,blue:0.955)
    static let line=Color(red:0.88,green:0.90,blue:0.87)
    static let pale=Color(red:0.92,green:0.95,blue:0.91)
    static let orange=Color(red:0.76,green:0.43,blue:0.25)
}

struct PrimaryButton:ButtonStyle {
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.semibold)).foregroundStyle(.white).padding(.horizontal,17).padding(.vertical,11)
            .background(Palette.green.opacity(configuration.isPressed ? 0.8 : 1),in:RoundedRectangle(cornerRadius:9)).contentShape(Rectangle())
    }
}

struct RootView:View {
    @ObservedObject var store:AppStore
    @ObservedObject var layout:ReaderLayout
    init(store:AppStore) { self.store=store; self.layout=store.layout }
    var body:some View {
        GeometryReader { geometry in
        let sidebarWidth = min(222.0,max(184.0,geometry.size.width * 0.17))
        let sidebarShown = layout.sidebarVisible && !(layout.focused && store.route == .reading)
        HStack(spacing:0) {
            Sidebar(store:store).frame(width:sidebarWidth).frame(width:sidebarShown ? sidebarWidth : 0).clipped().allowsHitTesting(sidebarShown).accessibilityHidden(!sidebarShown)
            Rectangle().fill(Palette.line).frame(width:sidebarShown ? 1 : 0)
            VStack(spacing:0) {
                HStack {
                    Button {layout.sidebarVisible.toggle()} label:{Image(systemName:"sidebar.left")}.buttonStyle(ReadingButtonStyle()).help("显示或收起论文库 ⌥⌘S")
                    HStack(spacing:8) { Circle().fill(Palette.green).frame(width:6,height:6); Text("YOUR RESEARCH, YOUR ENGLISH").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(1.3).foregroundStyle(Palette.muted) }
                    Spacer()
                    Text(Date(),format:.dateTime.month(.wide).day().weekday(.wide)).font(.system(size:11)).foregroundStyle(Palette.muted)
                    Text("LOCAL FIRST").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(Palette.green).padding(.horizontal,9).padding(.vertical,5).background(Palette.pale,in:Capsule())
                }.padding(.horizontal,20).frame(height:54).frame(height:store.route == .reading && store.selectedPaper != nil ? 0 : 54).clipped().allowsHitTesting(!(store.route == .reading && store.selectedPaper != nil)).accessibilityHidden(store.route == .reading && store.selectedPaper != nil)
                Rectangle().fill(Palette.line).frame(height:store.route == .reading && store.selectedPaper != nil ? 0 : 1)
                Group {
                    switch store.route {
                    case .reading: ReadingSpace(store:store)
                    case .library: ResearchLibraryScreen(store:store)
                    case .vocabulary: VocabularyScreen(store:store)
                    case .review: ReviewScreen(store:store)
                    case .settings: SettingsScreen(store:store,engines:store.engines)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.background(Palette.cream)
        }
        }
        .overlay(alignment:.bottomTrailing) {
            if store.researchBusy && store.route != .library {ResearchCompactStatus(store:store,audio:store.audio).padding(18)}
            else {AudioBar(audio:store.audio).padding(18)}
        }
        .onExitCommand { if layout.focused {layout.focused=false} }
        .foregroundStyle(Palette.ink).tint(Palette.green)
        .sheet(isPresented:$store.showLink) { LinkImport(store:store) }
        .sheet(item:$store.noteEditor) {note in ResearchNoteEditor(store:store,note:note)}
        .sheet(item:$store.metadataEditor) {paper in ResearchMetadataEditor(store:store,paper:paper)}
        .confirmationDialog("移除论文和该论文的个人笔记？",isPresented:Binding(get:{store.pendingPaperDeletion != nil},set:{if !$0{store.pendingPaperDeletion=nil}}),titleVisibility:.visible) {
            Button("移除论文、档案与笔记",role:.destructive) {if let paper=store.pendingPaperDeletion{store.deletePaper(paper)};store.pendingPaperDeletion=nil}
            Button("取消",role:.cancel){store.pendingPaperDeletion=nil}
        } message:{Text("本机论文副本、个人笔记、AI 汇总和检索索引会被移除。已积累的英语词条保留。可先导出 Markdown 保存笔记。")}
        .alert("需要留意",isPresented:Binding(get:{store.error != nil && !store.showLink},set:{if !$0 {store.error=nil}})) {
            Button("知道了",role:.cancel) { store.error=nil }
        } message:{ Text(store.error ?? "") }
        .overlay(alignment:.bottom) {
            if let toast=store.toast { Button { store.toast=nil } label:{ Text(toast).font(.system(size:12)).padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).shadow(color:.black.opacity(0.08),radius:12) }.buttonStyle(ReadingButtonStyle()).padding(.bottom,20) }
        }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in
            for provider in providers {
                _=provider.loadObject(ofClass:URL.self) { url,_ in if let url,url.pathExtension.lowercased()=="pdf" { Task { @MainActor in store.importPDF(url) } } }
            }
            return true
        }
    }
}

struct Sidebar:View {
    @ObservedObject var store:AppStore
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"book.closed.fill").font(.system(size:22)).foregroundStyle(Palette.green)
                VStack(alignment:.leading,spacing:2) { Text("PaperLingo").font(.system(size:20,weight:.semibold,design:.serif)).lineLimit(1).minimumScaleFactor(0.75); Text("在阅读中，把英文变成自己的").font(.system(size:9)).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.8) }
            }.padding(.top,42).padding(.bottom,35).padding(.horizontal,22)
            VStack(spacing:7) {
                nav(.reading,icon:"doc.text.magnifyingglass",count:nil)
                nav(.library,icon:"books.vertical",count:store.papers.count)
                nav(.vocabulary,icon:"square.stack",count:store.words.count)
                nav(.review,icon:"sun.max",count:store.dueWords.count)
            }.padding(.horizontal,13)
            HStack { Text("我的论文").font(.system(size:10,weight:.semibold)).foregroundStyle(Palette.muted); Spacer(); Button { store.choosePDF() } label:{ Image(systemName:"plus").font(.system(size:13)) }.buttonStyle(ReadingButtonStyle()).help("导入 PDF ⌘O") }.padding(.horizontal,23).padding(.top,35).padding(.bottom,12)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:3) {
                    ForEach(store.papers) { paper in
                        Button { store.open(paper) } label:{
                            HStack(alignment:.top,spacing:9) {
                                Image(systemName:paper.kind=="PDF" ? "doc.richtext" : "globe").font(.system(size:13)).padding(.top,2)
                                VStack(alignment:.leading,spacing:5) { Text(paper.title).font(.system(size:11,weight:.medium)).lineLimit(2).multilineTextAlignment(.leading); Text(paper.kind=="PDF" ? "PDF · 第 \(paper.page+1) 页" : "网页 · 本地快照").font(.system(size:9)).foregroundStyle(Palette.muted) }
                                Spacer(minLength:0)
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(store.selectedPaperID==paper.id && store.route == .reading ? Palette.pale : .clear,in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                        }.buttonStyle(ReadingButtonStyle()).contextMenu {
                            Button("打开") { store.open(paper) }
                            Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(paper)]) }
                            Button("论文档案与笔记") {store.showArchive(paper)}
                            Button("移除论文…",role:.destructive) { store.pendingPaperDeletion=paper }
                        }
                    }
                    if store.papers.isEmpty { Text("导入你的第一篇论文，\n从一个陌生的词开始。").font(.system(size:11)).foregroundStyle(Palette.muted).lineSpacing(5).padding(.horizontal,10).padding(.top,3) }
                }.padding(.horizontal,13)
            }
            Spacer(minLength:16)
            VStack(alignment:.leading,spacing:9) {
                HStack { Image(systemName:"sparkle"); Text("每天，前进一步").fontWeight(.medium) }.font(.system(size:11))
                Text("从真实阅读中积累，\n用 10 分钟让表达留下来。").font(.system(size:10)).foregroundStyle(Palette.muted).lineSpacing(4)
                HStack { Text("今日已练习"); Spacer(); Text("\(store.reviewedToday)").fontWeight(.semibold) }.font(.system(size:10)).padding(.top,4)
            }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(Palette.pale.opacity(0.7),in:RoundedRectangle(cornerRadius:12)).padding(.horizontal,17).padding(.bottom,19)
            nav(.settings,icon:"slider.horizontal.3",count:nil).padding(.horizontal,13).padding(.bottom,18)
        }.background(Color(red:0.96,green:0.965,blue:0.95))
    }
    func nav(_ route:Route,icon:String,count:Int?) -> some View {
        Button {
            store.route=route
            if route == .review { store.beginReview(listening:false) }
        } label:{
            HStack(spacing:12) { Image(systemName:icon).font(.system(size:16)).frame(width:21); Text(route.rawValue).font(.system(size:13,weight:store.route==route ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85); Spacer(); if let count { Text("\(count)").font(.system(size:10,weight:.medium,design:.monospaced)).padding(.horizontal,7).padding(.vertical,3).background(.white.opacity(0.65),in:Capsule()) } }
                .padding(.horizontal,13).frame(height:42).background(store.route==route ? Palette.green.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:9)).contentShape(Rectangle())
        }.buttonStyle(ReadingButtonStyle()).foregroundStyle(store.route==route ? Palette.green : Palette.ink.opacity(0.8))
    }
}

struct ReadingSpace:View {
    @ObservedObject var store:AppStore
    @ObservedObject var layout:ReaderLayout
    init(store:AppStore) { self.store=store; self.layout=store.layout }
    var body:some View {
        if let paper=store.selectedPaper {
            GeometryReader { geometry in
                let shown = layout.assistantVisible && !layout.focused
                let width = min(288.0,max(240.0,geometry.size.width * 0.27))
                HStack(spacing:0) {
                    DocumentPanel(store:store,paper:paper).frame(maxWidth:.infinity,maxHeight:.infinity)
                    Rectangle().fill(Palette.line).frame(width:shown ? 1 : 0)
                    LearningPanel(store:store).frame(width:width).frame(width:shown ? width : 0).clipped().allowsHitTesting(shown).accessibilityHidden(!shown)
                }
            }
        } else { WelcomeScreen(store:store) }
    }
}

struct WelcomeScreen:View {
    @ObservedObject var store:AppStore
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:0) {
                Text("A LITTLE READING. A LITTLE GROWTH.").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(2).foregroundStyle(Palette.orange).padding(.bottom,24)
                Text("读懂下一篇论文，\n也更靠近流利的自己。").font(.system(size:38,weight:.medium,design:.serif)).lineSpacing(9).padding(.bottom,20)
                Text("让陌生的单词，成为熟悉的表达。\n在这里阅读、听见、理解，再用每天 10 分钟记住。").font(.system(size:14)).foregroundStyle(Palette.muted).lineSpacing(8).padding(.bottom,35)
                HStack(spacing:12) {
                    Button { store.choosePDF() } label:{ Label("导入一篇 PDF",systemImage:"plus") }.buttonStyle(PrimaryButton())
                    Button { store.showLink=true } label:{ Label("粘贴论文链接",systemImage:"link") }.buttonStyle(.bordered).controlSize(.large)
                }.padding(.bottom,44)
                HStack(alignment:.top,spacing:16) {
                    feature("01","自由阅读","保留论文原版式，\n选一个词，也可以选一整句。","text.cursor")
                    feature("02","即时理解","本地翻译与自然发音，\n让上下文帮助你理解。","waveform")
                    feature("03","让记忆发生","反复查阅的表达，\n会出现在下一次复习中。","sun.horizon")
                }.padding(.bottom,36)
                HStack { Image(systemName:"leaf").foregroundStyle(Palette.green); Text("论文、词库和学习记录保存在你的 Mac。").font(.system(size:11)).foregroundStyle(Palette.muted); Spacer(); Button("先试读一段 →") { store.loadExample() }.buttonStyle(ReadingButtonStyle()).font(.system(size:12,weight:.medium)).foregroundStyle(Palette.green) }
                Divider().padding(.vertical,25)
                HStack(spacing:8) { Image(systemName:"cpu"); Text(store.engines.bundled ? "本离线版已包含模型，可到「设置」查看引擎连接状态。" : "首次使用：到「设置」安装并启动本地模型，随后可离线翻译与朗读。").font(.system(size:11)) }.foregroundStyle(Palette.muted)
            }.frame(maxWidth:850,alignment:.leading).padding(60).frame(maxWidth:.infinity,alignment:.center)
        }
    }
    func feature(_ number:String,_ title:String,_ detail:String,_ icon:String) -> some View {
        VStack(alignment:.leading,spacing:17) {
            HStack { Image(systemName:icon).font(.system(size:22)); Spacer(); Text(number).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted) }.foregroundStyle(Palette.green)
            Text(title).font(.system(size:15,weight:.semibold))
            Text(detail).font(.system(size:11)).foregroundStyle(Palette.muted).lineSpacing(6)
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading).frame(height:158).background(.white.opacity(0.65),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(Palette.line,lineWidth:1))
    }
}

struct DocumentPanel:View {
    @ObservedObject var store:AppStore
    @ObservedObject var layout:ReaderLayout
    let paper:Paper
    @State private var zoom=0
    @State private var fontSize:CGFloat=19
    @State private var search=""
    @State private var text=""
    @State private var controlsVisible=true
    @State private var hovering=false
    @State private var hideTask:Task<Void,Never>?
    init(store:AppStore,paper:Paper) {self.store=store;self.layout=store.layout;self.paper=paper}
    var body:some View {
        VStack(spacing:0) {
            VStack(spacing:0) {
                HStack(spacing:12) {
                    Text(paper.title).font(.system(size:17,weight:.medium,design:.serif)).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength:0)
                    Button {store.showArchive(paper)} label:{Image(systemName:"books.vertical")}.buttonStyle(ReadingButtonStyle()).help("论文档案与个人笔记")
                    Button {store.newNote(paper,fromSelection:!store.selection.isEmpty)} label:{Image(systemName:"square.and.pencil")}.buttonStyle(ReadingButtonStyle()).help("记录想法；当前选区会附入笔记")
                    Menu { Button("导入 PDF…") {store.choosePDF()}; Button("导入链接…") {store.showLink=true}; Button("在 Finder 中显示") {NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(paper)])} } label:{Image(systemName:"ellipsis").frame(width:32,height:32).contentShape(Rectangle())}.menuStyle(.borderlessButton).frame(width:32)
                }.padding(.horizontal,20).frame(height:50)
                controls
                Rectangle().fill(Palette.line).frame(height:1)
            }.frame(height:layout.focused ? 0 : 99,alignment:.top).clipped().allowsHitTesting(!layout.focused).accessibilityHidden(layout.focused)
            Group {
                if paper.kind=="PDF" { PDFReader(url:store.fileURL(paper),paper:paper,store:store,zoomCommand:zoom,search:search).id(paper.id) }
                else { TextReader(text:text,store:store,fontSize:fontSize,search:search).id(paper.id).background(Color.white.opacity(0.4)) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .overlay(alignment:.top) {
                    if layout.focused {
                        VStack(spacing:0) {
                            if controlsVisible {
                                controls.frame(maxWidth:660).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).shadow(color:.black.opacity(0.10),radius:10,y:3)
                            } else {
                                Button {revealControls()} label:{Image(systemName:"ellipsis").font(.system(size:14,weight:.semibold)).frame(width:64,height:18)}
                                    .buttonStyle(ReadingButtonStyle()).background(.regularMaterial,in:Capsule()).help("显示阅读工具栏 · Esc 退出专注")
                            }
                        }.padding(.top,8).padding(.horizontal,12)
                            .onHover {inside in hovering=inside;if inside {revealControls()} else {scheduleHide()} }
                    }
                }
        }
        .onAppear {if layout.focused {revealControls()}}
        .onChange(of:layout.focused) { _,focused in if focused {revealControls()} else {hideTask?.cancel()} }
        .onDisappear {hideTask?.cancel()}
        .task(id:paper.id) {
            if paper.kind != "PDF" {
                let url=store.fileURL(paper)
                do {text=try await Task.detached(priority:.userInitiated) {try String(contentsOf:url,encoding:.utf8)}.value}
                catch {store.error=error.localizedDescription}
            }
        }
    }
    private var controls:some View {
        HStack(spacing:4) {
            Button {if layout.focused {layout.sidebarVisible=true;layout.focused=false} else {layout.sidebarVisible.toggle()}} label:{Image(systemName:"sidebar.left")}.help("显示或收起论文库 ⌥⌘S")
            Text(paper.kind=="PDF" ? "第 \(paper.page+1) 页" : "正文").font(.system(size:10)).foregroundStyle(Palette.muted).fixedSize()
            Spacer(minLength:4)
            TextField("查找正文",text:$search).textFieldStyle(.roundedBorder).font(.system(size:11)).frame(minWidth:60,maxWidth:150).help("在当前论文中查找")
            Button {if paper.kind=="PDF" {zoom-=1} else {fontSize=max(14,fontSize-1)}} label:{Image(systemName:"textformat.size.smaller")}.help("缩小正文")
            Button {if paper.kind=="PDF" {zoom+=1} else {fontSize=min(30,fontSize+1)}} label:{Image(systemName:"textformat.size.larger")}.help("放大正文")
            Button {layout.focused.toggle()} label:{
                ViewThatFits(in:.horizontal) {
                    Label(layout.focused ? "退出专注" : "专注",systemImage:layout.focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").fixedSize()
                    Image(systemName:layout.focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }.help("专注阅读 ⇧⌘F · Esc 退出")
            Button {if layout.focused {layout.assistantVisible=true;layout.focused=false} else {layout.assistantVisible.toggle()}} label:{Image(systemName:"sidebar.right")}.help("显示或收起学习助手 ⌥⌘I")
        }.font(.system(size:12)).buttonStyle(ReadingButtonStyle()).padding(.horizontal,12).frame(height:48)
    }
    private func revealControls() {controlsVisible=true;scheduleHide()}
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask=Task {try? await Task.sleep(for:.seconds(2));guard !Task.isCancelled,!hovering else {return};controlsVisible=false}
    }
}

struct LearningPanel:View {
    @ObservedObject var store:AppStore
    @State private var expandedSelection=false
    @State private var manualText=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                HStack { Text("学习助手").font(.system(size:14,weight:.semibold)); Spacer(); Button {store.layout.assistantVisible=false} label:{Image(systemName:"sidebar.right")}.buttonStyle(ReadingButtonStyle()).help("收起学习助手") }.padding(.top,5)
                Text("A MOMENT TO UNDERSTAND").font(.system(size:8,weight:.medium,design:.monospaced)).tracking(1.1).foregroundStyle(Palette.muted)
                if store.selection.isEmpty {
                    VStack(alignment:.leading,spacing:16) {
                        Image(systemName:"character.cursor.ibeam").font(.system(size:31,weight:.light)).foregroundStyle(Palette.green).padding(.top,12)
                        Text("从一个好奇的词开始").font(.system(size:18,weight:.medium,design:.serif))
                        Text("在论文中划选一个词、短语或句子。译文、发音和上下文会出现在这里。").font(.system(size:12)).foregroundStyle(Palette.muted).lineSpacing(7)
                    }.padding(.bottom,5)
                    TextField("输入英文，按回车确认",text:$manualText).textFieldStyle(.roundedBorder).font(.system(size:12))
                        .onSubmit {store.updateSelection(manualText,context:"",page:0);manualText=""}
                } else {
                    VStack(alignment:.leading,spacing:12) {
                        HStack { Text(TextTools.kind(store.selection)).font(.system(size:9,weight:.medium)).foregroundStyle(Palette.green).padding(.horizontal,8).padding(.vertical,4).background(Palette.pale,in:Capsule()); Spacer(); Button {store.clearSelection()} label:{Image(systemName:"xmark").font(.system(size:10))}.buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.muted) }
                        Text(store.selection).font(.system(size:store.selection.count > 120 ? 16 : 22,weight:.medium,design:.serif)).textSelection(.enabled).lineSpacing(5).lineLimit(expandedSelection ? nil : 8).fixedSize(horizontal:false,vertical:true)
                        if store.selection.count > 160 {Button(expandedSelection ? "收起选区" : "展开完整选区") {expandedSelection.toggle()}.buttonStyle(ReadingButtonStyle()).font(.system(size:10)).foregroundStyle(Palette.green)}
                        HStack(spacing:14) {
                            Button {store.audio.speak(store.selection)} label:{Label("发音",systemImage:"speaker.wave.2")}
                            Button {store.audio.speak(store.selection,slow:true)} label:{Label("慢速",systemImage:"tortoise")}
                        }.font(.system(size:11)).buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.green)
                    }
                    Button {Task {await store.translate()}} label:{
                        HStack { if store.translating {ProgressView().controlSize(.small).tint(.white)} else {Image(systemName:"character.bubble")} ; Text(store.translating ? "正在本地翻译…" : "翻译选区"); Spacer(); Text("⌘D").font(.system(size:10)) }
                    }.buttonStyle(PrimaryButton()).disabled(store.translating)
                    if !store.translation.isEmpty {
                        VStack(alignment:.leading,spacing:13) {
                            Text("中文释义").font(.system(size:10,weight:.medium)).foregroundStyle(Palette.muted)
                            Text(store.translation).font(.system(size:15)).textSelection(.enabled).lineSpacing(7).fixedSize(horizontal:false,vertical:true)
                            if store.lookupSaved { Label("已加入个人词库",systemImage:"checkmark.circle.fill").font(.system(size:10)).foregroundStyle(Palette.green) }
                            else {Button {store.saveSentence()} label:{Label("加入复习",systemImage:"plus.circle")}.buttonStyle(.bordered).font(.system(size:11))}
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Palette.pale.opacity(0.65),in:RoundedRectangle(cornerRadius:11))
                    }
                    if !store.context.isEmpty && store.context != store.selection {
                        VStack(alignment:.leading,spacing:12) {
                            HStack {Text("回到上下文").font(.system(size:10,weight:.medium)).foregroundStyle(Palette.muted);Spacer();Button("译原句"){let sentence=store.context;store.updateSelection(sentence,context:sentence,page:store.selectedPage);Task{await store.translate()}}.buttonStyle(ReadingButtonStyle()).font(.system(size:10)).foregroundStyle(Palette.green).disabled(store.translating);Button {store.audio.speak(store.context)} label:{Image(systemName:"speaker.wave.2")}.buttonStyle(ReadingButtonStyle()).help("朗读原句")}
                            Text(store.context).font(.system(size:12,design:.serif)).foregroundStyle(Palette.ink.opacity(0.8)).textSelection(.enabled).lineSpacing(7)
                        }
                    }
                }
                Divider()
                VStack(alignment:.leading,spacing:10) {
                    Label("让不熟悉的表达，慢慢熟悉",systemImage:"leaf").font(.system(size:11,weight:.medium))
                    Text("成功查阅的单词和短语会自动积累。查得越多、越容易忘，复习优先级越高。").font(.system(size:10)).foregroundStyle(Palette.muted).lineSpacing(6)
                    Button {store.route = .review;store.beginReview(listening:false)} label:{HStack {Text("今日待复习");Spacer();Text("\(store.dueWords.count) 项 →")}}.buttonStyle(ReadingButtonStyle()).font(.system(size:11)).foregroundStyle(Palette.green).padding(.top,5)
                }
            }.padding(23)
        }.background(Color.white.opacity(0.52)).onChange(of:store.selection) {_,_ in expandedSelection=false}
    }
}

struct VocabularyScreen:View {
    @ObservedObject var store:AppStore
    @State private var search=""
    @State private var kind="全部"
    @State private var sort="高频优先"
    var filtered:[Vocabulary] {
        let list=store.words.filter{(kind=="全部" || $0.kind==kind) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.translation.contains(search))}
        if sort=="高频优先" {return list.sorted{$0.lookups == $1.lookups ? $0.lastSeen > $1.lastSeen : $0.lookups > $1.lookups}}
        return list.sorted{$0.due < $1.due}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:24) {
            ScreenHeading(eyebrow:"WORDS WORTH KEEPING",title:"你读过的，正在成为你的。",subtitle:"从真实查阅中积累的单词、短语和句子。")
            HStack(spacing:16) {
                StatTile(title:"个人表达",value:"\(store.words.count)",detail:"从你的阅读中积累")
                StatTile(title:"反复查阅",value:"\(store.words.filter{$0.lookups>1}.count)",detail:"更值得多练习一次")
                StatTile(title:"今天到期",value:"\(store.dueWords.count)",detail:"每天最多练习 20 项")
            }
            HStack(spacing:15) {
                HStack {Image(systemName:"magnifyingglass").foregroundStyle(Palette.muted);TextField("搜索英文或中文",text:$search).textFieldStyle(.plain)}.padding(10).background(.white,in:RoundedRectangle(cornerRadius:8)).frame(maxWidth:330)
                Picker("类型",selection:$kind) {ForEach(["全部","单词","短语","句子"],id:\.self){Text($0)}}.labelsHidden().frame(width:100)
                Spacer()
                Picker("排序",selection:$sort) {ForEach(["高频优先","到期优先"],id:\.self){Text($0)}}.labelsHidden().frame(width:110)
                Button {store.exportBackup()} label:{Label("导出",systemImage:"square.and.arrow.up")}.buttonStyle(.bordered)
            }
            if filtered.isEmpty { EmptyContent(icon:"square.stack",title:store.words.isEmpty ? "从阅读中收集第一份表达" : "没有找到匹配的表达",detail:"查阅一个单词或短语，成功翻译后就会出现在这里。").frame(maxHeight:.infinity) }
            else {
                ScrollView { LazyVStack(spacing:10) {ForEach(filtered){word in WordRow(word:word,store:store)}}.padding(.bottom,15) }
            }
        }.padding(32)
    }
}

struct WordRow:View {
    let word:Vocabulary
    @ObservedObject var store:AppStore
    @State private var expanded=false
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:18) {
                VStack(alignment:.leading,spacing:7) {HStack {Text(word.text).font(.system(size:20,weight:.medium,design:.serif)).textSelection(.enabled);Text(word.kind).font(.system(size:9)).foregroundStyle(Palette.muted)};Text(word.translation).font(.system(size:12)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(expanded ? nil : 2)}.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.trailing,spacing:7) {Text("查阅 \(word.lookups) 次").font(.system(size:10,weight:.medium));Text(word.due <= Date() ? "待复习" : word.due.formatted(date:.abbreviated,time:.omitted)).font(.system(size:9)).foregroundStyle(word.due <= Date() ? Palette.orange : Palette.muted)}
                Button {store.audio.speak(word.text)} label:{Image(systemName:"speaker.wave.2")}.buttonStyle(ReadingButtonStyle()).help("朗读")
                Button {expanded.toggle()} label:{Image(systemName:expanded ? "chevron.up" : "chevron.down")}.buttonStyle(ReadingButtonStyle()).help("查看上下文")
                Menu { Button("删除词条",role:.destructive) {store.deleteWord(word)} } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:17)
            }
            if expanded {
                if !word.context.isEmpty {Text(word.context).font(.system(size:13,design:.serif)).lineSpacing(6).textSelection(.enabled).foregroundStyle(Palette.muted)}
                HStack {Label(word.paperTitle,systemImage:"doc.text").lineLimit(1);Text("· 遗忘 \(word.lapses) 次");Spacer();if let p=store.papers.first(where:{$0.id==word.paperID}) {Button("回到原文 →"){store.open(p,page:word.page)}.buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.green)}}.font(.system(size:10))
            }
        }.padding(20).background(.white.opacity(0.75),in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(Palette.line.opacity(0.6),lineWidth:1))
    }
}

struct ReviewScreen:View {
    @ObservedObject var store:AppStore
    var body:some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(alignment:.top) {
                ScreenHeading(eyebrow:"TEN MINUTES, EVERY DAY",title:"把今天的不熟悉，留给明天的自己。",subtitle:"按到期、遗忘次数和查阅频率，为你安排这一组练习。")
                Spacer()
                HStack(spacing:0) {modeButton("认词",icon:"character.book.closed",listening:false);modeButton("听力",icon:"headphones",listening:true)}.padding(4).background(Palette.pale,in:RoundedRectangle(cornerRadius:10))
            }
            if let word=store.currentCard {
                HStack {Text("\(store.reviewIndex+1) / \(store.queue.count)").font(.system(size:11,weight:.medium,design:.monospaced));ProgressView(value:Double(store.reviewIndex),total:Double(max(1,store.queue.count))).tint(Palette.green);Text("约 10 分钟").font(.system(size:10)).foregroundStyle(Palette.muted)}
                Spacer(minLength:0)
                VStack(spacing:24) {
                    Text(store.listening ? "LISTEN FIRST. TRUST YOUR EARS." : "PAUSE. RECALL. MAKE IT YOURS.").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(2).foregroundStyle(Palette.muted)
                    if store.listening && !store.revealed {
                        Image(systemName:"waveform").font(.system(size:62,weight:.ultraLight)).foregroundStyle(Palette.green).padding(.vertical,16)
                        Text("先听一听，你能认出来吗？").font(.system(size:19,design:.serif))
                        HStack(spacing:15) {Button {store.audio.speak(word.text)} label:{Label("播放",systemImage:"play.fill")}.buttonStyle(PrimaryButton());Button {store.audio.speak(word.text,slow:true)} label:{Label("慢速再听",systemImage:"tortoise")}.buttonStyle(.bordered)}
                    } else {
                        Text(word.text).font(.system(size:word.kind=="句子" ? 26 : 38,weight:.medium,design:.serif)).multilineTextAlignment(.center).textSelection(.enabled).lineSpacing(7)
                        Button {store.audio.speak(word.text)} label:{Label("听发音",systemImage:"speaker.wave.2")}.font(.system(size:12)).buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.green)
                    }
                    if store.revealed {
                        Divider().padding(.horizontal,50)
                        Text(word.translation).font(.system(size:19)).multilineTextAlignment(.center).lineSpacing(7).textSelection(.enabled)
                        if !word.context.isEmpty && word.context != word.text {Text(word.context).font(.system(size:13,design:.serif)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(6).lineLimit(5);Button("听论文原句"){store.audio.speak(word.context)}.buttonStyle(ReadingButtonStyle()).font(.system(size:11)).foregroundStyle(Palette.green)}
                        Text("来自 \(word.paperTitle) · 查阅 \(word.lookups) 次").font(.system(size:10)).foregroundStyle(Palette.muted).lineLimit(1)
                    } else {
                        Text(store.listening ? "原文和译文暂时隐藏，先试着辨认声音。" : "想一想它的含义，再揭晓答案。").font(.system(size:12)).foregroundStyle(Palette.muted).padding(.top,10)
                        Button {store.revealed=true} label:{Text("揭晓答案").frame(width:160)}.buttonStyle(PrimaryButton()).keyboardShortcut(.space,modifiers:[])
                    }
                }.padding(40).frame(maxWidth:800).frame(minHeight:390).frame(maxWidth:.infinity).background(.white.opacity(0.75),in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(Palette.line,lineWidth:1))
                if store.revealed {
                    HStack(spacing:12) {
                        ForEach(Grade.allCases,id:\.rawValue) {grade in
                            let next=Scheduler.next(stage:word.stage,grade:grade,now:Date())
                            Button {store.grade(grade)} label:{VStack(spacing:7){Text(grade.title).font(.system(size:13,weight:.semibold));Text(interval(next.due)).font(.system(size:10)).foregroundStyle(Palette.muted)}.frame(maxWidth:.infinity).padding(.vertical,15).background(grade == .good ? Palette.pale : .white,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Palette.line,lineWidth:1))}.buttonStyle(ReadingButtonStyle())
                        }
                    }
                }
                Spacer(minLength:0)
            } else {
                Spacer()
                EmptyContent(icon:store.queue.isEmpty ? "sun.horizon" : "checkmark.seal",title:store.queue.isEmpty ? "今天的复习队列是空的" : "这一组，已经记在心里。",detail:store.queue.isEmpty ? "去读一篇论文，查阅的表达会在这里等你。" : "已完成 \(store.queue.count) 项练习，新的间隔已经安排好。")
                HStack {Spacer();Button("回到阅读"){store.route = .reading}.buttonStyle(PrimaryButton());if !store.dueWords.isEmpty {Button("继续下一组"){store.beginReview(listening:store.listening)}.buttonStyle(.bordered)};Spacer()}.padding(.top,8)
                Spacer()
            }
            HStack {Image(systemName:"clock");Text(String(format:"每天 %02d:%02d · 北京时间 · 可在设置中调整",UserDefaults.standard.object(forKey:"reminderHour") as? Int ?? 20,UserDefaults.standard.object(forKey:"reminderMinute") as? Int ?? 30));Spacer();Text("今天已练习 \(store.reviewedToday) 项")}.font(.system(size:10)).foregroundStyle(Palette.muted)
        }.padding(32).onDisappear{store.audio.stop()}
    }
    func modeButton(_ title:String,icon:String,listening:Bool) -> some View {Button {store.beginReview(listening:listening)} label:{Label(title,systemImage:icon).font(.system(size:12,weight:.medium)).padding(.horizontal,15).padding(.vertical,9).background(store.listening==listening ? .white : .clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(ReadingButtonStyle())}
    func interval(_ date:Date)->String {let seconds=date.timeIntervalSinceNow;if seconds<3600{return "10 分钟后"};return "\(Int((seconds/86400).rounded())) 天后"}
}

struct SettingsScreen:View {
    @ObservedObject var store:AppStore
    @ObservedObject var engines:EngineManager
    @AppStorage("speechProvider") private var speechProvider="omnivoice"
    @AppStorage("voiceAccent") private var voice="american"
    @AppStorage("translationModel") private var model="translategemma:4b"
    @AppStorage("remindersEnabled") private var reminders=false
    @AppStorage("reminderHour") private var hour=20
    @AppStorage("reminderMinute") private var minute=30
    @State private var reminderMessage=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                ScreenHeading(eyebrow:"MADE TO STAY ON YOUR MAC",title:"安静地学习，安心地保存在本地。",subtitle:"设置本地模型、发音方式和每天的学习节奏。")
                settingsCard("本地模型",icon:"cpu") {
                    statusRow("翻译 · Ollama",detail:engines.translationStatus,ready:engines.translationReady)
                    Divider()
                    statusRow("发音 · OmniVoice",detail:engines.speechStatus,ready:engines.speechReady)
                    HStack(spacing:12) {
                        Button {Task{await engines.start()}} label:{Label("启动本地引擎",systemImage:"play")}.buttonStyle(PrimaryButton()).disabled(engines.checking || store.researchBusy)
                        Button("检查连接"){Task{await engines.check()}}.buttonStyle(.bordered).disabled(engines.checking)
                        Button("停止本应用启动的引擎"){store.stopLocalEngines()}.buttonStyle(.bordered)
                        Spacer()
                    }.padding(.top,6)
                    if let error=engines.error {Text(error).font(.system(size:11)).foregroundStyle(Palette.orange).textSelection(.enabled)}
                    HStack {
                        if engines.bundled {Label("已包含离线模型与运行环境",systemImage:"checkmark.seal").font(.system(size:11))}
                        else {Button("安装本地模型…"){NSWorkspace.shared.open(engines.runtime.deletingLastPathComponent().appendingPathComponent("安装本地模型.command"))}}
                        Button("查看引擎日志"){NSWorkspace.shared.open(engines.workDirectory.appendingPathComponent("logs"))};Spacer()
                    }.font(.system(size:11)).buttonStyle(ReadingButtonStyle()).foregroundStyle(Palette.green)
                    Text(engines.bundled ? "本版本已携带 Python、OmniVoice 和 TranslateGemma，无需下载。首次朗读会加载模型；日志和音频缓存保存在当前用户的数据目录。" : "首次使用需安装本地模型，下载中断后可继续安装。应用只会停止自己启动的引擎进程。").font(.system(size:11)).foregroundStyle(Palette.muted).lineSpacing(6)
                    if !engines.bundled {DownloadStatus(runtime:engines.runtime)}
                }
                settingsCard("翻译与发音",icon:"waveform") {
                    HStack {Text("翻译模型").font(.system(size:12));Spacer();TextField("translategemma:4b",text:$model).textFieldStyle(.roundedBorder).frame(width:230)}
                    HStack {Text("发音引擎").font(.system(size:12));Spacer();Picker("发音引擎",selection:$speechProvider){Text("OmniVoice · 本地模型").tag("omnivoice");Text("macOS 系统语音 · 临时试听").tag("system")}.labelsHidden().frame(width:230)}
                    HStack {Text("英语口音").font(.system(size:12));Spacer();Picker("英语口音",selection:$voice){Text("美式英语").tag("american");Text("英式英语").tag("british")}.labelsHidden().frame(width:230)}
                    Button("试听一句英文"){store.audio.speak("A little reading, a little growth. Every day is a chance to learn something new.")}.buttonStyle(.bordered).font(.system(size:11))
                }
                ResearchModelSettings(engines:engines)
                settingsCard("每日复习提醒",icon:"bell") {
                    HStack {
                        VStack(alignment:.leading,spacing:6) {Text("每天 10 分钟").font(.system(size:13,weight:.medium));Text("北京时间；点击系统通知进入练习。通知不自动播放声音材料。").font(.system(size:11)).foregroundStyle(Palette.muted)}
                        Spacer()
                        Toggle("启用提醒",isOn:Binding(get:{reminders},set:{value in
                            if value {Task {do {let granted=try await store.reminders.enable(words:store.words);reminderMessage=granted ? "已安排未来 30 天的个性化提醒；每次打开应用会更新。" : "通知尚未获准。请在系统设置 → 通知 → PaperLingo 中开启。"}catch{reminderMessage=error.localizedDescription}}}
                            else {store.reminders.disable();reminderMessage="已关闭系统提醒，应用内仍可复习。"}
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    HStack {
                        Text("提醒时间").font(.system(size:12));Spacer()
                        Picker("时",selection:$hour){ForEach(0..<24){Text(String(format:"%02d",$0)).tag($0)}}.labelsHidden().frame(width:75)
                        Text(":")
                        Picker("分",selection:$minute){ForEach(0..<60){Text(String(format:"%02d",$0)).tag($0)}}.labelsHidden().frame(width:75)
                        Text("Asia/Shanghai").font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted)
                    }
                    if !reminderMessage.isEmpty {Text(reminderMessage).font(.system(size:11)).foregroundStyle(Palette.green)}
                    Button("打开 macOS 通知设置"){if let url=URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension"){NSWorkspace.shared.open(url)}}.buttonStyle(.bordered).font(.system(size:11))
                    Button("发送测试提醒"){Task{do{try await store.reminders.test();reminderMessage="测试提醒已提交给 macOS，将在 3 秒后显示。"}catch{reminderMessage=error.localizedDescription}}}.buttonStyle(.bordered).font(.system(size:11))
                    Text("系统权限需在这台 Mac 上授权。通知提前安排 30 天，内容随每次学习更新；超过一个月未打开应用需重新打开更新。").font(.system(size:10)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                settingsCard("你的资料",icon:"externaldrive") {
                    Text("论文副本、词库、查询与复习日志均保存在本机。").font(.system(size:12))
                    Text(store.dataURL.path).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    HStack {Button("打开数据目录"){NSWorkspace.shared.open(store.dataURL)};Button("导出词库、档案与笔记…"){store.exportBackup()}}.buttonStyle(.bordered).font(.system(size:11))
                    Text("JSON 包含词条、档案、笔记与最新汇总，不含 PDF、完整日志或检索向量；完整备份请退出应用后复制整个数据目录。目前不支持 JSON 导入。").font(.system(size:10)).foregroundStyle(Palette.muted)
                }
                HStack {Text("PaperLingo 0.2 · macOS 原生应用");Spacer();Text("Keep reading. Keep growing.").font(.system(size:11,design:.serif))}.font(.system(size:10)).foregroundStyle(Palette.muted).padding(.bottom,10)
            }.padding(32).frame(maxWidth:980).frame(maxWidth:.infinity)
        }.task{await engines.check()}.onChange(of:hour){Task{await store.reminders.schedule(store.words)}}.onChange(of:minute){Task{await store.reminders.schedule(store.words)}}.onChange(of:speechProvider){store.audio.stop()}
    }
    func statusRow(_ title:String,detail:String,ready:Bool)->some View {HStack(alignment:.top){Text(title).font(.system(size:12,weight:.medium));Spacer();Circle().fill(ready ? Palette.green : Palette.orange).frame(width:6,height:6).padding(.top,4);Text(detail).font(.system(size:11)).foregroundStyle(Palette.muted).textSelection(.enabled).multilineTextAlignment(.trailing)}}
    func settingsCard<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content)->some View {VStack(alignment:.leading,spacing:17){Label(title,systemImage:icon).font(.system(size:14,weight:.semibold)).padding(.bottom,2);content()}.padding(24).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(Palette.line,lineWidth:1))}
}

struct LinkImport:View {
    @ObservedObject var store:AppStore
    @State private var url=""
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            Label("带一篇论文进来",systemImage:"link").font(.system(size:24,weight:.medium,design:.serif))
            Text("粘贴 PDF 直链、arXiv 摘要页或英文网页链接。\n网页会保存为本地正文，方便随时继续读。").font(.system(size:12)).foregroundStyle(Palette.muted).lineSpacing(6)
            TextField("https://arxiv.org/abs/…",text:$url).textFieldStyle(.roundedBorder).onSubmit{Task{await store.importLink(url)}}.disabled(store.importing)
            if store.importing {HStack{ProgressView().controlSize(.small);Text("正在下载并保存到本地…").font(.system(size:11))}}
            HStack {Button("取消"){store.showLink=false}.keyboardShortcut(.cancelAction);Spacer();Button("导入并开始阅读"){Task{await store.importLink(url)}}.buttonStyle(PrimaryButton()).disabled(url.isEmpty || store.importing)}
        }.padding(35).frame(width:500).background(Palette.cream)
        .alert("无法导入链接",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("知道了",role:.cancel){store.error=nil}} message:{Text(store.error ?? "")}
    }
}

struct AudioBar:View {
    @ObservedObject var audio:AudioService
    @State private var collapsed=false
    var body:some View {
        if audio.busy || audio.playing || audio.error != nil {
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:8) {
                    if audio.busy {ProgressView().controlSize(.small)} else {Image(systemName:audio.error == nil ? "waveform" : "exclamationmark.circle").foregroundStyle(Palette.green)}
                    if !collapsed {
                        VStack(alignment:.leading,spacing:3) {
                            Text(audio.error != nil ? "朗读提示" : audio.paused ? "已暂停" : audio.busy ? (audio.currentPart == 0 ? "正在生成首句…" : "正在接续下一句…") : "正在朗读").font(.system(size:12,weight:.medium))
                            Text(audio.totalParts > 0 ? "\(audio.label) · \(audio.currentPart)/\(audio.totalParts) 段 · 已生成 \(audio.generatedParts) 段" : audio.label).font(.system(size:10)).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer(minLength:4)
                    if audio.error == nil {
                        Button {audio.togglePause()} label:{Image(systemName:audio.paused ? "play.fill" : "pause.fill")}.help(audio.paused ? "继续朗读" : "暂停朗读")
                    }
                    Button {collapsed.toggle()} label:{Image(systemName:collapsed ? "chevron.up" : "chevron.down")}.help(collapsed ? "展开播放器" : "收起播放器")
                    Button {audio.stop()} label:{Image(systemName:"xmark")}.help("停止并关闭 ⌘.")
                }
                if !collapsed {
                    if let error=audio.error {Text(error).font(.system(size:11)).foregroundStyle(Palette.orange).lineLimit(3)}
                    else if !audio.currentText.isEmpty {Text(audio.currentText).font(.system(size:11,design:.serif)).lineLimit(2).foregroundStyle(Palette.muted)}
                }
            }.buttonStyle(ReadingButtonStyle()).padding(collapsed ? 8 : 13).frame(width:collapsed ? 172 : 340)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).stroke(Palette.line,lineWidth:1))
                .shadow(color:.black.opacity(0.10),radius:14,y:4)
        }
    }
}

struct ScreenHeading:View {
    let eyebrow:String,title:String,subtitle:String
    var body:some View {VStack(alignment:.leading,spacing:13){Text(eyebrow).font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.8).foregroundStyle(Palette.orange);Text(title).font(.system(size:27,weight:.medium,design:.serif));Text(subtitle).font(.system(size:12)).foregroundStyle(Palette.muted).lineSpacing(5)}}
}
struct StatTile:View {
    let title:String,value:String,detail:String
    var body:some View {VStack(alignment:.leading,spacing:9){Text(title).font(.system(size:11)).foregroundStyle(Palette.muted);Text(value).font(.system(size:31,weight:.medium,design:.serif));Text(detail).font(.system(size:10)).foregroundStyle(Palette.muted)}.padding(21).frame(maxWidth:.infinity,alignment:.leading).background(Palette.pale.opacity(0.65),in:RoundedRectangle(cornerRadius:11))}
}
struct EmptyContent:View {
    let icon:String,title:String,detail:String
    var body:some View {VStack(spacing:18){Image(systemName:icon).font(.system(size:45,weight:.ultraLight)).foregroundStyle(Palette.green);Text(title).font(.system(size:23,weight:.medium,design:.serif));Text(detail).font(.system(size:12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)}.padding(35).frame(maxWidth:.infinity)}
}
