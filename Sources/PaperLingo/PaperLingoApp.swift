import AppKit
import SwiftUI
import UserNotifications

extension Notification.Name { static let openReview=Notification.Name("PaperLingo.openReview") }

final class AppDelegate:NSObject,NSApplicationDelegate,UNUserNotificationCenterDelegate {
    @MainActor static var pendingListening:Bool?
    @MainActor weak var store:AppStore?
    @MainActor func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let store,store.hasUnsavedResearchEdits,(store.noteEditor != nil || store.metadataEditor != nil) else {return .terminateNow}
        let alert=NSAlert();alert.messageText="还有未保存的研究记录"
        alert.informativeText="个人笔记或文献档案尚有未保存修改。继续编辑后可先保存，再退出应用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle:"继续编辑");alert.addButton(withTitle:"放弃修改并退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    @MainActor func applicationWillTerminate(_ notification:Notification) {
        // SwiftUI subscriptions may already be gone when AppKit terminates.
        // Signal the owned engines synchronously before the app exits.
        store?.shuttingDown=true
        store?.researchTask?.cancel();store?.searchTask?.cancel()
        store?.stopReviewContext()
        store?.audio.stop()
        store?.engines.stop()
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate=self
        let actions=[UNNotificationAction(identifier:"LISTEN",title:"开始听力",options:[.foreground]),UNNotificationAction(identifier:"RECOGNITION",title:"认词练习",options:[.foreground])]
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier:"DAILY_REVIEW",actions:actions,intentIdentifiers:[],options:[])])
        NSApplication.shared.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void) {
        DispatchQueue.main.async {
            let listening=response.actionIdentifier=="LISTEN"
            Self.pendingListening=listening
            NSApp.activate(ignoringOtherApps:true);NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name:.openReview,object:nil,userInfo:["listening":listening])
        }
        completionHandler()
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.sound]) }
}

@main struct PaperLingoApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store=AppStore()
    var body:some Scene {
        WindowGroup("PaperLingo") {
            RootView(store:store).frame(minWidth:860,minHeight:620).preferredColorScheme(.light)
                .onOpenURL { url in if url.isFileURL && url.pathExtension.lowercased()=="pdf" {store.importPDF(url)} }
                .onReceive(NotificationCenter.default.publisher(for:.openReview)) { event in store.route = .review;store.beginReview(listening:event.userInfo?["listening"] as? Bool ?? false);AppDelegate.pendingListening=nil }
                .task {
                    delegate.store=store
                    if let listening=AppDelegate.pendingListening {AppDelegate.pendingListening=nil;store.route = .review;store.beginReview(listening:listening)}
                    await store.engines.start();await store.reminders.schedule(store.words)
                }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in
                    Task { try? store.reload(); await store.reminders.schedule(store.words) }
                }
        }
        .defaultSize(width:1440,height:900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("研究库") {
                Button("打开研究库"){store.route = .library}.keyboardShortcut("k",modifiers:[.command,.shift])
                Button("记录当前论文…"){store.noteCurrentLocation()}.keyboardShortcut("n",modifiers:[.command,.shift]).disabled(store.currentNotePaper==nil || store.noteEditor != nil || store.metadataEditor != nil)
            }
            CommandGroup(replacing:.newItem) {
                Button("导入 PDF…") { store.choosePDF() }.keyboardShortcut("o").disabled(store.noteEditor != nil || store.metadataEditor != nil)
                Button("导入链接…") { store.showLink=true }.keyboardShortcut("o",modifiers:[.command,.shift]).disabled(store.noteEditor != nil || store.metadataEditor != nil)
            }
            CommandMenu("阅读视图") {
                Button("专注阅读 / 退出专注") {store.layout.focused.toggle()}.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(store.route != .reading || store.selectedPaper == nil)
                Button("显示 / 收起论文库") {store.layout.sidebarVisible.toggle();store.layout.focused=false}.keyboardShortcut("s",modifiers:[.command,.option])
                Button("显示 / 收起学习助手") {store.layout.assistantVisible.toggle();store.layout.focused=false}.keyboardShortcut("i",modifiers:[.command,.option])
            }
            CommandMenu("学习") {
                Button("翻译选区") { Task { await store.translate() } }.keyboardShortcut("d")
                Button("朗读选区") { store.audio.speak(store.selection) }.keyboardShortcut("l")
                Button("停止朗读") { store.audio.stop() }.keyboardShortcut(".")
                Button("今日练习") { store.route = .review; store.beginReview(listening:false) }.keyboardShortcut("r")
            }
        }
    }
}
