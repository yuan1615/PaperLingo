import Foundation
import PDFKit
import PaperCore

struct WordExplanationBatch {
    var pending:[String]
    let total:Int
    var completed=0
    var failed=0
    var skipped=0
    var isRunning=true
    var message="准备批量生成…"
    var lastFailure=""
    var processed:Int {completed+failed+skipped}
}

extension AppStore {
    var unexplainedWords:[Vocabulary] {
        words.filter{$0.kind != "句子" && explanation(for:$0) == nil}.sorted {
            $0.lookups == $1.lookups ? $0.lastSeen > $1.lastSeen : $0.lookups > $1.lookups
        }
    }
    var batchingWordExplanations:Bool {wordExplanationBatch?.isRunning == true}
    func explanation(for word:Vocabulary) -> WordExplanation? {
        guard let value=wordExplanations[word.id],value.isCurrent(for:word) else {return nil}
        if let digest=engines.modelDigests[ResearchModels.analysis],value.model != ResearchModels.analysis+"@"+digest {return nil}
        return value
    }
    func showWordDetails(_ word:Vocabulary,force:Bool=false) {
        // Browsing and filtering must not replace a batch with a single-word request.
        if batchingWordExplanations {expandedWordID=word.id;return}
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
        if expandedWordID == word.id {expandedWordID=nil;if !batchingWordExplanations {cancelWordExplanation()}}
        else {showWordDetails(word)}
    }
    func cancelWordExplanation() {
        wordExplanationTask?.cancel()
        if batchingWordExplanations {
            wordExplanationBatch?.isRunning=false
            wordExplanationBatch?.message="已停止，已生成的讲解已保留"
            wordExplanationMessage="批量已停止，可再次补全尚未生成的讲解。"
            wordExplanationManuallyPaused=true
        }
    }
    func pauseWordExplanation() {wordExplanationManuallyPaused=true;cancelWordExplanation()}
    func yieldWordExplanation() async {
        let pending=wordExplanationTask
        pending?.cancel()
        if let pending {await pending.value}
        // Foreground work sets its busy flag before yielding. The resumed worker
        // waits without loading a model until that work has finished.
        if batchingWordExplanations {resumeWordExplanationIfNeeded()}
    }
    func resumeWordExplanationIfNeeded() {
        guard route == .vocabulary,wordExplanationTask == nil,!shuttingDown,!wordExplanationManuallyPaused else {return}
        if batchingWordExplanations {launchWordExplanationBatch();return}
        guard wordExplanationError == nil,let word=words.first(where:{$0.id == expandedWordID}),word.kind != "句子",explanation(for:word) == nil else {return}
        showWordDetails(word)
    }
    func focusVocabulary(_ visible:[Vocabulary]) {
        if let word=visible.first(where:{$0.id == expandedWordID}) {showWordDetails(word)}
        else if let word=visible.first {showWordDetails(word)}
        else {expandedWordID=nil;if !batchingWordExplanations {cancelWordExplanation()}}
    }
    func startWordExplanationBatch() {
        guard route == .vocabulary,!batchingWordExplanations,!shuttingDown else {return}
        let pending=unexplainedWords.map(\.id)
        guard !pending.isEmpty else {return}
        let previous=wordExplanationTask
        previous?.cancel()
        wordExplanationBatch=WordExplanationBatch(pending:pending,total:pending.count)
        wordExplanationError=nil;wordExplanationManuallyPaused=false
        wordExplanationMessage="尚无有效讲解，可在批量结束后单独生成。"
        launchWordExplanationBatch(after:previous)
    }
    private func launchWordExplanationBatch(after previous:Task<Void,Never>?=nil) {
        let token=UUID();wordExplanationRequest=token
        wordExplanationTask=Task { [weak self] in
            if let previous {await previous.value}
            guard let self else {return}
            await self.runWordExplanationBatch(token:token)
        }
    }
    private var otherModelWork:Bool {
        translating || researchBusy || searching || audio.busy || audio.playing || audio.generating || engines.checking
    }
    private func waitForWordExplanationSlot(batch:Bool=false) async throws {
        while otherModelWork {
            if batch {wordExplanationBatch?.message="等待翻译、朗读或论文任务完成…"}
            else {wordExplanationMessage="等待翻译、朗读或论文任务完成…"}
            try await Task.sleep(for:.milliseconds(500))
        }
        try Task.checkCancellation()
    }
    private func saveWordExplanation(_ draft:WordExplanationDraft,word:Vocabulary,context:String) throws {
        guard let db else {throw AppError.message("数据库未打开，讲解未保存。")}
        let signature=ResearchModels.analysis+"@"+(engines.modelDigests[ResearchModels.analysis] ?? "unknown")
        let value=try WordExplanation(word:word,context:context,model:signature,content:draft)
        try db.saveWordExplanation(value)
        wordExplanations[word.id]=value
    }
    private func finishWordExplanationSession(usedModel:Bool,pausedSpeech:Bool) async {
        if usedModel {
            let client=researchClient
            // Cleanup survives cancellation and finishes before foreground work resumes.
            await Task.detached {await client.unload(ResearchModels.analysis)}.value
        }
        if pausedSpeech && !shuttingDown && allowEngineRestore {
            await Task.detached { @MainActor [weak self] in
                guard let self,!self.shuttingDown,self.allowEngineRestore else {return}
                await self.engines.start()
            }.value
        }
    }
    private func runWordExplanationBatch(token:UUID) async {
        defer {if wordExplanationRequest == token {wordExplanationTask=nil;explainingWordID=nil}}
        var pausedSpeech=false,usedModel=false,prepared=false
        do {
            while let id=wordExplanationBatch?.pending.first {
                try Task.checkCancellation()
                guard route == .vocabulary,batchingWordExplanations,wordExplanationRequest == token else {throw CancellationError()}
                try await waitForWordExplanationSlot(batch:true)
                guard let word=words.first(where:{$0.id == id}),word.kind != "句子",explanation(for:word) == nil else {
                    wordExplanationBatch?.pending.removeFirst();wordExplanationBatch?.skipped += 1
                    continue
                }
                if !prepared {
                    if !engines.analysisReady {await engines.check()}
                    try Task.checkCancellation()
                    guard engines.analysisReady else {throw AppError.message("请在设置中启动引擎并检查 Qwen3.6 是否已安装，再重新开始批量处理。")}
                    try await waitForWordExplanationSlot(batch:true)
                    allowEngineRestore=true
                    pausedSpeech=await engines.pauseSpeechForResearch(status:"批量词语讲解期间暂停，结束后恢复")
                    prepared=true
                }
                explainingWordID=word.id
                wordExplanationBatch?.message="正在处理：\(word.text)"
                do {
                    let context=await resolvedWordContext(word)
                    try Task.checkCancellation()
                    let input=try WordExplanationInput(expression:word.text,context:context)
                    usedModel=true
                    let draft=try await researchClient.explainWord(input,keepAliveSeconds:60)
                    try Task.checkCancellation()
                    guard batchingWordExplanations,wordExplanationRequest == token else {throw CancellationError()}
                    try saveWordExplanation(draft,word:word,context:context)
                    wordExplanationBatch?.pending.removeFirst();wordExplanationBatch?.completed += 1
                } catch {
                    if Task.isCancelled || error is CancellationError {throw CancellationError()}
                    wordExplanationBatch?.pending.removeFirst();wordExplanationBatch?.failed += 1
                    wordExplanationBatch?.lastFailure="\(word.text)：\(error.localizedDescription)"
                }
            }
            try Task.checkCancellation()
            wordExplanationBatch?.isRunning=false
            wordExplanationBatch?.message="批量处理完成"
            wordExplanationMessage="批量处理结束，尚未生成的词条可重试。"
            wordExplanationManuallyPaused=true
        } catch {
            if wordExplanationRequest == token,!Task.isCancelled,!(error is CancellationError) {
                wordExplanationBatch?.isRunning=false
                wordExplanationBatch?.message=error.localizedDescription
                wordExplanationMessage=error.localizedDescription
                wordExplanationManuallyPaused=true
            }
        }
        await finishWordExplanationSession(usedModel:usedModel,pausedSpeech:pausedSpeech)
    }
    private func runWordExplanation(_ word:Vocabulary,token:UUID,force:Bool) async {
        defer {if wordExplanationRequest == token {wordExplanationTask=nil;explainingWordID=nil}}
        guard !Task.isCancelled,route == .vocabulary,expandedWordID == word.id else {return}
        guard word.kind != "句子" else {wordExplanationMessage="整句保留原译文；语境讲解用于单词和短语。";return}
        if !force,explanation(for:word) != nil {return}
        var pausedSpeech=false,usedModel=false
        do {
            try await Task.sleep(for:.milliseconds(800))
            try await waitForWordExplanationSlot()
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
            try saveWordExplanation(draft,word:word,context:context)
            wordExplanationMessage="已保存在本机"
        } catch {
            if wordExplanationRequest == token {
                if Task.isCancelled || error is CancellationError {wordExplanationMessage="已暂停；空闲时可继续生成"}
                else {wordExplanationError=error.localizedDescription;wordExplanationMessage="本次讲解未完成"}
            }
        }
        await finishWordExplanationSession(usedModel:usedModel,pausedSpeech:pausedSpeech)
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
