import Foundation
import PaperCore

private struct PracticeRandom:RandomNumberGenerator {
    var state:UInt64
    mutating func next()->UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value=state
        value=(value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value=(value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

final class PracticeQueueTests {
    let now=Date(timeIntervalSince1970:1_700_000_000)
    func word(_ id:String)->Vocabulary {
        let fields:[String:Any]=["id":id,"text":id,"translation":"测试","kind":"单词","context":"A synthetic example.","paperID":"","paperTitle":"","page":0,"lookups":1,"lapses":0,"stage":3,"due":now.timeIntervalSinceReferenceDate,"created":now.timeIntervalSinceReferenceDate,"lastSeen":now.timeIntervalSinceReferenceDate]
        return try! JSONDecoder().decode(Vocabulary.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    func testEligibilityUniquenessAndCap() {
        let due=(0..<60).map{word("word-\($0)")}
        var future=word("future");future.due=now.addingTimeInterval(1)
        let input=due+[future]
        var random=PracticeRandom(state:1)
        let sample=Scheduler.practiceQueue(input,at:now,using:&random)
        XCTAssertEqual(sample.count,20)
        XCTAssertEqual(Set(sample.map(\.id)).count,20)
        XCTAssertTrue(sample.allSatisfy{$0.due <= now && input.contains($0)})
        XCTAssertEqual(Set(Scheduler.practiceQueue(input,at:now,limit:Int.max,using:&random).map(\.id)),Set(due.map(\.id)))
        XCTAssertTrue(Scheduler.practiceQueue(input,at:now,limit:0,using:&random).isEmpty)
        XCTAssertTrue(Scheduler.practiceQueue(input,at:now,limit:-1,using:&random).isEmpty)
        XCTAssertTrue(Scheduler.practiceQueue([future],at:now,using:&random).isEmpty)
        XCTAssertEqual(Scheduler.practiceQueue([due[0]],at:now,using:&random),[due[0]])
    }
    func testVariedSamplingAndPreviousOrder() {
        let words=(0..<60).map{word("word-\($0)")}
        var random=PracticeRandom(state:42),same=PracticeRandom(state:42),different=PracticeRandom(state:73)
        let first=Scheduler.practiceQueue(words,at:now,using:&random).map(\.id)
        XCTAssertEqual(Scheduler.practiceQueue(words,at:now,using:&same).map(\.id),first)
        XCTAssertTrue(Scheduler.practiceQueue(words,at:now,using:&different).map(\.id) != first)
        var seen=Set<String>()
        for _ in 0..<50 {seen.formUnion(Scheduler.practiceQueue(words,at:now,using:&random).map(\.id))}
        XCTAssertEqual(seen,Set(words.map(\.id)))
        let small=Array(words.prefix(3))
        var original=PracticeRandom(state:9),repeated=PracticeRandom(state:9)
        let previous=Scheduler.practiceQueue(small,at:now,using:&original).map(\.id)
        let next=Scheduler.practiceQueue(small,at:now,avoiding:previous,using:&repeated).map(\.id)
        XCTAssertTrue(next != previous)
        XCTAssertEqual(Set(next),Set(previous))
    }
    func testUnfamiliarCardsHaveHigherSamplingProbability() {
        let familiar=word("familiar")
        var forgotten=word("forgotten");forgotten.lapses=4
        var lookedUp=word("looked-up");lookedUp.lookups=31
        var learning=word("learning");learning.stage=0
        var overdue=word("overdue");overdue.due=now.addingTimeInterval(-10*86400)
        var random=PracticeRandom(state:20261027)
        for difficult in [forgotten,lookedUp,learning,overdue] {
            var difficultCount=0
            for _ in 0..<4000 {
                if Scheduler.practiceQueue([familiar,difficult],at:now,limit:1,using:&random).first?.id == difficult.id {difficultCount+=1}
            }
            XCTAssertTrue(difficultCount > 2400 && difficultCount < 3950)
        }
        XCTAssertEqual(Scheduler.queue([familiar,forgotten],at:now).first?.id,forgotten.id)
    }
}
