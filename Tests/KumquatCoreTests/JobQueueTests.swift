import XCTest
@testable import KumquatCore

final class JobQueueTests: XCTestCase {
    func items(_ count: Int, job: Int = 1) -> [QueueItem] {
        (0..<count).map { QueueItem(job: job, title: "file\($0)", input: URL(fileURLWithPath: "/tmp/file\($0).png")) }
    }

    func testStartsInOrderUpToTheLimit() {
        var queue = JobQueue(maxRunning: 2)
        let added = items(4)
        queue.add(added)
        XCTAssertEqual(queue.nextToStart(), [added[0].id, added[1].id])
        queue.nextToStart().forEach { queue.markRunning($0) }
        XCTAssertEqual(queue.nextToStart(), [], "both slots busy")
        queue.finish(added[0].id, outputs: [URL(fileURLWithPath: "/tmp/out0.jpg")])
        XCTAssertEqual(queue.nextToStart(), [added[2].id])
        XCTAssertEqual(JobQueue(maxRunning: 0).maxRunning, 1)
    }

    func testPauseStopsNewStartsOnly() {
        var queue = JobQueue(maxRunning: 1)
        let added = items(2)
        queue.add(added)
        queue.markRunning(added[0].id)
        queue.isPaused = true
        queue.finish(added[0].id, outputs: [])
        XCTAssertEqual(queue.nextToStart(), [], "paused")
        XCTAssertEqual(queue.item(added[0].id)?.state, .done, "the running item finished")
        queue.isPaused = false
        XCTAssertEqual(queue.nextToStart(), [added[1].id])
    }

    func testReorderChangesWhatStartsNext() {
        var queue = JobQueue(maxRunning: 1)
        let added = items(4)
        queue.add(added)
        queue.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.title), ["file3", "file0", "file1", "file2"])
        XCTAssertEqual(queue.nextToStart(), [added[3].id])
        queue.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        XCTAssertEqual(queue.items.map(\.title), ["file1", "file2", "file3", "file0"])

        queue.markRunning(added[1].id)
        queue.moveToFront(added[0].id)
        XCTAssertEqual(queue.items.map(\.title), ["file1", "file0", "file2", "file3"], "ahead of other waiting items")
        queue.moveToFront(added[1].id)
        XCTAssertEqual(queue.items.map(\.title), ["file1", "file0", "file2", "file3"], "running items don't move")
    }

    func testProgressOnlyMovesForwardWhileRunning() {
        var queue = JobQueue()
        let item = items(1)[0]
        queue.add([item])
        queue.setProgress(item.id, 0.5)
        XCTAssertEqual(queue.item(item.id)?.progress, 0, "not running yet")
        queue.markRunning(item.id)
        queue.setProgress(item.id, 0.6)
        queue.setProgress(item.id, 0.3)
        queue.setProgress(item.id, 7)
        XCTAssertEqual(queue.item(item.id)?.progress, 1)
        XCTAssertEqual(queue.overallProgress, 1)
        queue.finish(item.id, outputs: [])
        XCTAssertNil(queue.overallProgress, "idle")
    }

    func testFailureRetryAndCancel() {
        var queue = JobQueue(maxRunning: 3)
        let added = items(3)
        queue.add(added)
        queue.nextToStart().forEach { queue.markRunning($0) }
        queue.fail(added[0].id, "Unsupported")
        XCTAssertTrue(queue.cancel(added[1].id), "was running")
        queue.finish(added[1].id, outputs: [URL(fileURLWithPath: "/tmp/late")])
        XCTAssertEqual(queue.item(added[1].id)?.state, .cancelled, "a cancelled item's late result is ignored")
        queue.finish(added[2].id, outputs: [URL(fileURLWithPath: "/tmp/ok")], message: "Saved 10%")
        XCTAssertTrue(queue.isFinished(job: 1))
        let results = queue.results(job: 1)
        XCTAssertEqual(results.outputs, [URL(fileURLWithPath: "/tmp/ok")])
        XCTAssertEqual(results.failures, ["file0.png: Unsupported"])
        XCTAssertEqual(results.messages, ["Saved 10%"])
        XCTAssertEqual(results.cancelled, 1)
        XCTAssertEqual(queue.failed.map(\.id), [added[0].id])

        XCTAssertFalse(queue.retry(added[2].id, job: 2), "done items aren't retried")
        XCTAssertTrue(queue.retry(added[0].id, job: 2))
        XCTAssertTrue(queue.retry(added[1].id, job: 2))
        XCTAssertEqual(queue.item(added[0].id)?.state, .waiting)
        XCTAssertFalse(queue.isFinished(job: 2))
        XCTAssertTrue(queue.isFinished(job: 1), "the original job keeps only what finished")
        XCTAssertEqual(queue.nextToStart(), [added[0].id, added[1].id])

        XCTAssertEqual(queue.cancel(job: 2), [], "nothing running yet")
        XCTAssertTrue(queue.isFinished(job: 2))
        XCTAssertFalse(queue.cancel(added[2].id), "finished items stay as they are")
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testCancelJobReturnsRunningItems() {
        var queue = JobQueue(maxRunning: 1)
        let first = items(2, job: 1), second = items(1, job: 2)
        queue.add(first + second)
        queue.markRunning(first[0].id)
        XCTAssertEqual(queue.cancel(job: 1), [first[0].id])
        XCTAssertEqual(queue.item(first[1].id)?.state, .cancelled)
        XCTAssertEqual(queue.item(second[0].id)?.state, .waiting, "other jobs untouched")
        XCTAssertEqual(queue.results(job: 1).failures, [])
    }

    func testSingleItemFailureKeepsThePlainMessage() {
        var queue = JobQueue()
        let item = items(1)[0]
        queue.add([item])
        queue.markRunning(item.id)
        queue.fail(item.id, "Disk full")
        XCTAssertEqual(queue.results(job: 1).failures, ["Disk full"])
    }
}
