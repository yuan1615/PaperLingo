import AppKit
import AVFoundation
import Foundation
import PaperCore
import UserNotifications

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum LocalAPI {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 240
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()
    static func request(port: Int, path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = body == nil ? 5 : 300
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw AppError.message(object?["error"] as? String ?? "本地服务返回错误，请检查引擎日志。")
        }
        return data
    }
    static func translate(_ text: String, model: String) async throws -> String {
        let prompt = """
        You are a professional English (en) to Chinese (zh-Hans) translator. Your goal is to accurately convey the meaning and nuances of the original English text while adhering to Chinese grammar, vocabulary, and cultural sensitivities.
        Produce only the Chinese translation, without any additional explanations or commentary. Please translate the following English text into Chinese:


        \(text)
        """
        let data = try await request(port: 11434, path: "/api/chat", body: [
            "model": model, "stream": false,
            "messages": [["role": "user", "content": prompt]],
            "options": ["temperature": 0.1, "num_ctx": 4096, "num_predict": 2048],
            "keep_alive": "2m"
        ])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["done_reason"] as? String == "length" {throw AppError.message("译文达到模型输出上限，请缩小选区后重试。")}
        guard let message = object?["message"] as? [String: Any], let result = message["content"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("翻译模型没有返回文本，请重试。")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor final class EngineManager: ObservableObject {
    @Published var translationStatus = "检查中"
    @Published var speechStatus = "检查中"
    @Published var translationReady = false
    @Published var speechReady = false
    @Published var error: String?
    @Published var checking = false
    @Published var analysisReady=false
    @Published var embeddingReady=false
    @Published var analysisStatus="尚未检查"
    @Published var embeddingStatus="尚未检查"
    var modelDigests:[String:String]=[:]
    private var ollama: Process?
    private var speech: Process?
    private var logHandles: [String:FileHandle] = [:]
    let runtime: URL
    let workDirectory: URL
    let bundled: Bool
    private let paths:RuntimePaths
    let engineScript: URL
    init() {
        let resource = Bundle.main.url(forResource: "runtime", withExtension: "json")
        let config = resource.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        paths=RuntimePaths(configuration:config ?? [:],resources:Bundle.main.resourceURL ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath),applicationSupport:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
        runtime=paths.assets;workDirectory=paths.work;bundled=paths.bundled
        engineScript = Bundle.main.resourceURL?.appendingPathComponent("engine/server.py") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/engine/server.py")
    }
    func check() async {
        checking = true
        defer { checking = false }
        do {
            let data = try await LocalAPI.request(port: 11434, path: "/api/tags")
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = result?["models"] as? [[String: Any]] ?? []
            modelDigests=Dictionary(models.compactMap{m -> (String,String)? in guard let name=m["name"] as? String,let digest=m["digest"] as? String else{return nil};return(name,digest)},uniquingKeysWith:{$1})
            analysisReady=modelDigests[ResearchModels.analysis] != nil
            embeddingReady=modelDigests[ResearchModels.embedding] != nil
            analysisStatus=analysisReady ? "已就绪 · Qwen3.6 27B Q4" : "研究模型尚未安装"
            embeddingStatus=embeddingReady ? "已就绪 · Qwen3 Embedding 0.6B" : "检索模型尚未安装"
            let name = UserDefaults.standard.string(forKey: "translationModel") ?? "translategemma:4b"
            let expected=name.contains(":") ? name : name+":latest"
            translationReady = models.contains { ($0["name"] as? String) == expected || ($0["model"] as? String) == expected }
            translationStatus = translationReady ? "已就绪 · \(name)" : "Ollama 已连接 · 模型未安装"
        } catch { translationReady = false; translationStatus = "未启动";analysisReady=false;embeddingReady=false;analysisStatus="Ollama 未启动";embeddingStatus="Ollama 未启动";modelDigests=[:] }
        do {
            let data = try await LocalAPI.request(port: 8765, path: "/health")
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            speechReady = result?["service"] as? String == "paperlingo-omnivoice" && result?["installed"] as? Bool == true && result?["protocol"] as? Int == 2
            if let failure = result?["error"] as? String { speechReady = false; speechStatus = "加载失败：\(failure)" }
            else if result?["service"] as? String == "paperlingo-omnivoice", result?["protocol"] as? Int != 2 {speechStatus = "语音服务版本较旧，请退出旧版 PaperLingo 后重新启动"}
            else { speechStatus = speechReady ? (result?["loaded"] as? Bool == true ? "模型已载入" : "服务就绪 · 首次播放加载模型") : "OmniVoice 未安装" }
        } catch { speechReady = false; speechStatus = "未启动" }
        if translationReady && speechReady {error=nil}
    }
    func start() async {
        error = nil
        await check()
        do {
            try paths.prepare()
            if !translationReady, ollama?.isRunning != true {
                // A reachable Ollama with a missing model must not be shadowed by another process.
                if (try? await LocalAPI.request(port: 11434, path: "/api/version")) == nil {
                    ollama = try launch(runtime.appendingPathComponent("bin/ollama"), args: ["serve"], log: "ollama.log")
                }
            }
            if !speechReady, speech?.isRunning != true {
                if (try? await LocalAPI.request(port:8765,path:"/health")) != nil {
                    throw AppError.message("8765 端口已有其他版本的语音服务，请退出旧版 PaperLingo 后重试。")
                }
                guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("models.ready").path) else { throw AppError.message(bundled ? "安装包缺少模型，请重新复制完整的 PaperLingo.app。" : "模型还未下载完成。请运行「安装本地模型.command」，在安装日志中查看进度。") }
                let marker=try Data(contentsOf:runtime.appendingPathComponent("models.ready"))
                let manifest=try JSONSerialization.jsonObject(with:marker) as? [String:String]
                guard let modelPath=manifest?["omnivoice"],FileManager.default.fileExists(atPath:paths.modelURL(modelPath).path) else {throw AppError.message(bundled ? "安装包中的 OmniVoice 模型不完整，请重新复制完整应用。" : "OmniVoice 模型路径无效，请重新运行安装脚本。")}
                speech = try launch(runtime.appendingPathComponent("venv/bin/python"), args: [engineScript.path,"--model",paths.modelURL(modelPath).path,"--cache",workDirectory.appendingPathComponent("audio-cache").path], log: "omnivoice.log")
            }
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(500))
                await check()
                if translationReady && speechReady { break }
            }
        } catch { self.error = error.localizedDescription }
        await check()
    }
    private func launch(_ url: URL, args: [String], log: String) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw AppError.message("还未安装本地运行时，请先运行「安装本地模型.command」。") }
        let logs = workDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent(log)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL); try handle.seekToEnd()
        try? logHandles.removeValue(forKey:log)?.close();logHandles[log]=handle
        let process = Process(); process.executableURL = url; process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = workDirectory.appendingPathComponent("huggingface").path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["NUMBA_CACHE_DIR"] = workDirectory.appendingPathComponent("numba-cache").path
        environment["OLLAMA_MODELS"] = paths.ollamaModels.path
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_CONTEXT_LENGTH"] = "4096"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        process.environment = environment; process.standardOutput = handle; process.standardError = handle
        try process.run(); return process
    }
    func stop() {
        if ollama?.isRunning == true { ollama?.terminate() }
        if speech?.isRunning == true { speech?.terminate() }
        ollama = nil; speech = nil
        for handle in logHandles.values {try? handle.close()};logHandles.removeAll()
        Task { await check() }
    }
    func pauseSpeechForResearch() async -> Bool {
        guard let speech,speech.isRunning else{return false}
        speech.terminate()
        for _ in 0..<40 {
            if !speech.isRunning {break}
            try? await Task.sleep(for:.milliseconds(50))
        }
        self.speech=nil;speechReady=false;speechStatus="论文整理期间暂停，完成后恢复"
        try? logHandles.removeValue(forKey:"omnivoice.log")?.close()
        return true
    }
}

