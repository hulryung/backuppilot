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

    /// 자동 탐지가 디렉터리 하나에서 확인할 하위 항목 수 상한.
    /// 앱 시작 시 동기적으로 도는 코드라 무한정 뒤질 수 없다.
    static let shallowScanLimit = 200

    private struct Rule {
        var path: String
        var note: String
        var strategy: CopyStrategy
        var reason: StrategyReason
        var enabled: Bool = true
        var excludes: [String] = commonExcludes
        /// 소스 코드 디렉터리 후보인지.
        var isSource: Bool = false
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
        // 소스를 홈 어디에 두는지는 사람마다 다르다. 흔한 이름을 후보로 올려 두되,
        // 이 목록에 없는 이름은 아래 `discoverSourceDirectories` 가 내용으로 찾아낸다.
        // 대소문자만 다른 이름을 함께 넣지 말 것 — macOS 파일시스템은 기본이 대소문자 무시라
        // `Projects` 와 `projects` 가 같은 디렉터리를 두 번 가리키게 된다.
        Rule(path: "dev", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "src", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "Projects", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "Developer", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "code", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "work", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "repos", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),
        Rule(path: "workspace", note: "개발 소스", strategy: .tarGz, reason: .manyFiles, isSource: true),

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
        var items: [BackupItem] = []
        // 대소문자를 무시해서 담는다. `fileExists` 는 대소문자 무시 파일시스템에서
        // `~/projects` 를 `~/Projects` 로도 찾아 주므로, 이 방어가 없으면 같은
        // 디렉터리가 두 항목으로 들어가 두 번 백업된다.
        var seen = Set<String>()

        for rule in rules {
            let url = home.appendingPathComponent(rule.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard seen.insert(rule.path.lowercased()).inserted else { continue }
            items.append(BackupItem(
                relativePath: rule.path,
                note: rule.note,
                strategy: rule.strategy,
                reason: rule.reason,
                isEnabled: rule.enabled,
                excludes: rule.excludes,
                isSourceDirectory: rule.isSource
            ))
        }

        items += discoverSourceDirectories(excluding: seen)
        return BackupPlan(items: items)
    }

    // MARK: - 자동 탐지

    /// 홈 최상위에서 소스 디렉터리로 보이는 것을 찾는다.
    ///
    /// 위의 이름 목록은 흔한 관례를 담았을 뿐이고, 실제로 쓰는 이름은 그보다 다양하다.
    /// 그래서 이름이 아니라 **내용**으로 판정한다 — 안에 git 저장소가 있으면 소스 디렉터리다.
    /// 이름 목록에만 의존하면 `~/mycompany` 에 소스를 둔 사람은 가장 중요한 것을
    /// 백업하지 못한 채 아무 경고도 못 받는다.
    static func discoverSourceDirectories(excluding seen: Set<String>) -> [BackupItem] {
        // macOS 표준 디렉터리와 클라우드 동기화 폴더는 보지 않는다.
        // 여기에 git 저장소가 있더라도 소스 보관처로 다루는 것은 맞지 않고,
        // 동기화 폴더는 어차피 원격에 사본이 있다.
        let ignored: Set<String> = [
            "documents", "desktop", "downloads", "library", "movies", "music",
            "pictures", "public", "applications", "sites", "parallels",
            "virtual machines", "vmware", "dropbox", "onedrive", "google drive",
            "icloud drive", "creative cloud files"
        ]

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Home.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [BackupItem] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let key = name.lowercased()
            guard !ignored.contains(key), !seen.contains(key) else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard looksLikeSource(entry) else { continue }

            found.append(BackupItem(
                relativePath: name,
                note: "git 저장소가 있어 소스 디렉터리로 판단했습니다",
                strategy: .tarGz,
                reason: .manyFiles,
                excludes: commonExcludes,
                isSourceDirectory: true
            ))
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    /// 이 디렉터리가 git 저장소를 품고 있는가.
    /// 자기 자신이 저장소이거나, 바로 아래 하위 디렉터리 중 하나가 저장소이면 참으로 본다.
    ///
    /// 깊이 1단계에서 멈추는 것은 의도적이다. 앱 시작을 막는 동기 호출이라
    /// 전부 재귀로 뒤지면 홈에 큰 트리가 있을 때 창이 뜨는 데만 몇 초가 걸린다.
    static func looksLikeSource(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }

        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        for child in children.prefix(shallowScanLimit) {
            if fm.fileExists(atPath: child.appendingPathComponent(".git").path) { return true }
        }
        return false
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
