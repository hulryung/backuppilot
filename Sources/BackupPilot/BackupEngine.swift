import Foundation

/// 백업에 필요한 외부 도구를 찾고, 그 도구가 무엇을 할 수 있는지 알아낸다.
///
/// macOS 에는 rsync 가 두 개 있고 서로 다르다:
///  - `/usr/bin/rsync` — openrsync. `--info=progress2` 를 모른다.
///  - `/opt/homebrew/bin/rsync` — rsync 3.x. 진행률을 퍼센트로 준다.
/// 어느 쪽이 걸리느냐에 따라 진행률을 얻는 방법이 달라진다.
struct Tools {
    var rsync: String
    var rsyncHasProgress2: Bool
    var tar: String

    static func detect() async -> Tools {
        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsync = rsyncCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/rsync"

        // 실제로 물어본다. 경로로 짐작하면 사용자가 심볼릭 링크를 바꿔 둔 경우에 틀린다.
        let probe = try? await ProcessRunner.capture(rsync, ["--info=progress2", "--version"])
        let hasProgress2 = probe?.succeeded ?? false

        return Tools(rsync: rsync, rsyncHasProgress2: hasProgress2, tar: "/usr/bin/tar")
    }
}

/// 백업을 실제로 수행한다.
@MainActor
final class BackupEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress = JobProgress()
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var lastManifest: Manifest?
    /// 실패한 항목과 그 로그. Codex 진단에 그대로 넘긴다.
    @Published private(set) var failure: Failure?

    struct Failure {
        var itemPath: String?
        var logTail: String
        var message: String
    }

    private var currentProcess: Process?
    private var isCancelled = false

    // MARK: - 로그

    private func append(_ level: LogLine.Level, _ text: String) {
        log.append(LogLine(level, text))
        // 무한정 쌓이면 UI 가 느려진다. 오래된 것부터 버리되 넉넉히 남긴다.
        if log.count > 4000 { log.removeFirst(1000) }
    }

    /// 최근 로그를 Codex 진단용으로 뽑는다.
    func recentLogText(lines: Int = 60) -> String {
        log.suffix(lines).map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    func clearLog() {
        log.removeAll()
        failure = nil
    }

    // MARK: - 취소

    func cancel() {
        isCancelled = true
        currentProcess?.terminate()
        append(.warn, "취소 요청 — 실행 중인 명령을 종료합니다")
    }

    // MARK: - 실행

    /// 백업을 수행하고 매니페스트를 남긴다.
    ///
    /// - Returns: 성공적으로 만들어진 백업 디렉터리. 실패하면 nil.
    @discardableResult
    func run(plan: BackupPlan, to volume: Volume) async -> URL? {
        guard !isRunning else { return nil }

        isRunning = true
        isCancelled = false
        failure = nil
        defer {
            isRunning = false
            currentProcess = nil
        }

        let items = plan.enabledItems
        guard !items.isEmpty else {
            append(.error, "백업할 항목이 없습니다")
            return nil
        }

        // ── 사전 점검 ──
        guard !volume.isReadOnly else {
            append(.error, "\(volume.name) 은 읽기 전용으로 마운트되어 있습니다")
            failure = Failure(itemPath: nil, logTail: recentLogText(), message: "대상 볼륨이 읽기 전용")
            return nil
        }

        let estimated = plan.estimatedDestinationBytes(on: volume)
        if estimated > volume.freeBytes {
            append(.error, "여유 공간 부족: 예상 \(Fmt.bytes(estimated)) > 여유 \(Fmt.bytes(volume.freeBytes))")
            failure = Failure(
                itemPath: nil,
                logTail: recentLogText(),
                message: "여유 공간 부족 (예상 \(Fmt.bytes(estimated)), 여유 \(Fmt.bytes(volume.freeBytes)))"
            )
            return nil
        }

        let tools = await Tools.detect()
        append(.info, "rsync: \(tools.rsync) (진행률 \(tools.rsyncHasProgress2 ? "지원" : "미지원"))")

        // ── 대상 디렉터리 ──
        let stamp = Self.stampFormatter.string(from: Date())
        let root = volume.url.appendingPathComponent("BackupPilot-\(stamp)")
        let dataDir = root.appendingPathComponent("data")

        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            append(.error, "백업 디렉터리를 만들지 못했습니다: \(error.localizedDescription)")
            failure = Failure(itemPath: nil, logTail: recentLogText(), message: error.localizedDescription)
            return nil
        }

        append(.ok, "백업 위치: \(root.path)")
        if volume.isPermissionLossy {
            append(.warn, "\(volume.fileSystem) 볼륨 — 권한이 보존되지 않습니다. 권한이 중요한 항목은 tar.gz 로 묶습니다.")
        }

        // ── 항목별 실행 ──
        progress = JobProgress(currentItem: "", itemIndex: 0, itemCount: items.count, itemFraction: nil)
        var manifestItems: [Manifest.ManifestItem] = []

        for (index, item) in items.enumerated() {
            if isCancelled {
                append(.warn, "사용자 취소로 중단했습니다")
                break
            }

            progress.currentItem = item.relativePath
            progress.itemIndex = index
            progress.itemFraction = nil

            append(.info, "[\(index + 1)/\(items.count)] \(item.relativePath) — \(item.strategy.label)")

            let started = Date()
            let outcome: (ok: Bool, message: String?)

            switch item.strategy {
            case .tarGz:
                outcome = await runTar(item: item, into: dataDir, tools: tools)
            case .rsync:
                outcome = await runRsync(item: item, into: dataDir, tools: tools)
            }

            let elapsed = Date().timeIntervalSince(started)
            let artifactURL = dataDir.appendingPathComponent(item.artifactName)
            let produced = await SizeEstimator.measureProduced(at: artifactURL)

            manifestItems.append(Manifest.ManifestItem(
                relativePath: item.relativePath,
                strategy: item.strategy,
                artifactName: item.artifactName,
                sourceByteSize: item.byteSize ?? 0,
                sourceFileCount: item.fileCount ?? 0,
                producedByteSize: produced.byteSize,
                producedFileCount: produced.fileCount,
                producedAllocatedBytes: produced.allocatedBytes,
                durationSeconds: elapsed,
                succeeded: outcome.ok,
                message: outcome.message
            ))

            if outcome.ok {
                // 논리 크기와 실제 할당량이 크게 벌어지면(exFAT) 둘 다 보여준다.
                // "65KB 썼다"고만 하면 SSD 가 왜 차오르는지 알 수 없다.
                let inflated = produced.allocatedBytes > produced.byteSize * 2 && produced.byteSize > 0
                let sizeText = inflated
                    ? "\(Fmt.bytes(produced.byteSize)) → 디스크에서 \(Fmt.bytes(produced.allocatedBytes))"
                    : Fmt.bytes(produced.allocatedBytes > 0 ? produced.allocatedBytes : produced.byteSize)
                append(.ok, "\(item.relativePath) 완료 — \(sizeText), \(Fmt.duration(elapsed))")
            } else {
                append(.error, "\(item.relativePath) 실패 — \(outcome.message ?? "원인 미상")")
                failure = Failure(
                    itemPath: item.relativePath,
                    logTail: recentLogText(),
                    message: outcome.message ?? "원인 미상"
                )
            }

            progress.itemIndex = index + 1
            progress.itemFraction = nil
        }

        // ── 매니페스트 ──
        let manifest = Manifest(
            createdAt: Date(),
            hostName: ProcessInfo.processInfo.hostName,
            userName: NSUserName(),
            homePath: Home.path,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            destinationPath: root.path,
            destinationFileSystem: volume.fileSystem,
            items: manifestItems
        )

        writeManifest(manifest, to: root)
        writeLog(to: root)
        lastManifest = manifest

        let failed = manifestItems.filter { !$0.succeeded }
        if failed.isEmpty && !isCancelled {
            append(.ok, "백업 완료 — \(manifestItems.count)개 항목")
            return root
        } else if isCancelled {
            append(.warn, "중단됨 — \(manifestItems.count)개 항목까지 처리")
            return root
        } else {
            append(.error, "\(failed.count)개 항목이 실패했습니다: \(failed.map(\.relativePath).joined(separator: ", "))")
            return root
        }
    }

    // MARK: - tar.gz

    private func runTar(item: BackupItem, into dataDir: URL, tools: Tools) async -> (Bool, String?) {
        let output = dataDir.appendingPathComponent(item.artifactName)
        let totalFiles = item.fileCount ?? 0

        var args = ["czf", output.path]
        for pattern in item.excludes {
            args += ["--exclude", pattern]
        }
        // 진행률을 위해 파일 목록을 받는다. bsdtar 는 이걸 stderr 로 낸다.
        args.append("-v")
        args += ["-C", Home.path, item.relativePath]

        append(.command, "tar \(args.joined(separator: " "))")

        // 38만 개 파일이면 콜백도 38만 번 불린다. UI 갱신은 솎아낸다.
        let counter = ProgressCounter()

        do {
            let result = try await ProcessRunner.stream(
                tools.tar, args,
                registerProcess: { [weak self] process in
                    Task { @MainActor in self?.currentProcess = process }
                },
                onOutput: { [weak self] line in
                    // tar -v 는 추가되는 파일마다 "a <경로>" 를 낸다.
                    if line.hasPrefix("a ") {
                        guard let snapshot = counter.tick(total: totalFiles) else { return }
                        Task { @MainActor in self?.progress.itemFraction = snapshot }
                    } else if !line.hasPrefix("x ") {
                        // 경고·오류만 로그에 남긴다.
                        Task { @MainActor in self?.append(.warn, line) }
                    }
                }
            )

            guard FileManager.default.fileExists(atPath: output.path) else {
                return (false, "아카이브가 만들어지지 않았습니다 (종료 코드 \(result.exitCode))")
            }

            // tar 는 일부 파일을 못 읽어도 exit 1 을 낼 수 있다.
            // 아카이브가 만들어졌으면 부분 성공으로 보고 경고만 남긴다.
            if !result.succeeded {
                let detail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " / ")
                append(.warn, "일부 파일을 건너뛰었습니다: \(detail)")
            }
            return (true, result.succeeded ? nil : "일부 파일 건너뜀")

        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - rsync

    private func runRsync(item: BackupItem, into dataDir: URL, tools: Tools) async -> (Bool, String?) {
        let destination = dataDir.appendingPathComponent(item.relativePath)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return (false, "대상 폴더를 만들지 못했습니다: \(error.localizedDescription)")
        }

        // -rlt 만 쓴다. -p(권한) -o(소유자) -g(그룹) 은 exFAT 에서 어차피 버려지고
        // 오류만 늘린다. -X(확장속성) 도 뺀다 — 켜면 파일마다 `._` 짝이 생겨 용량이 폭증한다.
        var args = ["-rlt", "--human-readable"]
        for pattern in item.excludes {
            args += ["--exclude", pattern]
        }
        args.append(tools.rsyncHasProgress2 ? "--info=progress2" : "-v")

        // 원본에 슬래시를 붙여 "안의 것들"을 대상 안으로 넣는다.
        args += [item.sourceURL.path + "/", destination.path + "/"]

        append(.command, "rsync \(args.joined(separator: " "))")

        let totalFiles = item.fileCount ?? 0
        let counter = ProgressCounter()
        let hasProgress2 = tools.rsyncHasProgress2

        do {
            let result = try await ProcessRunner.stream(
                tools.rsync, args,
                registerProcess: { [weak self] process in
                    Task { @MainActor in self?.currentProcess = process }
                },
                onOutput: { [weak self] line in
                    if hasProgress2 {
                        // "  32,899,072  12%   31.34MB/s    0:00:02"
                        if let percent = Self.parsePercent(line) {
                            Task { @MainActor in self?.progress.itemFraction = percent }
                            return
                        }
                    } else {
                        // openrsync 는 퍼센트를 안 준다. 전송된 파일 이름을 세서 근사한다.
                        if !line.hasPrefix("sending") && !line.hasPrefix("sent") && !line.contains("speedup") {
                            if let snapshot = counter.tick(total: totalFiles) {
                                Task { @MainActor in self?.progress.itemFraction = snapshot }
                            }
                            return
                        }
                    }

                    if line.lowercased().contains("error") || line.contains("rsync:") {
                        Task { @MainActor in self?.append(.warn, line) }
                    }
                }
            )

            if !result.succeeded {
                // 24 = 전송 중 원본 파일이 사라짐. 흔하고 치명적이지 않다.
                if result.exitCode == 24 {
                    append(.warn, "전송 중 사라진 파일이 있습니다 (정상 범위)")
                    return (true, "일부 파일이 전송 중 사라짐")
                }
                let detail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " / ")
                return (false, "rsync 종료 코드 \(result.exitCode): \(detail)")
            }
            return (true, nil)

        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// rsync `--info=progress2` 줄에서 퍼센트를 뽑는다.
    nonisolated static func parsePercent(_ line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let digits = line[range].dropLast()
        guard let value = Double(digits) else { return nil }
        return min(1.0, value / 100.0)
    }

    // MARK: - 산출물 기록

    private func writeManifest(_ manifest: Manifest, to root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: root.appendingPathComponent("manifest.json"))
            append(.ok, "manifest.json 기록 — 복원 검증의 기준값입니다")
        } catch {
            append(.warn, "매니페스트를 쓰지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func writeLog(to root: URL) {
        let text = log.map { line in
            "\(Self.logFormatter.string(from: line.timestamp)) [\(line.level.rawValue)] \(line.text)"
        }.joined(separator: "\n")
        try? text.write(to: root.appendingPathComponent("backup.log"), atomically: true, encoding: .utf8)
    }

    // MARK: - 포맷터

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 파일 하나마다 오는 콜백을 UI 갱신 빈도로 솎아낸다.
///
/// 38만 개 파일에 대해 매번 `@Published` 를 건드리면 SwiftUI 가 그것만 그리다 끝난다.
/// 카운트는 전부 세되, 화면 갱신 값은 일정 간격으로만 돌려준다.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var lastReported = 0

    /// - Returns: 갱신할 값(0...1). 아직 갱신할 때가 아니면 nil.
    func tick(total: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        guard total > 0 else {
            // 총 개수를 모르면 200개마다 한 번씩만 살아있다는 표시를 준다.
            guard seen - lastReported >= 200 else { return nil }
            lastReported = seen
            return nil
        }
        let step = max(1, total / 100)   // 1% 단위
        guard seen - lastReported >= step else { return nil }
        lastReported = seen
        return min(1.0, Double(seen) / Double(total))
    }
}