@MainActor final class AudioService: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    var researchBusy=false
    @Published var busy = false
    @Published var playing = false
    @Published var generating = false
    @Published var paused = false
    @Published var error: String?
    @Published var label = ""
    @Published var currentText = ""
    @Published var currentPart = 0
    @Published var totalParts = 0
    @Published var generatedParts = 0
    private struct Clip { let data: Data; let index: Int; let text: String }
    private var clips: [Clip] = []
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, slow: Bool = false) {
        guard !researchBusy || UserDefaults.standard.string(forKey:"speechProvider")=="system" else {error="论文整理进行中；可取消整理，或切换系统语音继续试听。";return}
        stop()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 12000 else { error = "选区过长，请分成小于 12,000 字符的段落朗读。"; return }
        let provider = UserDefaults.standard.string(forKey: "speechProvider") ?? "omnivoice"
        let voice = UserDefaults.standard.string(forKey: "voiceAccent") ?? "american"
        let speed = slow ? 0.75 : 1.0
        if provider == "system" {
            label = "macOS 系统语音"; playing = true; currentText = text
            let next = AVSpeechUtterance(string: text); utterance = next
            next.voice = AVSpeechSynthesisVoice(language: voice == "british" ? "en-GB" : "en-US")
            next.rate = slow ? 0.35 : 0.48
            synthesizer.speak(next); return
        }
        label = slow ? "OmniVoice · 慢速" : "OmniVoice"
        busy = true; generating = true
        let token = generation
        task = Task {
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/speak/stream")!)
                request.httpMethod = "POST"; request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["request_id": token.uuidString, "text": text, "speed": speed, "voice": voice])
                let (bytes, response) = try await LocalAPI.session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw AppError.message("分段语音服务未就绪，请在设置中重新启动本地引擎。")
                }
                var completed = false
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    let event = try JSONDecoder().decode(SpeechEvent.self, from: Data(line.utf8))
                    switch event.type {
                    case "start":
                        guard totalParts == 0, let total = event.total, total > 0 else { throw AppError.message("语音分段信息无效。") }
                        totalParts = total
                    case "audio":
                        guard let index = event.index, index == generatedParts + 1, index <= totalParts,
                              let encoded = event.audio, let data = Data(base64Encoded: encoded), !data.isEmpty else {
                            throw AppError.message("语音片段不完整，请重试。")
                        }
                        generatedParts = index
                        clips.append(Clip(data: data, index: index, text: event.text ?? ""))
                        if player == nil { try playNext() }
                    case "done":
                        guard generatedParts == totalParts, totalParts > 0 else { throw AppError.message("语音生成提前结束，请重试。") }
                        completed = true
                    case "error": throw AppError.message(event.error ?? "语音生成失败。")
                    case "cancelled": throw CancellationError()
                    default: throw AppError.message("无法识别语音服务响应。")
                    }
                }
                guard !Task.isCancelled, generation == token else { return }
                guard completed else { throw AppError.message("本地语音连接中断，请重试。") }
                generating = false
                if player == nil { try playNext() }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                generating = false; busy = false
                self.error = "朗读未完成：\(error.localizedDescription)"
                Task { _ = try? await LocalAPI.request(port:8765,path:"/cancel",body:["request_id":token.uuidString]) }
                // A received, valid segment can finish playing even if later inference fails.
            }
        }
    }
    private func playNext() throws {
        guard player == nil else { return }
        guard !clips.isEmpty else {
            playing = false; busy = generating
            if !generating { paused = false }
            return
        }
        let clip = clips.removeFirst()
        let next = try AVAudioPlayer(data: clip.data)
        next.delegate = self; next.prepareToPlay(); player = next
        currentText = clip.text; currentPart = clip.index
        busy = false; playing = true
        if !paused && !next.play() { player = nil; playing = false; throw AppError.message("无法播放生成的音频。") }
    }
    func togglePause() {
        guard playing || busy else { return }
        paused.toggle()
        if let player {
            if paused { player.pause() } else if !player.play() { stop(); error = "无法恢复音频播放。" }
        } else if utterance != nil {
            if paused { synthesizer.pauseSpeaking(at: .immediate) } else { synthesizer.continueSpeaking() }
        }
    }
    func stop() {
        let previous = generation, cancelServer = generating
        generation = UUID(); task?.cancel(); task = nil
        player?.delegate = nil; player?.stop(); player = nil
        utterance = nil; synthesizer.stopSpeaking(at: .immediate)
        clips.removeAll(); busy = false; playing = false; generating = false; paused = false; error = nil
        currentText = ""; currentPart = 0; totalParts = 0; generatedParts = 0
        if cancelServer {
            Task { _ = try? await LocalAPI.request(port: 8765, path: "/cancel", body: ["request_id": previous.uuidString]) }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard finished === self.player else { return }
            self.player = nil
            do {
                guard flag else { throw AppError.message("音频播放中断。") }
                try self.playNext()
            } catch { self.stop(); self.error = error.localizedDescription }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ finished: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard finished === self.player else { return }
            self.stop(); self.error = "无法解码音频，请重试。"
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish finished: AVSpeechUtterance) {
        Task { @MainActor in
            guard finished === self.utterance else { return }
            self.utterance = nil; self.playing = false; self.paused = false
        }
    }
}

