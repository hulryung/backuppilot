import Foundation

/// 기본 백업 계획을 만든다.
///
/// 규칙은 두 축으로 갈린다.
///  - **권한이 보존되어야 하는가** → 그렇다면 tar.gz. exFAT 은 chmod 를 버리므로
///    `~/.ssh/id_ed25519`(0600)를 평문 복사하면 복원 후 ssh 가 거부한다.
///  - **파일이 많은가** → 그렇다면 tar.gz. 128KB 할당 블록 + AppleDouble `._` 짝 때문에
///    작은 파일이 많은 트리는 평문 복사 시 용량이 몇 배로 부푼다.
/// 둘 다 아니면 평문 복사해서 Finder 로 바로 열람할 수 있게 둔다.
enum PlanBuilder {

    /// 파일이 이 개수를 넘으면 평문 복사가 아니라 아카이브로 돌린다.
    /// 5만 개 × 128KB = 6.4GB 가 내용과 무관하게 낭비되는 지점.
    static let manyFilesThreshold = 50_000

    /// 어디에나 붙는 제외 규칙. 재설치하면 다시 생기거나 다시 받는 것들이다.
    static let commonExcludes = [
        ".DS_Store", "._*", ".Spotlight-V100", ".fseventsd", ".Trashes",
        "node_modules", ".next", ".nuxt", "dist", "build",
        "target/debug", "target/release",
        ".venv", "venv", "__pycache__", "*.pyc",
        ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".gradle", ".ccls-cache", ".cache",
        "cmake-build-*", "*.o", "*.obj",
        "DerivedData", ".Trash"
    ]

    private struct Rule {
        var path: String
        var note: String
        var strategy: CopyStrategy
        var reason: StrategyReason
        var enabled: Bool = true
        var excludes: [String] = commonExcludes
    }

    /// 큐레이션된 규칙. 존재하지 않는 경로는 계획에서 빠진다.
    private static let rules: [Rule] = [
        // ── 자격증명·설정 (권한 보존 필수) ──
        Rule(path: ".ssh", note: "SSH 키 — 권한 0600 이 유지되어야 함",
             strategy: .tarGz, reason: .permissionSensitive, excludes: ["agent"]),
        Rule(path: ".gnupg", note: "GPG 키링",
             strategy: .tarGz, reason: .permissionSensitive, excludes: []),
        Rule(path: ".aws", note: "AWS 자격증명",
             strategy: .tarGz, reason: .permissionSensitive, excludes: []),
        Rule(path: ".config", note: "CLI 도구 설정 모음",
             strategy: .tarGz, reason: .permissionSensitive),

        // ── AI 대화 컨텍스트 (로컬에만 존재 — 잃으면 복구 불가) ──
        Rule(path: ".claude", note: "Claude Code 대화·메모리·스킬 — 로컬 전용",
             strategy: .tarGz, reason: .permissionSensitive,
             excludes: ["cache", "paste-cache", "shell-snapshots", "session-env",
                        "telemetry", "daemon.log", "plugins/cache"]),
        Rule(path: ".claude.json", note: "Claude 전역 설정 + 프로젝트 등록",
             strategy: .tarGz, reason: .permissionSensitive, excludes: []),
        Rule(path: ".codex", note: "Codex 세션·메모리 — 로컬 전용",
             strategy: .tarGz, reason: .permissionSensitive,
             excludes: ["cache", "ipc", "process_manager"]),
        Rule(path: ".gemini", note: "Gemini CLI 설정",
             strategy: .tarGz, reason: .permissionSensitive, excludes: ["cache"]),

        // ── 셸 설정 ──
        Rule(path: ".zshrc", note: "zsh 설정", strategy: .tarGz, reason: .permissionSensitive, excludes: []),
        Rule(path: ".zprofile", note: "zsh 프로파일", strategy: .tarGz, reason: .permissionSensitive, excludes: []),
        Rule(path: ".gitconfig", note: "git 전역 설정", strategy: .tarGz, reason: .permissionSensitive, excludes: []),

        // ── 소스 코드 (파일 수가 압도적) ──
        Rule(path: "dev", note: "개발 소스 — 최우선", strategy: .tarGz, reason: .manyFiles),
        Rule(path: "STM32Cube", note: "STM32 워크스페이스", strategy: .tarGz, reason: .manyFiles),

        // ── 사용자 데이터 (열람 가능하게 평문) ──
        Rule(path: "Documents", note: "문서", strategy: .rsync, reason: .browsable),
        Rule(path: "Desktop", note: "바탕화면", strategy: .rsync, reason: .browsable),
        Rule(path: "Pictures", note: "사진", strategy: .rsync, reason: .browsable),
        Rule(path: "Music", note: "음악", strategy: .rsync, reason: .browsable),
        Rule(path: "Downloads", note: "다운로드", strategy: .rsync, reason: .browsable),

        // ── Library 선별 ──
        Rule(path: "Library/Fonts", note: "설치한 폰트", strategy: .rsync, reason: .browsable, excludes: []),
        Rule(path: "Library/Preferences", note: "앱 환경설정", strategy: .tarGz, reason: .manyFiles, excludes: []),
        Rule(path: "Library/Application Support/Code/User",
             note: "VS Code 설정·스니펫", strategy: .tarGz, reason: .permissionSensitive, excludes: []),

        // ── 크고 선택적인 것 (기본 제외) ──
        Rule(path: "Movies", note: "동영상 — 용량이 큼", strategy: .rsync, reason: .browsable, enabled: false),
        Rule(path: "Parallels", note: "Parallels VM — 용량이 큼", strategy: .rsync, reason: .browsable, enabled: false)
    ]

    /// 홈 디렉터리를 훑어 실제로 존재하는 항목만으로 계획을 만든다.
    static func defaultPlan() -> BackupPlan {
        let home = Home.url
        let items = rules.compactMap { rule -> BackupItem? in
            let path = home.appendingPathComponent(rule.path).path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return BackupItem(
                relativePath: rule.path,
                note: rule.note,
                strategy: rule.strategy,
                reason: rule.reason,
                isEnabled: rule.enabled,
                excludes: rule.excludes
            )
        }
        return BackupPlan(items: items)
    }

    /// 측정 결과를 반영해 전략을 재조정한다.
    /// 파일 수는 재 보기 전에는 모르므로, 스캔이 끝난 뒤 한 번 더 판단한다.
    static func refineStrategies(_ plan: inout BackupPlan) {
        for index in plan.items.indices {
            // 사용자가 직접 정한 것은 건드리지 않는다.
            guard plan.items[index].reason != .userOverride,
                  plan.items[index].reason != .llmSuggested,
                  plan.items[index].reason != .permissionSensitive else { continue }

            guard let count = plan.items[index].fileCount else { continue }

            if count >= manyFilesThreshold, plan.items[index].strategy == .rsync {
                plan.items[index].strategy = .tarGz
                plan.items[index].reason = .manyFiles
            }
        }
    }
}
