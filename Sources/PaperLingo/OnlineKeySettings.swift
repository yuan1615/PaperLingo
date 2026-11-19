import SwiftUI

struct OnlineKeySettings: View {
    @ObservedObject var store: AppStore
    @State private var draft = ""
    @State private var saved = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("OpenAI API Key", systemImage: "key").fontWeight(.medium)
                Spacer()
                Text(saved ? "已存入本机钥匙串" : "尚未配置").foregroundStyle(Palette.muted)
            }
            HStack {
                SecureField(saved ? "输入新密钥以替换" : "粘贴项目 API Key", text: $draft)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("OpenAI API Key")
                Button("保存密钥") {
                    do {
                        try OnlineAccess.save(draft)
                        store.credentialsDidChange()
                        draft = ""; saved = true; issue = nil
                    } catch { issue = error.localizedDescription }
                }.disabled(draft.isEmpty)
                if saved {
                    Button("移除密钥") {
                        do {
                            try OnlineAccess.remove()
                            store.credentialsDidChange()
                            draft = ""; saved = false; issue = nil
                        } catch { issue = error.localizedDescription }
                    }.help("从本机钥匙串移除。要撤销此密钥，请前往 OpenAI 项目。")
                }
            }
            if let issue { Text(issue).foregroundStyle(Palette.orange) }
            Text("选择 OpenAI 后，翻译发送选区，摘要发送 PDF 前三页文字或网页开头，词语讲解发送词条和原句片段，朗读发送清理后的英文。索引与个人笔记保存在本机。")
            HStack {
                Text("在线请求按 API 用量计费。")
                Link("创建项目密钥", destination: URL(string:"https://platform.openai.com/api-keys")!)
                Link("查看用量", destination: URL(string:"https://platform.openai.com/usage")!)
            }
        }
        .font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
        .onAppear {
            do { saved = try OnlineAccess.hasKey() }
            catch { issue = error.localizedDescription }
        }
        .onDisappear { draft = "" }
    }
}
