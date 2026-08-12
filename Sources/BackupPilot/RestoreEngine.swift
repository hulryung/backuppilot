import Foundation

/// 외장 매체에서 찾은 백업 하나.
struct BackupBundle: Identifiable, Hashable {
    var url: URL
    var manifest: Manifest

    var id: String { url.path }

    var displayName: String { url.lastPathComponent }

    var totalSourceBytes: Int64 {
        manifest.items.reduce(0) { $0 + $1.sourceByteSize }
    }

    /// 백업 당시 계정 경로가 지금과 같은지.
    ///
    /// 이게 어긋나면 Claude Code 대화 기록이 복원돼도 매칭되지 않는다.
    /// `~/.claude/projects/` 하위 디렉터리 이름이 프로젝트 절대경로를 인코딩한 값이기 때문이다.
    var homePathMatches: Bool {
        manifest.homePath == Home.path
    }

    // 매니페스트 전체를 값 비교할 이유가 없다. 백업 디렉터리 경로가 곧 신원이다.
    static func == (lhs: BackupBundle, rhs: BackupBundle) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// 복원을 수행한다.
@MainActor
final class RestoreEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress = JobProgress()
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var checks: [VerificationCheck] = []
    @Published private(set) var failure: BackupEngine.Failure?

    private var currentProcess: Process?
    private var isCancelled = false

    // MARK: - 로그

    private func append(_ level: LogLine.Level, _ text: String) {
        log.append(LogLine(level, text))
        if log.count > 4000 { log.removeFirst(1000) }
    }

