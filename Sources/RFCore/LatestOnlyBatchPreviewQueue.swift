import Foundation

/// 批次預覽只保留一個執行中的要求與一個最新的待處理要求。
public actor LatestOnlyBatchPreviewQueue {
    public typealias Operation = @Sendable () async -> Void

    private struct Request {
        let generation: UInt64
        let operation: Operation
    }

    private var latestGeneration: UInt64 = 0
    private var pending: Request?
    private var activeTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?

    public init() {}

    /// 較新的要求會取代待處理要求，並取消目前工作。
    public func submit(generation: UInt64, operation: @escaping Operation) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        pending = Request(generation: generation, operation: operation)
        activeTask?.cancel()
        guard workerTask == nil else { return }
        workerTask = Task { await runPending() }
    }

    /// 取消目前工作並清空待處理要求；較舊的 submit 之後會被忽略。
    public func cancel(generation: UInt64) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        pending = nil
        activeTask?.cancel()
    }

    private func runPending() async {
        while let request = pending {
            pending = nil
            let task = Task { await request.operation() }
            activeTask = task
            await task.value
            activeTask = nil
        }
        workerTask = nil
    }
}
