import Foundation

/// 累积一条消息的 body。超过 `spillThreshold` 或共享活动预算不足时，已缓存内容连同后续字节一起写入磁盘。
/// 最多记录 `maxCapturedBytes` 字节；超出的部分，以及落盘失败之后的字节都不再记录，结果标记为截断。
/// 这只影响记录，不影响转发。
/// 只在单个 EventLoop 上使用，因此内部不加锁；`finish()` 之后不要再 `append`。
public final class BodyCapture: @unchecked Sendable {
    public static let spillThreshold = 1_048_576
    public static let defaultMaxCapturedBytes = 50 * 1_048_576

    private let directory: URL
    private let maxCapturedBytes: Int
    private let budget: BodyMemoryBudget?
    private let registry: HTTPBodyRegistry
    /// Identity of the spill file this capture created and still owns (until `finish()`).
    private var ownedID: HTTPBodyID?
    private var memory = Data()
    // 以下两个成员仅为测试可见（@testable），不属于公开接口。
    var file: (url: URL, handle: FileHandle)?
    private var fileSize = 0
    /// 达到上限或写盘失败之后不再记录：结果是被截断的前缀，而不是拼接出错位的内容。
    private(set) var isTruncated = false
    private var finished = false

    init(
        directory: URL, maxCapturedBytes: Int = BodyCapture.defaultMaxCapturedBytes,
        budget: BodyMemoryBudget? = nil, registry: HTTPBodyRegistry = HTTPBodyRegistry()
    ) {
        self.registry = registry
        self.directory = directory
        self.maxCapturedBytes = max(0, maxCapturedBytes)
        self.budget = budget
    }

    deinit {
        budget?.release(memory.count)
        // 没有走到 finish()（连接中途断开）：不留下孤儿文件。
        guard !finished, let file else { return }
        try? file.handle.close()
        abandonSpill()
    }

    private var capturedCount: Int { file == nil ? memory.count : fileSize }

    public func append(_ bytes: some Sequence<UInt8>) {
        guard !finished, !isTruncated else { return }
        var chunk = Data(bytes)
        guard !chunk.isEmpty else { return }

        let room = maxCapturedBytes - capturedCount
        if chunk.count > room {
            chunk = chunk.prefix(room)
            isTruncated = true
            guard !chunk.isEmpty else { return }
        }

        if file != nil {
            write(chunk)
        } else if memory.count + chunk.count > Self.spillThreshold || budget?.reserve(chunk.count) == false {
            if spill(buffered: memory) {
                releaseMemory()
                write(chunk)
            } else {
                // 不退回到无上限的内存，也不在后续每个分块上重试建文件。
                isTruncated = true
            }
        } else {
            memory.append(chunk)
        }
    }

    /// 消费并释放 capture 持有的缓冲；没有字节或再次调用时 `body` 为 nil。
    /// `truncated` 表示只记录了前缀。返回值写入 store 前是预算之外的临时交接引用。
    public func finish() -> (body: BodyRef?, truncated: Bool) {
        guard !finished else { return (nil, isTruncated) }
        finished = true
        if let file {
            try? file.handle.close()
            self.file = nil
            if fileSize > 0, let id = ownedID, let handle = registry.seal(id, size: fileSize) {
                ownedID = nil
                return (.managed(handle), isTruncated)
            }
            abandonSpill()
            return (nil, isTruncated)
        }
        let body: BodyRef? = memory.isEmpty ? nil : .managed(registry.registerMemory(memory))
        releaseMemory()
        return (body, isTruncated)
    }

    private func releaseMemory() {
        let count = memory.count
        memory = Data()
        budget?.release(count)
    }

    /// 创建落盘文件并写入已缓存内容。失败时返回 false，只清理本次创建的文件。
    private func spill(buffered: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (url, handle) = try Self.createExclusive(in: directory)
            file = (url, handle)
            ownedID = registry.registerCreatedFile(url)
            guard write(buffered) else {
                try? handle.close()
                file = nil
                fileSize = 0
                abandonSpill()
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Drops the producer claim on the file this capture created; the registry unlinks it.
    private func abandonSpill() {
        guard let id = ownedID else { return }
        ownedID = nil
        HTTPBodyRegistry.discard(registry.abandonProducer(id))
    }

    /// `O_EXCL | O_NOFOLLOW`, mode 0600, direct child of `directory`.
    private static func createExclusive(in directory: URL) throws -> (URL, FileHandle) {
        for _ in 0..<8 {
            let url = directory.appendingPathComponent("\(UUID().uuidString).body")
            let descriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            if descriptor >= 0 { return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) }
            guard errno == EEXIST else { break }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// 返回是否写入成功。失败后标记截断，之后的数据一律丢弃；size 只统计已写入的字节。
    @discardableResult
    private func write(_ chunk: Data) -> Bool {
        guard let file else { return false }
        do {
            try file.handle.write(contentsOf: chunk)
            fileSize += chunk.count
            return true
        } catch {
            isTruncated = true
            return false
        }
    }
}
