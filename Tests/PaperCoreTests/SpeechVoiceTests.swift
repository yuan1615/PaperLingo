import Foundation
import PaperCore

final class SpeechVoiceTests {
    func fixture(_ directory:URL) throws -> [[String:String]] {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return try ["001","002"].map { id in
            let data=Data(("synthetic audio "+id).utf8)
            try data.write(to:directory.appendingPathComponent(id+".wav"))
            return ["id":id,"label":"Fixture "+id,"file":id+".wav","text":"Synthetic reference.","sha256":ResearchText.hash(String(decoding:data,as:UTF8.self))]
        }
    }
    func write(_ voices:[[String:String]],to directory:URL) throws {
        try JSONSerialization.data(withJSONObject:["version":1,"voices":voices],options:.sortedKeys).write(to:directory.appendingPathComponent("manifest.json"))
    }
    func testCatalogRandomizationAndSessionSelection() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        try write(fixture(directory),to:directory)
        let catalog=try SpeechVoiceCatalog(directory:directory)
        XCTAssertEqual(catalog.voices.count,2)
        XCTAssertEqual(catalog.randomVoice(avoiding:"001").id,"002")
        XCTAssertEqual(catalog.randomVoice(avoiding:"002").id,"001")
        XCTAssertTrue(catalog.voices.contains(catalog.randomVoice()))
        let raw=try String(contentsOf:directory.appendingPathComponent("manifest.json"),encoding:.utf8)
        XCTAssertEqual(catalog.signature,ResearchText.hash(raw))
        try write([fixture(directory)[0]],to:directory)
        XCTAssertEqual(try SpeechVoiceCatalog(directory:directory).randomVoice(avoiding:"001").id,"001")
    }
    func testRejectChangedAudioAndOutwardSymlinks() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory);try? FileManager.default.removeItem(at:outside)}
        let entries=try fixture(directory);try write(entries,to:directory)
        try Data("changed".utf8).write(to:directory.appendingPathComponent("001.wav"))
        do {_=try SpeechVoiceCatalog(directory:directory);fail("Changed audio accepted")} catch {}
        try write(fixture(directory),to:directory)
        try FileManager.default.moveItem(at:directory.appendingPathComponent("001.wav"),to:outside)
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("001.wav"),withDestinationURL:outside)
        do {_=try SpeechVoiceCatalog(directory:directory);fail("Outward audio symlink accepted")} catch {}
    }
    func testRejectAmbiguousOrMissingReferenceText() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        var entries=try fixture(directory)
        try write([entries[0],entries[0]],to:directory)
        do {_=try SpeechVoiceCatalog(directory:directory);fail("Duplicate voice accepted")} catch {}
        entries[0]["file"]="../001.wav";try write(entries,to:directory)
        do {_=try SpeechVoiceCatalog(directory:directory);fail("Outward path accepted")} catch {}
        entries=try fixture(directory);entries[0]["text"]=" \n ";try write(entries,to:directory)
        do {_=try SpeechVoiceCatalog(directory:directory);fail("Empty transcript accepted")} catch {}
    }
}
