import Foundation
import SwiftUI

struct DownloadStatus:View {
    let runtime:URL
    @State private var ratio:Double?
    @State private var detail=""
    @State private var log=""
    @State private var showLog=false
    @State private var translationRatio:Double?
    @State private var translationDetail=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if !detail.isEmpty {
                Label(detail,systemImage:"arrow.down.circle").font(.system(size:11,weight:.medium)).foregroundStyle(Palette.green)
                if let ratio {ProgressView(value:ratio).tint(Palette.green)}
            }
            if let translationRatio {
                Text("TranslateGemma · \(translationDetail)").font(.system(size:11,weight:.medium)).foregroundStyle(Palette.green)
                ProgressView(value:translationRatio).tint(Palette.green)
            }
            HStack {
                Text("下载中断后可继续安装。").font(.system(size:10)).foregroundStyle(Palette.muted)
                Spacer()
                Button(showLog ? "收起安装日志" : "查看安装日志"){showLog.toggle();refresh()}.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Palette.green)
            }
            if showLog {ScrollView {Text(log.isEmpty ? "尚无安装日志。双击「安装本地模型.command」开始。" : log).font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(height:180).padding(10).background(Palette.pale.opacity(0.5),in:RoundedRectangle(cornerRadius:8))}
        }.task {while !Task.isCancelled {refresh();try? await Task.sleep(for:.seconds(3))}}
    }
    private func refresh() {
        let url=runtime.appendingPathComponent("logs/model-progress.json")
        if let data=try? Data(contentsOf:url),let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let value=state["ratio"] as? Double {
            ratio=value
            let name=(state["file"] as? String)?.contains("audio_tokenizer") == true ? "OmniVoice 音频解码器" : "OmniVoice 主模型"
            detail=state["verified"] as? Bool == true ? "\(name) · 已下载并校验" : String(format:"%@ · 下载 %.1f%%",name,value*100)
        }
        let translationLog=tail(runtime.appendingPathComponent("logs/translation-download.log"))
        if translationLog.contains("success") {translationRatio=1;translationDetail="已下载并校验"}
        else if let regex=try? NSRegularExpression(pattern:"pulling [a-f0-9]+:\\s*(\\d+)%"),let result=regex.matches(in:translationLog,range:NSRange(translationLog.startIndex...,in:translationLog)).last {
            let percent=(translationLog as NSString).substring(with:result.range(at:1))
            translationRatio=(Double(percent) ?? 0)/100;translationDetail="下载 \(percent)%"
        }
        if showLog {
            let paths=[runtime.appendingPathComponent("logs/install.log"),runtime.appendingPathComponent("logs/model-download.log"),runtime.appendingPathComponent("logs/translation-download.log")]
            log=paths.map {"\($0.lastPathComponent)\n"+tail($0)}.joined(separator:"\n\n")
        }
    }
    private func tail(_ url:URL)->String {
        guard let handle=try? FileHandle(forReadingFrom:url) else{return ""}
        defer{try? handle.close()}
        do {
            let size=try handle.seekToEnd();try handle.seek(toOffset:size>6000 ? size-6000 : 0)
            return String(decoding:try handle.readToEnd() ?? Data(),as:UTF8.self).replacingOccurrences(of:"\\x1B\\[[0-?]*[ -/]*[@-~]",with:"",options:.regularExpression)
        } catch{return ""}
    }
}
