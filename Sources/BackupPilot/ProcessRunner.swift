import Foundation

/// 파이프에서 흘러나오는 바이트를 줄 단위로 잘라 넘겨주는 수집기.
///
/// 별도 타입으로 뺀 이유: readabilityHandler 는 임의의 백그라운드 스레드에서 불리므로
/// 지역 변수를 캡처해 고치면 데이터 경합이 된다. 상태를 한 객체에 모으고 락으로 감싼다.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private(set) var collected = ""
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        var lines: [String] = []
        lock.lock()
        collected += chunk
        partial += chunk
        // rsync --info=progress2 는 줄바꿈 대신 캐리지 리턴으로 같은 줄을 덮어쓴다.
        // 둘 다 구분자로 취급해야 진행률이 실시간으로 올라온다.
        while let idx = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(partial[partial.startIndex..<idx]))
            partial = String(partial[partial.index(after: idx)...])
        }
        lock.unlock()

        // 콜백은 락 밖에서 부른다 — 콜백이 오래 걸려도 읽기를 막지 않도록.
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onLine(trimmed) }
        }
    }

    /// 줄바꿈 없이 끝난 마지막 조각을 흘려보낸다.
    func flush() {
        lock.lock()
        let leftover = partial
        partial = ""
        lock.unlock()

        let trimmed = leftover.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onLine(trimmed) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return collected
    }
}

/// 한 번만 통과시키는 문.
///
/// 종료 신호가 두 경로로 올 수 있는 곳에서, `DispatchGroup.leave()` 가 두 번 불리면
/// 그 자체로 크래시다. 먼저 온 쪽만 통과시킨다.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// - Returns: 이번 호출이 처음이면 true.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// 외부 명령 실행 래퍼.
///
/// 백업은 결국 `rsync`/`tar`를 돌리는 일이고, 그 출력을 실시간으로 보여줘야 쓸 만하다.
/// 그래서 종료를 기다렸다가 한꺼번에 읽는 대신 줄 단위로 흘려보낸다.
enum ProcessRunner {

    struct Result {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        var succeeded: Bool { exitCode == 0 }
    }

    enum Failure: LocalizedError {
        case launchFailed(String, underlying: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .launchFailed(let cmd, let underlying):
                return "\(cmd) 실행 실패: \(underlying)"
            case .cancelled:
                return "사용자가 취소했습니다"
            }
        }
    }

    /// 명령을 실행하면서 출력 줄을 콜백으로 흘려보낸다.
    ///
    /// - Parameters:
    ///   - registerProcess: 실행 중인 Process 를 바깥에 넘겨 취소할 수 있게 한다.
    ///   - onOutput: stdout/stderr 에서 나온 줄. 백그라운드 스레드에서 호출된다.
    @discardableResult
    static func stream(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        registerProcess: (@Sendable (Process) -> Void)? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Result {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // stdin 을 명시적으로 닫는다. codex 는 stdin 이 열려 있으면 추가 입력을 기다리고,
        // rsync/tar 도 상황에 따라 프롬프트를 띄운다 — GUI 에서는 아무도 답할 수 없다.
        process.standardInput = FileHandle.nullDevice

        let outCollector = OutputCollector(onLine: onOutput)
        let errCollector = OutputCollector(onLine: onOutput)

        // 끝났다고 말할 수 있으려면 세 가지가 모두 끝나야 한다:
        // stdout EOF, stderr EOF, 그리고 프로세스 종료. 셋을 그룹으로 묶어 기다린다.
        let done = DispatchGroup()

        // 파이프는 EOF 까지 읽는다. `readDataToEndOfFile()` 을 쓰면 안 된다 —
        // 부모가 쓰기 끝을 쥐고 있는 동안 그 호출은 영원히 블록된다.
        // readabilityHandler 가 빈 데이터를 주는 것이 EOF 신호다.
        func drainToEOF(_ pipe: Pipe, into collector: OutputCollector) {
            done.enter()
            let left = OnceFlag()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if left.claim() { done.leave() }
                } else {
                    collector.feed(data)
                }
            }
        }
        drainToEOF(outPipe, into: outCollector)
        drainToEOF(errPipe, into: errCollector)

        // 종료 핸들러는 반드시 `run()` **전에** 건다.
        // 뒤에 걸면, 그 사이에 프로세스가 끝나 버린 경우(chmod 처럼 순식간에 끝나는 명령이 그렇다)
        // 핸들러가 영영 호출되지 않아 여기서 영구히 멈춘다.
        done.enter()
        let exited = OnceFlag()
        process.terminationHandler = { _ in
            if exited.claim() { done.leave() }
        }

        do {
            try process.run()
        } catch {
            // 걸어 둔 대기를 풀어 준다. 안 그러면 이 그룹을 기다리는 쪽이 멈춘다.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw Failure.launchFailed(executable, underlying: error.localizedDescription)
        }
        registerProcess?(process)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            done.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }

        // 줄바꿈 없이 끝난 마지막 조각을 흘려보낸다.
        outCollector.flush()
        errCollector.flush()

        return Result(
            exitCode: process.terminationStatus,
            stdout: outCollector.text,
            stderr: errCollector.text
        )
    }

    /// 출력이 짧고 진행률이 필요 없는 명령용. 결과만 통째로 돌려준다.
    static func capture(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> Result {
        try await stream(executable, arguments, currentDirectory: currentDirectory) { _ in }
    }

    /// `/bin/sh -c` 로 감싸 파이프라인을 실행한다.
    /// 인자를 직접 넘길 수 있는 경우에는 쓰지 말 것 — 셸 인용 문제를 떠안게 된다.
    @discardableResult
    static func shell(
        _ command: String,
        registerProcess: (@Sendable (Process) -> Void)? = nil,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Result {
        try await stream("/bin/sh", ["-c", command], registerProcess: registerProcess, onOutput: onOutput)
    }
}

// MARK: - 셸 인용

extension String {
    /// 셸에 넘길 때 안전하도록 작은따옴표로 감싼다.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
