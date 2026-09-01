import XCTest
@testable import JarvisKit

final class FramesTests: XCTestCase {

    func testChunkAndAssembleRoundTrip() {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        let frames = Frames.chunks(tag: Frames.tagFileRes,
                                   meta: ["reqId": "r1", "sid": 3, "status": 200],
                                   body: body)
        XCTAssertEqual(frames.count, 4)
        let assembler = Frames.Assembler()
        var whole: Frames.Whole?
        for frame in frames { whole = assembler.accept(frame) ?? whole }
        XCTAssertEqual(whole?.body, body)
        XCTAssertEqual(str(whole!.meta, "reqId"), "r1")
        XCTAssertEqual(int(whole!.meta, "status"), 200)
    }

    func testSequenceGapKillsStream() {
        let body = Data(count: 200_000)
        let frames = Frames.chunks(tag: Frames.tagWsBinary, meta: ["sid": 9], body: body)
        let assembler = Frames.Assembler()
        XCTAssertNil(assembler.accept(frames[0]))
        XCTAssertNil(assembler.accept(frames[2]))  // gap: stream dies
        XCTAssertNil(assembler.accept(frames[1]))  // and stays dead
        XCTAssertNil(assembler.accept(frames[3]))
    }

    func testEmptyBodyStillDelivers() {
        let frames = Frames.chunks(tag: Frames.tagFileReq,
                                   meta: ["op": "get", "sid": 1], body: Data())
        XCTAssertEqual(frames.count, 1)
        let whole = Frames.Assembler().accept(frames[0])
        XCTAssertEqual(whole?.body.count, 0)
        XCTAssertEqual(str(whole!.meta, "op"), "get")
    }

    func testEvictionAtSixteenOpenStreams() {
        let assembler = Frames.Assembler()
        let long = Data(count: 100_000)
        // Open 17 streams; the first must be evicted.
        for sid in 0..<17 {
            let frames = Frames.chunks(tag: Frames.tagWsBinary, meta: ["sid": sid],
                                       body: long)
            XCTAssertNil(assembler.accept(frames[0]))
        }
        let first = Frames.chunks(tag: Frames.tagWsBinary, meta: ["sid": 0], body: long)
        XCTAssertNil(assembler.accept(first[1]))  // evicted: mid-stream frame dies
        let seventeenth = Frames.chunks(tag: Frames.tagWsBinary, meta: ["sid": 16],
                                        body: long)
        XCTAssertNotNil(assembler.accept(seventeenth[1]))  // survivor completes
    }

    func testGarbageRefused() {
        XCTAssertNil(Frames.decode(Data()))
        XCTAssertNil(Frames.decode(Data([0x09, 0, 0, 0, 1, 0x7b])))
        XCTAssertNil(Frames.decode(Data([0x01, 0xff, 0xff, 0xff, 0xff])))
        XCTAssertNil(Frames.Assembler().accept(Data("not a frame".utf8)))
    }

    func testArtifactParsing() {
        let artifacts: [String: Any] = ["files": [
            ["id": "f1", "name": "Report.pdf", "bytes": 51_600],
            ["path": "/tmp/photo.png"],
            ["bytes": 12],  // nameless: dropped
        ]]
        let refs = artifactFiles(artifacts)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].name, "Report.pdf")
        XCTAssertEqual(refs[0].id, "f1")
        XCTAssertEqual(refs[1].name, "photo.png")
        XCTAssertNil(refs[1].id)
    }

    func testMsgDropsNilFields() {
        let payload = msg("intent", ["text": "hi", "conversation": nil])
        XCTAssertEqual(payload["type"] as? String, "intent")
        XCTAssertEqual(payload["text"] as? String, "hi")
        XCTAssertFalse(payload.keys.contains("conversation"))
    }
}