private struct SpeechEvent: Decodable {
    let type: String
    let total: Int?
    let index: Int?
    let text: String?
    let audio: String?
    let error: String?
}

@MainActor final class Reminders {
    func test() async throws {
        let center=UNUserNotificationCenter.current()
        let settings=await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {throw AppError.message("请先开启每日提醒，并允许 macOS 通知。")}
        let content=UNMutableNotificationContent()
        content.title="PaperLingo · 通知已就绪"
        content.categoryIdentifier="DAILY_REVIEW"
        content.body="你的每日复习提醒已开启。点此进入今日练习，开始认词和听力。"
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier:"paperlingo-test",content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:3,repeats:false)))
    }
    func enable(words: [Vocabulary]) async throws -> Bool {
        let granted: Bool
        do { granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound]) }
        catch { throw AppError.message("macOS 暂未允许 PaperLingo 发送通知。请在系统设置 → 通知中查找 PaperLingo 并开启，然后返回重试。应用内练习仍可使用。系统信息：\(error.localizedDescription)") }
        UserDefaults.standard.set(granted, forKey: "remindersEnabled")
        if granted { await schedule(words) }
        return granted
    }
    func schedule(_ words: [Vocabulary]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard UserDefaults.standard.bool(forKey: "remindersEnabled") else { return }
        let hour = UserDefaults.standard.object(forKey: "reminderHour") as? Int ?? 20
        let minute = UserDefaults.standard.object(forKey: "reminderMinute") as? Int ?? 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for day in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: day, to: Date()), let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date), fire > Date() else { continue }
            let queue = Scheduler.queue(words, at: fire)
            let content = UNMutableNotificationContent()
            content.title = "PaperLingo · 今天的 10 分钟"
            content.categoryIdentifier="DAILY_REVIEW"
            content.body = queue.isEmpty ? "读一段论文，积累今天的表达，再来做一组听力练习。" : "\(queue.count) 项待复习：\(queue.prefix(3).map {String($0.text.prefix(55))}.joined(separator: " · "))。点此开始认词与听力。"
            content.sound = .default
            var components = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: fire)
            components.timeZone = calendar.timeZone
            try? await center.add(UNNotificationRequest(identifier: "paperlingo-\(day)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        // A final refresh reminder follows the 30-day personalized window.
        if let next = calendar.date(byAdding: .day, value: 30, to: Date()) {
            let content = UNMutableNotificationContent(); content.title = "PaperLingo · 今天的 10 分钟"; content.categoryIdentifier="DAILY_REVIEW";content.body = "打开应用，更新你的个人词汇复习与听力计划。"; content.sound = .default
            // Calendar triggers cannot express a start date plus daily recurrence; the app refreshes the window on each launch.
            var components = calendar.dateComponents([.year,.month,.day], from: next); components.hour=hour; components.minute=minute; components.timeZone=calendar.timeZone
            try? await center.add(UNNotificationRequest(identifier: "paperlingo-refresh", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }
    func disable() { UserDefaults.standard.set(false, forKey: "remindersEnabled"); UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
}
