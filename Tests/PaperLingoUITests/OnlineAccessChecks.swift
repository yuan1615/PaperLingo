import AppKit
import Security
import SwiftUI
@_spi(Testing) import PaperCore

private final class PendingResponse: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0
    static var started: Int { lock.withLock { starts } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.starts += 1 } }
    override func stopLoading() {}
}

@main @MainActor private struct OnlineAccessChecks {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message("FAIL " + message) }
        print("PASS " + message)
    }

    static func main() async throws {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard id.hasPrefix("local.paperlingo.reviewqa.") else {
            throw AppError.message("Requires an isolated QA bundle and disposable Keychain service.")
        }
        let first = "sk-" + UUID().uuidString
        let second = "sk-" + UUID().uuidString
        try check(try !OnlineAccess.hasKey(), "An isolated install has no configured key")
        defer { try? OnlineAccess.remove() }
        let invalidSaved: Void? = try? OnlineAccess.save("invalid value")
        try check(invalidSaved == nil, "Malformed input cannot replace a credential")
        try OnlineAccess.save(first)
        try check(try OnlineAccess.hasKey(), "Saved a disposable key to the real login Keychain")
        _ = try OnlineAccess.client()
        try OnlineAccess.save(second)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: id + ".openai", kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: false, kSecReturnData as String: true]
        var item: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess &&
                  (item as? Data) == Data(second.utf8), "Replacement updates the non-synchronizing item")
        let prefs = UserDefaults.standard.persistentDomain(forName:id) ?? [:]
        try check(!String(describing:prefs).contains(first) && !String(describing:prefs).contains(second),
                  "The disposable key is absent from preferences")
        try OnlineAccess.remove()
        try check(try !OnlineAccess.hasKey(), "Removing the key deletes the item")
        do {
            _ = try OnlineAccess.client()
            throw AppError.message("Missing key returned a client")
        } catch AppError.message(let error) where error.contains("请先") {}

        let store = AppStore(onlineClient:{ OpenAIClient(apiKey:"fixture", protocolClass:PendingResponse.self) })
        store.updateSelection("example", context:"A synthetic example.", page:0)
        for rotating in [false, true] {
            store.translationOnline = true
            let before = PendingResponse.started
            let request = Task { await store.translate() }
            for _ in 0..<100 where PendingResponse.started == before {
                try await Task.sleep(for:.milliseconds(20))
            }
            try check(PendingResponse.started == before + 1, "Translation uses the injected online transport")
            if rotating { store.credentialsDidChange() } else { store.translationOnline = false }
            await request.value
            try check(!store.translating && store.error == nil && store.words.isEmpty && store.translation.isEmpty,
                      "Changing the service or key cancels translation without saving a stale lookup")
        }
        store.analysisOnline = true
        let reopened = AppStore()
        try check(reopened.translationOnline && reopened.analysisOnline, "Independent selections survive relaunch")

        _ = NSApplication.shared
        UserDefaults.standard.set("openai", forKey:"speechProvider")
        store.route = .settings
        let view = NSHostingView(rootView:RootView(store:store).frame(width:1000,height:720).preferredColorScheme(.light))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:.aqua)
        window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(400))
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:rep)
            let work = URL(fileURLWithPath:CommandLine.arguments[1])
            try rep.representation(using:.png,properties:[:])?.write(to:work.appendingPathComponent("online-settings.png"))
        }
        window.orderOut(nil)
    }
}
