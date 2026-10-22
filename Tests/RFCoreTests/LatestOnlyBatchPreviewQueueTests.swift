import XCTest
@testable import RFCore

final class LatestOnlyBatchPreviewQueueTests: XCTestCase {
    func testThirtyRequestsRunOnlyActiveAndLatestPendingWork() async {
        let queue = LatestOnlyBatchPreviewQueue()
        let probe = PreviewQueueProbe()
        defer { Task { await probe.releaseFirst() } }
        await queue.submit(generation: 1) {
            await probe.run(0, holdUntilReleased: true)
        }
        let firstStarts = await probe.waitForStartedCount(1)
        XCTAssertEqual(firstStarts, [0], "the first preview should start within five seconds")

        for identifier in 1...29 {
            await queue.submit(generation: UInt64(identifier + 1)) {
                await probe.run(identifier)
            }
        }
        await probe.releaseFirst()

        let starts = await probe.waitForStartedCount(2)
        XCTAssertEqual(starts, [0, 29], "a 30-request burst should keep only the active and latest work")
        let completed = await probe.waitForCompletedCount(2)
        XCTAssertEqual(completed, [0, 29], "both retained operations should finish within five seconds")
    }

    func testCancelClearsPendingCancelsActiveAndAllowsANewerRequest() async {
        let queue = LatestOnlyBatchPreviewQueue()
        let probe = PreviewQueueProbe()
        defer { Task { await probe.releaseFirst() } }
        await queue.submit(generation: 1) {
            await probe.run(10, holdUntilReleased: true)
        }
        let started = await probe.waitForStartedCount(1)
        XCTAssertEqual(started, [10], "the active preview should start within five seconds")

        await queue.submit(generation: 2) { await probe.run(11) }
        await queue.cancel(generation: 3)
        let cancelled = await probe.waitForCancelledCount(1)
        XCTAssertEqual(cancelled, [10], "cancel should reach the active operation within five seconds")
        await probe.releaseFirst()
        let completed = await probe.waitForCompletedCount(1)
        XCTAssertEqual(completed, [10], "cancel must drop the pending request")

        await queue.cancel(generation: 4)
        await queue.submit(generation: 3) { await probe.run(12) }
        await queue.submit(generation: 5) { await probe.run(13) }
        let startsAfterResubmit = await probe.waitForStartedCount(2)
        XCTAssertEqual(startsAfterResubmit, [10, 13],
                       "a stale submit is ignored and a newer request runs after an idle cancel")
    }

    func testCancelWithoutActiveWorkAcceptsOnlyANewerRequest() async {
        let queue = LatestOnlyBatchPreviewQueue()
        let probe = PreviewQueueProbe()

        await queue.cancel(generation: 4)
        await queue.submit(generation: 3) { await probe.run(3) }
        await queue.submit(generation: 5) { await probe.run(5) }

        let started = await probe.waitForStartedCount(1)
        XCTAssertEqual(started, [5], "a newer request must run after cancellation while idle")
        let completed = await probe.waitForCompletedCount(1)
        XCTAssertEqual(completed, [5])
    }
}

private actor PreviewQueueProbe {
    private struct Waiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<[Int]?, Never>
    }

    private var started: [Int] = []
    private var completed: [Int] = []
    private var cancelled: [Int] = []
    private var startWaiters: [Waiter] = []
    private var completionWaiters: [Waiter] = []
    private var cancellationWaiters: [Waiter] = []
    private var firstGate: CheckedContinuation<Void, Never>?

    func run(_ identifier: Int, holdUntilReleased: Bool = false) async {
        started.append(identifier)
        resumeReady(&startWaiters, with: started)
        if holdUntilReleased {
            await withTaskCancellationHandler {
                await withCheckedContinuation { firstGate = $0 }
            } onCancel: {
                Task { await self.recordCancellation(identifier) }
            }
        }
        completed.append(identifier)
        resumeReady(&completionWaiters, with: completed)
    }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }

    func waitForStartedCount(_ count: Int) async -> [Int]? {
        if started.count >= count { return started }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            startWaiters.append(Waiter(id: id, count: count, continuation: continuation))
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.timeoutWaiter(id)
            }
        }
    }

    func waitForCompletedCount(_ count: Int) async -> [Int]? {
        if completed.count >= count { return completed }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            completionWaiters.append(Waiter(id: id, count: count, continuation: continuation))
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.timeoutWaiter(id)
            }
        }
    }

    func waitForCancelledCount(_ count: Int) async -> [Int]? {
        if cancelled.count >= count { return cancelled }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            cancellationWaiters.append(Waiter(id: id, count: count, continuation: continuation))
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.timeoutWaiter(id)
            }
        }
    }

    private func recordCancellation(_ identifier: Int) {
        cancelled.append(identifier)
        resumeReady(&cancellationWaiters, with: cancelled)
    }

    private func timeoutWaiter(_ id: UUID) {
        if let index = startWaiters.firstIndex(where: { $0.id == id }) {
            startWaiters.remove(at: index).continuation.resume(returning: nil)
        } else if let index = completionWaiters.firstIndex(where: { $0.id == id }) {
            completionWaiters.remove(at: index).continuation.resume(returning: nil)
        } else if let index = cancellationWaiters.firstIndex(where: { $0.id == id }) {
            cancellationWaiters.remove(at: index).continuation.resume(returning: nil)
        }
    }

    private func resumeReady(_ waiters: inout [Waiter], with values: [Int]) {
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        for waiter in ready { waiter.continuation.resume(returning: values) }
    }
}