    func recentLogText(lines: Int = 60) -> String {
        log.suffix(lines).map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    func clearLog() {
        log.removeAll()
        failure = nil
    }

    func cancel() {
        isCancelled = true
        currentProcess?.terminate()
        append(.warn, "취소 요청 — 실행 중인 명령을 종료합니다")
    }

    // MARK: - 백업 찾기

    /// 볼륨에서 BackupPilot 백업을 찾는다. 최근 것이 위로 온다.
    static func discover(on volume: Volume) -> [BackupBundle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: volume.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return entries.compactMap { url -> BackupBundle? in
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else { return nil }
            return BackupBundle(url: url, manifest: manifest)
        }
        .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    // MARK: - 복원

    /// 선택한 항목을 홈 디렉터리로 되돌린다.
    ///
    /// - Parameter selected: 복원할 항목의 relativePath 집합.
    func restore(bundle: BackupBundle, selected: Set<String>) async {
        guard !isRunning else { return }

        isRunning = true
        isCancelled = false
        failure = nil
        defer {
            isRunning = false
            currentProcess = nil
        }

        let items = bundle.manifest.items.filter { selected.contains($0.relativePath) && $0.succeeded }
        guard !items.isEmpty else {
            append(.error, "복원할 항목이 없습니다")
            return
        }

        if !bundle.homePathMatches {
            append(.warn, """
                백업 당시 홈 경로(\(bundle.manifest.homePath))와 지금(\(Home.path))이 다릅니다. \
                Claude Code 대화 기록은 프로젝트 절대경로로 색인되므로 그대로 복원해도 매칭되지 않습니다.
                """)
        }

        let tools = await Tools.detect()
        let dataDir = bundle.url.appendingPathComponent("data")

        progress = JobProgress(currentItem: "", itemIndex: 0, itemCount: items.count, itemFraction: nil)

        for (index, item) in items.enumerated() {
            if isCancelled {
                append(.warn, "사용자 취소로 중단했습니다")
                break
            }

            progress.currentItem = item.relativePath
            progress.itemIndex = index
            progress.itemFraction = nil

            append(.info, "[\(index + 1)/\(items.count)] \(item.relativePath) 복원 — \(item.strategy.label)")

            let ok: Bool
            switch item.strategy {
            case .tarGz:
                ok = await extractArchive(item: item, from: dataDir)
            case .rsync:
                ok = await copyBack(item: item, from: dataDir, tools: tools)
            }

            if ok {
                append(.ok, "\(item.relativePath) 복원 완료")
            } else {
                append(.error, "\(item.relativePath) 복원 실패")
                failure = BackupEngine.Failure(
                    itemPath: item.relativePath,
                    logTail: recentLogText(),
                    message: "\(item.relativePath) 복원 실패"
                )
            }

            progress.itemIndex = index + 1
        }

        await repairPermissions()
        append(.ok, "복원 작업이 끝났습니다. 검증을 실행해 빠진 것이 없는지 확인하세요.")
    }

    // MARK: - tar.gz 풀기

    private func extractArchive(item: Manifest.ManifestItem, from dataDir: URL) async -> Bool {
        let archive = dataDir.appendingPathComponent(item.artifactName)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            append(.error, "아카이브를 찾을 수 없습니다: \(item.artifactName)")
            return false
        }

        // -p 로 권한을 복원한다. 이게 tar.gz 를 쓴 이유 그 자체다.
        let args = ["xzpf", archive.path, "-C", Home.path]
        append(.command, "tar \(args.joined(separator: " "))")

        let totalFiles = item.sourceFileCount
        let counter = RestoreProgressCounter()

        do {
            let result = try await ProcessRunner.stream(
                "/usr/bin/tar", args,
                registerProcess: { [weak self] process in
                    Task { @MainActor in self?.currentProcess = process }
                },
                onOutput: { [weak self] line in
                    if line.hasPrefix("x ") {
                        if let value = counter.tick(total: totalFiles) {
                            Task { @MainActor in self?.progress.itemFraction = value }
                        }
                    } else {
                        Task { @MainActor in self?.append(.warn, line) }
                    }
                }
            )
            return result.succeeded
        } catch {
            append(.error, error.localizedDescription)
            return false
        }
    }

    // MARK: - 평문 복사 되돌리기

    private func copyBack(item: Manifest.ManifestItem, from dataDir: URL, tools: Tools) async -> Bool {
        let source = dataDir.appendingPathComponent(item.relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            append(.error, "백업본을 찾을 수 없습니다: \(item.relativePath)")
            return false
        }

        let destination = Home.resolve(item.relativePath)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // 기존 파일을 지우지 않는다(--delete 없음). 복원은 덧씌우기이지 동기화가 아니다.
        var args = ["-rlt", "--human-readable"]

        // exFAT 은 확장속성을 `._` AppleDouble 파일로 따로 저장한다. 그대로 되돌리면
        // 홈 디렉터리에 그 찌꺼기가 그대로 쌓인다 — 원본에는 없던 파일들이다.
        args += ["--exclude", "._*", "--exclude", ".DS_Store"]

        args.append(tools.rsyncHasProgress2 ? "--info=progress2" : "-v")
        args += [source.path + "/", destination.path + "/"]

        append(.command, "rsync \(args.joined(separator: " "))")

        let hasProgress2 = tools.rsyncHasProgress2
        let counter = RestoreProgressCounter()
        let totalFiles = item.sourceFileCount

        do {
            let result = try await ProcessRunner.stream(
                tools.rsync, args,
                registerProcess: { [weak self] process in
                    Task { @MainActor in self?.currentProcess = process }
                },
                onOutput: { [weak self] line in
                    if hasProgress2, let percent = BackupEngine.parsePercent(line) {
                        Task { @MainActor in self?.progress.itemFraction = percent }
                    } else if !hasProgress2 {
                        if let value = counter.tick(total: totalFiles) {
                            Task { @MainActor in self?.progress.itemFraction = value }
                        }
                    } else if line.contains("rsync:") {
                        Task { @MainActor in self?.append(.warn, line) }
                    }
                }
            )
            return result.succeeded || result.exitCode == 24
        } catch {
            append(.error, error.localizedDescription)
            return false
        }
    }

    // MARK: - 권한 복구

    /// exFAT 을 거치며 뭉개진 권한을 되돌린다.
    ///
    /// tar.gz 로 묶은 것은 이미 권한이 살아 있지만, 평문 복사분과
    /// 사용자가 손으로 옮긴 것까지 감안해 한 번 훑는다.
    /// 여기서 놓치면 `ssh` 가 "permissions are too open" 으로 거부한다.
    private func repairPermissions() async {
        append(.info, "권한 복구 중")

        let home = Home.path
        struct Fix { var mode: String; var paths: [String]; var isGlob: Bool }

        let fixes: [Fix] = [
            Fix(mode: "700", paths: [".ssh", ".gnupg", ".aws", ".claude", ".codex"], isGlob: false),
            Fix(mode: "600", paths: [".claude.json", ".ssh/config", ".ssh/known_hosts",
                                     ".codex/auth.json", ".aws/credentials"], isGlob: false),
            Fix(mode: "600", paths: [".ssh/id_*"], isGlob: true),
            Fix(mode: "644", paths: [".ssh/*.pub"], isGlob: true)
        ]

        for fix in fixes {
            for relative in fix.paths {
                let full = home + "/" + relative
                if fix.isGlob {
                    // 글로브는 셸에 맡긴다. 매칭이 없으면 조용히 넘어가도록 nullglob 대신 검사를 붙인다.
                    let command = "for f in \(full); do [ -e \"$f\" ] && chmod \(fix.mode) \"$f\"; done"
                    _ = try? await ProcessRunner.shell(command)
                } else {
                    guard FileManager.default.fileExists(atPath: full) else { continue }
                    _ = try? await ProcessRunner.capture("/bin/chmod", [fix.mode, full])
                }
            }
        }

        // 공개키는 0600 이어도 동작하지만, id_* 글로브가 .pub 까지 잡으므로 순서상 뒤에서 되돌려 놓는다.
        append(.ok, "권한 복구 완료 (.ssh 0700, 개인키 0600)")
    }

    // MARK: - 검증

    /// 백업 시점 기준값과 지금 상태를 대조한다.
    ///
    /// 하드코딩된 기대치가 아니라 "백업할 때 실제로 이만큼 있었다"와 비교하는 것이 요점이다.
    func verify(bundle: BackupBundle) async {
        checks = []

        // 홈 경로 일치 — Claude 대화 기록 매칭의 전제 조건
        checks.append(VerificationCheck(
            label: "홈 경로 일치",
            passed: bundle.homePathMatches,
            detail: bundle.homePathMatches
                ? Home.path
                : "백업 \(bundle.manifest.homePath) ≠ 현재 \(Home.path) — 대화 기록이 매칭되지 않습니다"
        ))

        for item in bundle.manifest.items where item.succeeded {
            let restored = Home.resolve(item.relativePath)

            guard FileManager.default.fileExists(atPath: restored.path) else {
                checks.append(VerificationCheck(
                    label: item.relativePath,
                    passed: false,
                    detail: "복원되지 않았습니다"
                ))
                continue
            }

            let measured = await SizeEstimator.measureProduced(at: restored, excludingAppleDouble: true)
            let expected = item.sourceFileCount

            // 정확히 같을 수는 없다. 캐시가 다시 생기고, 제외 패턴 집계 기준도 완전히 같지 않다.
            // 98% 이상이면 통과로 본다.
            let ratio = expected > 0 ? Double(measured.fileCount) / Double(expected) : 1.0
            let passed = expected == 0 || ratio >= 0.98

            checks.append(VerificationCheck(
                label: item.relativePath,
                passed: passed,
                detail: "\(Fmt.count(measured.fileCount)) / 백업 당시 \(Fmt.count(expected))"
                    + (passed ? "" : String(format: " (%.0f%%)", ratio * 100))
            ))
        }

        let failed = checks.filter { !$0.passed }
        if failed.isEmpty {
            append(.ok, "검증 통과 — \(checks.count)개 항목 모두 확인")
        } else {
            append(.warn, "검증에서 \(failed.count)개 항목이 걸렸습니다")
        }
    }
}

/// BackupEngine 의 것과 같은 역할. 복원 쪽에서도 콜백 폭주를 솎아낸다.
private final class RestoreProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var lastReported = 0

    func tick(total: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        guard total > 0 else { return nil }
        let step = max(1, total / 100)
        guard seen - lastReported >= step else { return nil }
        lastReported = seen
        return min(1.0, Double(seen) / Double(total))
    }
}
