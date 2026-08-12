import Foundation

/// Codex 에게 무엇을 물어볼지, 그리고 어떤 형태로 답을 받을지 정의한다.
///
/// 설계 원칙 두 가지:
///  1. **모델에게 파일을 건드리게 하지 않는다.** Codex 는 읽기 전용 샌드박스에서 돌고,
///     실제 실행은 언제나 앱이 사용자 승인을 받아 한다.
///  2. **답은 반드시 스키마에 맞춘다.** 자유 문장을 파싱하면 모델 말투가 바뀔 때마다 앱이 깨진다.
enum Advisor {

    // MARK: - 공통 배경 설명

    /// 모든 질의에 붙는 상황 설명. 이 앱이 무엇을 하는 물건인지 모델이 알아야
    /// 엉뚱한 제안(예: Time Machine 을 쓰라)을 하지 않는다.
    private static func context(volume: Volume?) -> String {
        var lines = [
            "너는 macOS 백업 도구 BackupPilot 의 조언자다.",
            "이 도구는 OS 재설치를 앞두고 홈 디렉터리를 외장 SSD 로 옮기는 데 쓰인다.",
            "복사 방식은 두 가지뿐이다: rsync(평문 복사) 또는 tar.gz(아카이브).",
            "너는 파일을 직접 건드리지 않는다. 제안만 하고, 실행은 사용자가 승인한 뒤 앱이 한다."
        ]

        if let volume {
            lines.append("")
            lines.append("대상 볼륨: \(volume.name) (\(volume.url.path))")
            lines.append("파일시스템: \(volume.fileSystem), 할당 블록 \(volume.allocationBlockSize) 바이트")
            lines.append("여유 공간: \(Fmt.bytes(volume.freeBytes)) / 전체 \(Fmt.bytes(volume.totalBytes))")

            if volume.isPermissionLossy {
                lines.append("""

                    중요 — 이 볼륨은 exFAT 계열이라 다음 제약이 있다:
                    - POSIX 권한(chmod)이 보존되지 않는다. ~/.ssh 같은 경로를 평문 복사하면 \
                    복원 후 ssh 가 "permissions are too open" 으로 거부한다.
                    - 소유자/그룹과 하드링크도 보존되지 않는다.
                    - 할당 블록이 \(volume.allocationBlockSize / 1024)KB 라 작은 파일 하나가 그만큼을 통째로 차지한다.
                    - 확장속성 때문에 파일마다 `._` AppleDouble 짝이 하나씩 더 생기고, 이것도 한 블록씩 먹는다.
                    → 따라서 권한이 중요한 경로와 파일 수가 많은 경로는 tar.gz 로 묶어야 한다.
                    """)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func itemTable(_ items: [BackupItem]) -> String {
        guard !items.isEmpty else { return "(측정된 항목 없음)" }
        let rows = items.map { item in
            let size = Fmt.bytes(item.byteSize)
            let count = Fmt.count(item.fileCount)
            let state = item.isEnabled ? "포함" : "제외"
            return "- \(item.relativePath) | \(size) | \(count) | 현재 \(item.strategy.rawValue) | \(state) | \(item.note)"
        }
        return (["경로 | 크기 | 파일수 | 현재전략 | 현재선택 | 설명"] + rows).joined(separator: "\n")
    }

    // MARK: - 1. 백업 계획 상담

    struct PlanAdvice: Codable {
        struct Suggestion: Codable, Identifiable {
            var relativePath: String
            var include: Bool
            var strategy: String        // "rsync" | "tarGz"
            var rationale: String

            var id: String { relativePath }

            var parsedStrategy: CopyStrategy? {
                CopyStrategy(rawValue: strategy)
            }
        }

        var summary: String
        var suggestions: [Suggestion]
        var warnings: [String]
    }

    private static let planSchema = """
    {
      "type": "object",
      "properties": {
        "summary": { "type": "string" },
        "suggestions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "relativePath": { "type": "string" },
              "include": { "type": "boolean" },
              "strategy": { "type": "string", "enum": ["rsync", "tarGz"] },
              "rationale": { "type": "string" }
            },
            "required": ["relativePath", "include", "strategy", "rationale"],
            "additionalProperties": false
          }
        },
        "warnings": { "type": "array", "items": { "type": "string" } }
      },
      "required": ["summary", "suggestions", "warnings"],
      "additionalProperties": false
    }
    """

    static func planPrompt(items: [BackupItem], volume: Volume?, plan: BackupPlan) -> String {
        let estimated = plan.estimatedDestinationBytes(on: volume)
        let free = volume?.freeBytes ?? 0
        let fits = estimated <= free

        return """
        \(context(volume: volume))

        아래는 현재 백업 계획이다.

        \(itemTable(items))

        원본 합계: \(Fmt.bytes(plan.totalSourceBytes)), 파일 \(Fmt.count(plan.totalFileCount))
        이 계획대로면 대상 볼륨에서 약 \(Fmt.bytes(estimated)) 를 쓸 것으로 예측된다.
        여유 공간은 \(Fmt.bytes(free)) 이므로 \(fits ? "들어간다" : "부족하다").

        할 일:
        1. 각 항목의 전략(rsync/tarGz)이 적절한지 판단하고, 바꿔야 할 것만 suggestions 에 넣어라.
           바꿀 필요가 없는 항목은 suggestions 에서 빼라.
        2. 포함/제외(include)도 재고해라. 재설치하면 어차피 다시 받는 것(캐시, 빌드 산출물,
           패키지 매니저가 복원하는 의존성)은 제외를 권해라.
        3. 놓치기 쉬운데 백업해야 하는 것이 보이면 warnings 에 적어라.
           특히 원격 저장소가 없어 로컬에만 존재하는 자산, 그리고 로컬에만 쌓이는 AI 대화 기록에 주의해라.
        4. summary 는 사용자가 먼저 읽을 2~3문장 요약이다.

        모든 답변은 한국어로 써라. relativePath 는 위 표에 있는 값을 그대로 써라.
        """
    }

    // MARK: - 2. 오류 진단

    struct Diagnosis: Codable {
        struct Step: Codable, Identifiable {
            var description: String
            /// 사용자가 직접 실행할 셸 명령. 없으면 빈 문자열.
            var command: String
            /// 되돌리기 어려운 작업인지. true 면 UI 에서 빨간 경고를 붙인다.
            var isDestructive: Bool

            var id: String { description }
        }

        var cause: String
        var severity: String        // "info" | "warning" | "critical"
        var steps: [Step]
        var canRetry: Bool
    }

    private static let diagnosisSchema = """
    {
      "type": "object",
      "properties": {
        "cause": { "type": "string" },
        "severity": { "type": "string", "enum": ["info", "warning", "critical"] },
        "steps": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "description": { "type": "string" },
              "command": { "type": "string" },
              "isDestructive": { "type": "boolean" }
            },
            "required": ["description", "command", "isDestructive"],
            "additionalProperties": false
          }
        },
        "canRetry": { "type": "boolean" }
      },
      "required": ["cause", "severity", "steps", "canRetry"],
      "additionalProperties": false
    }
    """

    static func diagnosisPrompt(operation: String, item: String?, logTail: String, volume: Volume?) -> String {
        """
        \(context(volume: volume))

        \(operation) 중 오류가 났다\(item.map { " (대상: \($0))" } ?? "").

        마지막 로그:
        ```
        \(logTail)
        ```

        할 일:
        - cause: 무엇 때문에 실패했는지 한두 문장으로. 로그에 근거가 없으면 추측이라고 밝혀라.
        - steps: 사용자가 밟을 조치를 순서대로. 각 단계의 command 는 그대로 복사해 실행할 수 있어야 한다.
          명령이 필요 없는 단계면 command 를 빈 문자열로 둬라.
          파일을 지우거나 덮어쓰는 단계는 isDestructive 를 true 로 해라.
        - canRetry: 조치 후 같은 작업을 그대로 재시도해도 되는지.

        한국어로 답해라. 확실하지 않은 것을 확실한 것처럼 쓰지 마라.
        """
    }

    // MARK: - 3. 자연어 명령

    struct CommandIntent: Codable {
        var action: String              // "backup" | "restore" | "scan" | "select" | "none"
        var includePaths: [String]
        var excludePaths: [String]
        var strategyOverrides: [StrategyOverride]
        var explanation: String
        /// 요청이 모호해서 되물어야 하면 채운다. 비어 있으면 바로 실행해도 된다.
        var clarification: String

        struct StrategyOverride: Codable, Identifiable {
            var relativePath: String
            var strategy: String
            var id: String { relativePath }
        }
    }

    private static let intentSchema = """
    {
      "type": "object",
      "properties": {
        "action": { "type": "string", "enum": ["backup", "restore", "scan", "select", "none"] },
        "includePaths": { "type": "array", "items": { "type": "string" } },
        "excludePaths": { "type": "array", "items": { "type": "string" } },
        "strategyOverrides": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "relativePath": { "type": "string" },
              "strategy": { "type": "string", "enum": ["rsync", "tarGz"] }
            },
            "required": ["relativePath", "strategy"],
            "additionalProperties": false
          }
        },
        "explanation": { "type": "string" },
        "clarification": { "type": "string" }
      },
      "required": ["action", "includePaths", "excludePaths", "strategyOverrides", "explanation", "clarification"],
      "additionalProperties": false
    }
    """

    static func intentPrompt(userText: String, items: [BackupItem], volume: Volume?) -> String {
        """
        \(context(volume: volume))

        선택 가능한 항목:
        \(itemTable(items))

        사용자가 이렇게 말했다:
        "\(userText)"

        이 말을 앱이 실행할 수 있는 형태로 옮겨라.

        - action: backup(백업 시작), restore(복원 시작), scan(크기 다시 측정),
          select(선택만 바꾸고 실행은 안 함), none(해당 없음)
        - includePaths / excludePaths: 위 표의 relativePath 값만 써라. 표에 없는 경로는 쓰지 마라.
        - strategyOverrides: 전략을 바꿔야 하는 항목만.
        - explanation: 무엇을 하려는 건지 사용자에게 확인시켜 줄 한 문장.
        - clarification: 요청이 모호하면 되물을 질문. 명확하면 빈 문자열.

        위험한 해석(예: "다 지워줘")은 action 을 none 으로 두고 clarification 에 되물어라.
        한국어로 답해라.
        """
    }

    // MARK: - 4. 복원 검증 리포트

    struct VerifyReport: Codable {
        var verdict: String             // "ok" | "partial" | "failed"
        var summary: String
        var missing: [String]
        var nextSteps: [String]
    }

    private static let verifySchema = """
    {
      "type": "object",
      "properties": {
        "verdict": { "type": "string", "enum": ["ok", "partial", "failed"] },
        "summary": { "type": "string" },
        "missing": { "type": "array", "items": { "type": "string" } },
        "nextSteps": { "type": "array", "items": { "type": "string" } }
      },
      "required": ["verdict", "summary", "missing", "nextSteps"],
      "additionalProperties": false
    }
    """

    static func verifyPrompt(manifest: Manifest, checks: [VerificationCheck]) -> String {
        let baseline = manifest.items.map { item in
            "- \(item.relativePath): 백업 당시 \(Fmt.bytes(item.sourceByteSize)), \(Fmt.count(item.sourceFileCount)) (\(item.strategy.rawValue))"
        }.joined(separator: "\n")

        let current = checks.map { check in
            "- \(check.label): \(check.passed ? "통과" : "실패") — \(check.detail)"
        }.joined(separator: "\n")

        return """
        \(context(volume: nil))

        복원 결과를 검증했다. 백업 시점 기준값과 지금 상태를 대조한 것이다.

        백업 시점 (\(manifest.createdAt.formatted())):
        \(baseline)

        지금 확인한 결과:
        \(current)

        할 일:
        - verdict: ok(모두 복원됨) / partial(일부 빠짐) / failed(핵심이 빠짐)
        - summary: 사용자가 먼저 읽을 2~3문장. 숫자를 근거로 들어라.
        - missing: 빠졌다고 판단되는 것들. 확실한 것만.
        - nextSteps: 지금 해야 할 일. 없으면 빈 배열.

        주의: 파일 수가 100% 일치하지 않는 것은 정상일 수 있다 (캐시가 다시 생기거나
        제외 패턴 집계 기준이 달라서). 2% 이내 차이는 문제로 보지 마라.
        한국어로 답해라.
        """
    }

    // MARK: - 호출

    static func requestPlanAdvice(
        client: CodexClient, items: [BackupItem], volume: Volume?, plan: BackupPlan,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlanAdvice {
        try await client.ask(
            PlanAdvice.self,
            prompt: planPrompt(items: items, volume: volume, plan: plan),
            schema: planSchema,
            onProgress: onProgress
        )
    }

    static func requestDiagnosis(
        client: CodexClient, operation: String, item: String?, logTail: String, volume: Volume?,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Diagnosis {
        try await client.ask(
            Diagnosis.self,
            prompt: diagnosisPrompt(operation: operation, item: item, logTail: logTail, volume: volume),
            schema: diagnosisSchema,
            onProgress: onProgress
        )
    }

    static func requestIntent(
        client: CodexClient, userText: String, items: [BackupItem], volume: Volume?,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandIntent {
        try await client.ask(
            CommandIntent.self,
            prompt: intentPrompt(userText: userText, items: items, volume: volume),
            schema: intentSchema,
            onProgress: onProgress
        )
    }

    static func requestVerifyReport(
        client: CodexClient, manifest: Manifest, checks: [VerificationCheck],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> VerifyReport {
        try await client.ask(
            VerifyReport.self,
            prompt: verifyPrompt(manifest: manifest, checks: checks),
            schema: verifySchema,
            onProgress: onProgress
        )
    }
}

/// 복원 후 기계적으로 확인한 항목 하나.
struct VerificationCheck: Identifiable, Hashable {
    var label: String
    var passed: Bool
    var detail: String

    var id: String { label }
}
