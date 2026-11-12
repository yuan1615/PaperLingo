import Foundation
import PaperCore

final class ReadingTextTests {
    func testPaperLineWrapsAndCompounds() {
        let raw="An experi-\r\nmental efﬁcient sys\u{00ad}\ntem uses state-\nof-the-art, zero-\nshot and data-\ndriven methods with 32-\nbit DNA-\nBased inputs."
        let expected="An experimental efficient system uses state-of-the-art, zero-shot and data-driven methods with 32-bit DNA-Based inputs."
        XCTAssertEqual(TextTools.clean(raw),expected)
        XCTAssertEqual(TextTools.clean(expected),expected)
        XCTAssertEqual(TextTools.clean("A soft\u{00ad}hyphen and zero\u{200b}width mark."),"A softhyphen and zerowidth mark.")
        XCTAssertEqual(TextTools.clean("First\\n Second\\r\\nThird."),"First Second Third.")
        XCTAssertEqual(TextTools.clean(#"Use \nabla in the equation."#),#"Use \nabla in the equation."#)
        XCTAssertEqual(TextTools.clean("BERT-\nlarge and RNA-\nseq."),"BERT-large and RNA-seq.")
    }
    func testSelectionMappingAcrossLayoutRepairs() {
        let sentence="The 🧠 efﬁcient experi-\nmental system\nuses state-\nof-the-art inputs [2]."
        let text="Prior sentence. "+sentence+" Another sentence."
        let expected="The 🧠 efficient experimental system uses state-of-the-art inputs [2]."
        for selection in ["efﬁcient","mental","system","of-the-art","[2]"] {
            XCTAssertEqual(TextTools.context(in:text,range:(text as NSString).range(of:selection)),expected)
        }
        XCTAssertEqual(TextTools.context(in:text,selection:"experimental"),expected)
        XCTAssertEqual(TextTools.context(in:text,selection:"state-of-the-art"),expected)
    }
    func testSpeechOmitsCitationsAndRedundantInitialisms() {
        let raw="Large language models (LLMs) improve [2, 4–6]. Text-to-speech (TTS) and reinforcement learning from human feedback (RLHF) help.\nThe experi-\nmental result [12] is stable."
        let expected="Large language models improve. Text-to-speech and reinforcement learning from human feedback help. The experimental result is stable."
        XCTAssertEqual(SpeechText.prepare(raw),expected)
        XCTAssertEqual(SpeechText.prepare(expected),expected)
        XCTAssertTrue(raw.contains("(LLMs)") && raw.contains("[12]"))
        XCTAssertEqual(SpeechText.prepare("[2]"),"")
        let mixed="Chain-of-thought (CoT), low-rank adaptation (LoRA), rotary position embedding (RoPE) and variational autoencoder (VAE) help."
        XCTAssertEqual(SpeechText.prepare(mixed),"Chain-of-thought, low-rank adaptation, rotary position embedding and variational autoencoder help.")
    }
    func testSpeechRetainsConditionsFormulasAndStandaloneTerms() {
        let text="We use CNN (n = 32, p < 0.05), [CLS] tokens and values in [0, 1]. Keep (training only), (GPT-4), (ASR) and (Eq. 2)."
        XCTAssertEqual(SpeechText.prepare(text),text)
        XCTAssertEqual(SpeechText.prepare("(TTS)"),"(TTS)")
        XCTAssertEqual(SpeechText.prepare("Accuracy is 3.14% (±0.2%)."),"Accuracy is 3.14% (±0.2%).")
        let math="Keep x[2], x = [2], vector [1, 2] and values in [1, 2]."
        XCTAssertEqual(SpeechText.prepare(math),math)
    }
    func testNewVocabularyNormalizesLayoutWithoutRemovingEvidence() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let db=try Database(url:dir.appendingPathComponent("test.sqlite"))
        try db.record(text:"experi-\nmental",translation:"实验的",context:"An experi-\nmental system (ES) improves [2].",paper:nil,page:0)
        let word=try db.vocabulary()[0]
        XCTAssertEqual(word.text,"experimental")
        XCTAssertEqual(word.context,"An experimental system (ES) improves [2].")
        XCTAssertEqual(word.lookups,1)
        XCTAssertEqual(word.lapses,0)
        XCTAssertEqual(SpeechText.prepare(word.context),"An experimental system improves.")
    }
}
