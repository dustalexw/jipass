import XCTest
@testable import Jipass

final class TestAudio:AudioPlayback {
    var volume:Float=0
    var duration:TimeInterval=5
    var currentTime:TimeInterval=0
    var isPlaying=false
    func prepareToPlay()->Bool {true}
    func play()->Bool {isPlaying=true;return true}
    func pause(){isPlaying=false}
    func stop(){isPlaying=false}
}
@MainActor final class GameTests: XCTestCase {
    func testNativeRoundPlaybackSubmissionAndPersistence() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("tone.wav")
        XCTAssertEqual(try Media.run("ffmpeg",["-v","error","-f","lavfi","-i","sine=frequency=440:duration=6","-y",input.path]).status,0)
        let base=try Media.probe(input,source:"nas")
        let model=GameModel(directory:root,audioFactory:{_ in TestAudio()})
        // Distinct local files and labels, so round uniqueness is meaningful.
        model.state.tracks=try (0..<6).map { i in
            let url=root.appendingPathComponent("song-\(i).wav");try FileManager.default.copyItem(at:input,to:url)
            var track=base;track.path=url.path;track.title="Song \(i)";track.artist="Artist \(i)";return track
        }
        model.state.profiles=[Profile(id:"test",name:"Listener")];model.state.selectedProfile="test"
        model.length=5;model.seconds=5;model.mode = .mixed;model.startRound()
        var paths=Set<String>(),kinds=[QuestionKind]()
        for index in 0..<5 {
            for _ in 0..<100 where !model.active && model.error == nil {try await Task.sleep(nanoseconds:50_000_000)}
            XCTAssertNil(model.error);XCTAssertTrue(model.active);XCTAssertEqual(model.options.count,4)
            XCTAssertNil(model.feedback);XCTAssertNil(model.artwork)
            let id=try XCTUnwrap(model.options.first?.id);model.answer(id);model.answer(id)
            XCTAssertEqual(model.results.count,index+1);XCTAssertFalse(model.active)
            let result=try XCTUnwrap(model.feedback);XCTAssertTrue(paths.insert(result.track.path).inserted);kinds.append(result.kind)
            XCTAssertEqual(result.points,Rules.score(correct:result.correct,elapsed:result.elapsed,limit:5))
            model.next()
        }
        XCTAssertEqual(model.page,.results);XCTAssertEqual(model.completed?.results.count,5)
        XCTAssertTrue(zip(kinds,kinds.dropFirst()).allSatisfy{$0 != $1})
        let saved=try NativeStorage(directory:root).load();XCTAssertEqual(saved.history.count,1);XCTAssertEqual(saved.history[0].results.count,5)
        model.leave()
    }
    func testNoQuestionsForTooSmallCategory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let model=GameModel(directory:root);model.startRound()
        XCTAssertNotNil(model.error);XCTAssertEqual(model.page,.play);XCTAssertTrue(model.options.isEmpty)
    }
    func testRemoveOverlappingFolderRetainsSharedMusic() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let model=GameModel(directory:root)
        let track=Track(path:"/music/album/song.mp3",source:"nas",size:1,modified:1,title:"Song",artist:"Artist",album:"Album",genre:"Rock",duration:60)
        model.state.tracks=[track];model.state.folders=[Folder(path:"/music"),Folder(path:"/music/album")];model.state.memberships=[track.path:["/music","/music/album"]]
        model.removeFolder(Folder(path:"/music"));XCTAssertEqual(model.state.tracks.count,1)
        model.removeFolder(Folder(path:"/music/album"));XCTAssertTrue(model.state.tracks.isEmpty)
    }
}
