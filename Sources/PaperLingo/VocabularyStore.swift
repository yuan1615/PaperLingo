import Foundation
import PDFKit
import PaperCore

extension AppStore {
    func explanation(for word:Vocabulary) -> WordExplanation? {
        guard let value=wordExplanations[word.id],value.isCurrent(for:word) else {return nil}
        if let digest=engines.modelDigests[ResearchModels.analysis],value.model != ResearchModels.analysis+"@"+digest {return nil}
        return value
    }
    func showWordDetails(_ word:Vocabulary,force:Bool=false) {
        let previous=wordExplanationTask
        previous?.cancel()
        expandedWordID=word.id;wordExplanationError=nil;wordExplanationManuallyPaused=false
        let token=UUID();wordExplanationRequest=token
        wordExplanationMessage=explanation(for:word) == nil ? "等待空闲，准备语境讲解…" : "已保存在本机"
        wordExplanationTask=Task { [weak self] in
            // Finish cancellation/unloading before the next word can load a model.
            if let previous {await previous.value}
            guard let self else {return}
            await self.runWordExplanation(word,token:token,force:force)
        }
    }
    func toggleWordDetails(_ word:Vocabulary) {
        if expandedWordID == word.id {expandedWordID=nil;cancelWordExplanation()}
        else {showWordDetails(word)}
    }
    func cancelWordExplanation() {wordExplanationTask?.cancel()}
    func pauseWordExplanation() {wordExplanationManuallyPaused=true;cancelWordExplanation()}
    func yieldWordExplanation() async {
        let pending=wordExplanationTask
        pending?.cancel()
        if let pending {await pending.value}
    }
    func resumeWordExplanationIfNeeded() {
        guard route == .vocabulary,wordExplanationTask == nil,wordExplanationError == nil,!shuttingDown,!wordExplanationManuallyPaused,
              let word=words.first(where:{$0.id == expandedWordID}),word.kind != "句子",explanation(for:word) == nil else {return}
        showWordDetails(word)
    }
    func focusVocabulary(_ visible:[Vocabulary]) {
        if let word=visible.first(where:{$0.id == expandedWordID}) {showWordDetails(word)}
        else if let word=visible.first {showWordDetails(word)}
        else {expandedWordID=nil;cancelWordExplanation()}
    }
    private var otherModelWork:Bool {
        translating || researchBusy || searching || audio.busy || audio.playing || audio.generating || engines.checking
    }
    private func runWordExplanation(_ word:Vocabulary,token:UUID,force:Bool) async {
        defer {if wordExplanationRequest == token {wordExplanationTask=nil;explainingWordID=nil}}
        guard !Task.isCancelled,route == .vocabulary,expandedWordID == word.id else {return}
        guard word.kind != "句子" else {wordExplanationMessage="整句保留原译文；语境讲解用于单词和短语。";return}
        if !force,explanation(for:word) != nil {return}
        var pausedSpeech=false,usedModel=false
        do {
            try await Task.sleep(for:.milliseconds(800))
            while otherModelWork {
                wordExplanationMessage="等待翻译、朗读或论文任务完成…"
                try await Task.sleep(for:.milliseconds(500))
            }
            try Task.checkCancellation()
            if !engines.analysisReady {await engines.check()}
            try Task.checkCancellation()
            guard engines.analysisReady else {throw AppError.message("词语讲解需要本地研究模型，请在设置中启动引擎并检查 Qwen3.6 是否已安装。")}
            allowEngineRestore=true
            explainingWordID=word.id;wordExplanationMessage="正在生成简短讲解；首次需要加载模型…"
            pausedSpeech=await engines.pauseSpeechForResearch(status:"词语讲解期间暂停，完成后恢复")
            let context=await resolvedWordContext(word)
            try Task.checkCancellation()
            let input=try WordExplanationInput(expression:word.text,context:context)
            usedModel=true
            let draft=try await researchClient.explainWord(input)
            try Task.checkCancellation()
            guard route == .vocabulary,expandedWordID == word.id,wordExplanationRequest == token else {throw CancellationError()}
            let signature=ResearchModels.analysis+"@"+(engines.modelDigests[ResearchModels.analysis] ?? "unknown")
            let value=try WordExplanation(word:word,context:context,model:signature,content:draft)
            try db?.saveWordExplanation(value)
            wordExplanations[word.id]=value
            wordExplanationMessage="已保存在本机"
        } catch {
            if wordExplanationRequest == token {
                if Task.isCancelled || error is CancellationError {wordExplanationMessage="已暂停；空闲时可继续生成"}
                else {wordExplanationError=error.localizedDescription;wordExplanationMessage="本次讲解未完成"}
            }
        }
        if usedModel {
            let client=researchClient
            // Cleanup survives cancellation and finishes before foreground work resumes.
            await Task.detached {await client.unload(ResearchModels.analysis)}.value
        }
        if pausedSpeech && !shuttingDown && allowEngineRestore {
            // A cancelled explanation must not pass its cancellation state into
            // health checks or startup of the speech service being restored.
            await Task.detached { @MainActor [weak self] in
                guard let self,!self.shuttingDown,self.allowEngineRestore else {return}
                await self.engines.start()
            }.value
        }
    }
    func resolvedWordContext(_ word:Vocabulary) async -> String {
        guard let paper=papers.first(where:{$0.id == word.paperID}) else {return word.context}
        let url=fileURL(paper)
        return await Task.detached(priority:.utility) {
            let source:String?
            if paper.kind == "PDF" {source=PDFDocument(url:url)?.page(at:word.page)?.string}
            else {source=try? String(contentsOf:url,encoding:.utf8)}
            guard let source,!source.isEmpty else {return word.context}
            return TextTools.context(in:source,selection:word.text,matching:word.context)
        }.value
    }
}
