import CryptoKit
import Foundation

public struct SpeechReferenceVoice:Codable,Equatable,Identifiable,Sendable {
    public let id:String
    public let label:String
    public let file:String
    public let text:String
    public let sha256:String
}

public struct SpeechVoiceCatalog:Sendable {
    public let voices:[SpeechReferenceVoice]
    public let signature:String
    public let directory:URL
    public init(directory:URL) throws {
        struct Document:Decodable {let version:Int;let voices:[SpeechReferenceVoice]}
        let data=try Data(contentsOf:directory.appendingPathComponent("manifest.json"))
        let document=try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1,(1...100).contains(document.voices.count),Set(document.voices.map(\.id)).count == document.voices.count else {
            throw ResearchError.message("参考声音清单无效，请重新复制声音素材。")
        }
        for voice in document.voices {
            guard voice.id.range(of:"^[A-Za-z0-9_-]{1,64}$",options:.regularExpression) != nil,
                  voice.file == voice.id+".wav",(1...40).contains(voice.label.count),
                  !voice.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,voice.text.count<=1000 else {
                throw ResearchError.message("参考声音编号或转写无效。")
            }
            let file=directory.appendingPathComponent(voice.file).resolvingSymlinksInPath()
            guard file.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {throw ResearchError.message("参考声音文件路径无效。")}
            let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard (1...5_000_000).contains(size) else {throw ResearchError.message("参考声音文件大小无效。")}
            let audio=try Data(contentsOf:file)
            guard SHA256.hash(data:audio).map({String(format:"%02x",$0)}).joined() == voice.sha256 else {
                throw ResearchError.message("参考声音 \(voice.id) 校验失败，请重新复制素材。")
            }
        }
        voices=document.voices
        signature=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        self.directory=directory
    }
    public func randomVoice(avoiding previous:String?=nil)->SpeechReferenceVoice {
        let candidates=voices.count>1 ? voices.filter{$0.id != previous}:voices
        return candidates.randomElement()!
    }
}
