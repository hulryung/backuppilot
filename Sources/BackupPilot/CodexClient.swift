import Foundation

/// Codex CLI 를 비대화형으로 호출하는 클라이언트.
///
/// 왜 CLI 인가: 사용자가 이미 `codex login` 으로 인증을 끝내 두었으므로
/// 앱이 API 키를 따로 보관하지 않아도 된다. 백업 도구가 자격증명을 하나 더
/// 들고 있는 것은 그 자체로 위험이라, 인증은 통째로 CLI 에 맡긴다.
///
/// 응답은 `--output-schema` 로 형태를 못박아 JSON 으로 받는다. 자유 문장을 파싱하면
/// 모델이 말투를 바꿀 때마다 앱이 깨진다.
struct CodexClient {

    /// 샌드박스 정책. 앱은 Codex 에게 **읽기 권한만** 준다.
    /// 파일을 실제로 건드리는 것은 언제나 앱 자신이고, 사용자 승인을 거친다.
    static let sandbox = "read-only"

    var executablePath: String
    /// 응답이 오래 걸릴 수 있다. 추론 모델은 1~3분도 흔하다.
    var timeout: TimeInterval = 300

    // MARK: - 실행 파일 찾기

    /// GUI 앱은 로그인 셸의 PATH 를 물려받지 못한다.
    /// (`launchd` 가 띄우기 때문에 `/usr/bin:/bin:/usr/sbin:/sbin` 정도만 있다)
    /// 그래서 Homebrew 경로를 직접 뒤진다.
    static func locate() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/.npm-global/bin/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 마지막 수단: 로그인 셸에 물어본다.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - 오류

    enum Failure: LocalizedError {
        case notInstalled
        case notLoggedIn
        case timedOut(TimeInterval)
        case emptyResponse(String)
        case decodeFailed(String, raw: String)
        case failed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Codex CLI 를 찾지 못했습니다. `brew install codex` 로 설치한 뒤 다시 시도하세요."
            case .notLoggedIn:
                return "Codex 에 로그인되어 있지 않습니다. 터미널에서 `codex login` 을 실행하세요."
            case .timedOut(let seconds):
                return "Codex 응답이 \(Int(seconds))초 안에 오지 않았습니다."
            case .emptyResponse(let detail):
                return "Codex 가 빈 응답을 돌려줬습니다. \(detail)"
            case .decodeFailed(let reason, let raw):
                return "Codex 응답을 해석하지 못했습니다 (\(reason)).\n받은 내용: \(raw.prefix(400))"
            case .failed(let code, let output):
                return "Codex 실행이 실패했습니다 (종료 코드 \(code)).\n\(output.suffix(600))"
            }
        }
    }

    // MARK: - 질의

    /// 스키마에 맞는 구조화 응답을 요청한다.
    ///
    /// - Parameter onProgress: Codex 가 진행 상황을 뱉을 때마다 호출된다 (UI 에 "생각 중" 표시용).
    func ask<T: Decodable>(
        _ type: T.Type,
        prompt: String,
        schema: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let raw = try await askRaw(prompt: prompt, schema: schema, onProgress: onProgress)

        guard let data = raw.data(using: .utf8) else {
            throw Failure.decodeFailed("UTF-8 변환 실패", raw: raw)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.decodeFailed(error.localizedDescription, raw: raw)
        }
    }

    /// 스키마 없이 자유 문장으로 답을 받는다. 사람이 읽을 요약문에만 쓴다.
    func askText(prompt: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await askRaw(prompt: prompt, schema: nil, onProgress: onProgress)
    }

    private func askRaw(
        prompt: String,
        schema: String?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw Failure.notInstalled
        }

        // 작업 파일은 임시 디렉터리에 둔다. 백업 대상 볼륨에 쓰레기를 남기지 않기 위함.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupPilot-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let outputFile = workDir.appendingPathComponent("last-message.txt")

        var args = [
            "exec",
            "--skip-git-repo-check",   // 백업 앱은 git 저장소 안에서 도는 게 아니다
            "--sandbox", Self.sandbox,
            "--ephemeral",             // 세션 기록을 남기지 않는다 (홈 디렉터리 목록이 새어나가지 않도록)
            "-C", workDir.path,        // 작업 루트를 빈 임시 폴더로 묶는다
            "-o", outputFile.path
        ]

        if let schema {
            let schemaFile = workDir.appendingPathComponent("schema.json")
            try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
            args += ["--output-schema", schemaFile.path]
        }

        args.append(prompt)

        // GUI 앱의 빈약한 PATH 를 보강한다. Codex 가 내부적으로 다른 도구를 부를 수 있다.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        env["PATH"] = (extraPaths + existing).reduced().joined(separator: ":")

        // 클로저로 넘기기 전에 값을 확정한다. var 를 그대로 캡처하면 동시성 규칙에 걸린다.
        let finalArgs = args
        let finalEnv = env
        let executable = executablePath

        let result = try await withTimeout(seconds: timeout) {
            try await ProcessRunner.stream(
                executable, finalArgs,
                currentDirectory: workDir,
                environment: finalEnv
            ) { line in
                onProgress?(line)
            }
        }

        guard result.succeeded else {
            let combined = result.stderr + "\n" + result.stdout
            if combined.lowercased().contains("not logged in") || combined.contains("codex login") {
                throw Failure.notLoggedIn
            }
            throw Failure.failed(result.exitCode, combined)
        }

        let text = (try? String(contentsOf: outputFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            throw Failure.emptyResponse(result.stdout.suffix(300).description)
        }
        return stripCodeFence(text)
    }

    /// 모델이 JSON 을 ```json 펜스로 감싸는 경우가 있다. 스키마를 줬을 때도 가끔 그런다.
    private func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 타임아웃

    /// 응답이 영영 안 올 때 UI 가 멈춰 있지 않도록 상한을 건다.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timedOut(seconds)
            }
            guard let first = try await group.next() else {
                throw Failure.emptyResponse("작업이 결과 없이 끝났습니다")
            }
            group.cancelAll()
            return first
        }
    }
}

private extension Array where Element == String {
    /// 순서를 유지하면서 중복을 제거한다.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
