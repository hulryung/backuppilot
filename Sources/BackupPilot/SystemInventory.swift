import Foundation

/// 이 맥에 무엇이 깔려 있는지 훑는다.
///
/// 백업 계획을 홈 디렉터리만 보고 세우면 놓치는 것이 생긴다. 어떤 앱이 설정·라이선스·프로필을
/// 홈 어디에 두는지는 앱마다 다르고, 그건 홈을 훑어서는 알 수 없다 — 이름만 봐서는
/// `Library/Application Support/` 아래 어느 디렉터리가 중요한지 판단이 안 선다.
/// 그래서 "무엇이 설치되어 있는가"를 따로 모아 조언의 근거로 넘긴다.
///
/// 원칙 두 가지:
///  - **읽기만 한다.** 목록을 뽑는 명령만 부르고 아무것도 바꾸지 않는다.
///  - **없는 도구는 조용히 건너뛴다.** Homebrew 가 없다고 조사 전체가 실패하면 안 된다.
///    대신 건너뛴 이유를 `skipped` 에 남겨 사용자가 빈 목록을 보고 헤매지 않게 한다.
enum SystemInventory {

    // MARK: - 결과

    struct Snapshot: Equatable {
        var osVersion: String = ""
        var brewFormulae: [String] = []
        var brewCasks: [String] = []
        var applications: [String] = []
        var appStoreApps: [String] = []
        var vscodeExtensions: [String] = []
        var globalPackages: [String] = []
        var launchAgents: [String] = []
        var homeConfigs: [String] = []
        /// 조사하지 못한 항목과 그 이유.
        var skipped: [String] = []

        /// 화면과 프롬프트가 같은 순서로 읽도록 한 곳에서 정의한다.
        var sections: [Section] {
            [
                Section("Homebrew formula", brewFormulae),
                Section("Homebrew cask", brewCasks),
                Section("응용 프로그램", applications),
                Section("App Store", appStoreApps),
                Section("VS Code 확장", vscodeExtensions),
                Section("전역 패키지", globalPackages),
                Section("로그인 항목", launchAgents),
                Section("홈 설정 디렉터리", homeConfigs)
            ]
        }

        var totalCount: Int { sections.reduce(0) { $0 + $1.items.count } }
        var isEmpty: Bool { totalCount == 0 }

        struct Section: Identifiable, Equatable {
            var label: String
            var items: [String]

            init(_ label: String, _ items: [String]) {
                self.label = label
                self.items = items
            }

            var id: String { label }
        }
    }

    // MARK: - 수집

    /// - Parameter onProgress: 지금 무엇을 읽고 있는지. UI 에 한 줄로 띄운다.
    static func collect(onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> Snapshot {
        var snapshot = Snapshot()
        snapshot.osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        onProgress("Homebrew 목록을 읽는 중")
        // `leaves` 는 다른 패키지의 의존성으로만 깔린 것을 뺀다 — 사용자가 직접 고른 것만 남는다.
        if let formulae = await lines("brew", "leaves") {
            snapshot.brewFormulae = formulae
            snapshot.brewCasks = await lines("brew", "list --cask -1") ?? []
        } else {
            snapshot.skipped.append("Homebrew — brew 를 찾지 못했습니다")
        }

        onProgress("응용 프로그램을 확인하는 중")
        snapshot.applications = applicationNames()

        onProgress("App Store 앱을 확인하는 중")
        if let listing = await lines("mas", "list") {
            snapshot.appStoreApps = listing.map(stripLeadingID)
        } else {
            snapshot.skipped.append("App Store — mas 가 설치되어 있지 않습니다 (brew install mas)")
        }

        onProgress("VS Code 확장을 확인하는 중")
        if let extensions = await vscodeExtensions() {
            snapshot.vscodeExtensions = extensions
        } else {
            snapshot.skipped.append("VS Code 확장 — code 명령을 찾지 못했습니다")
        }

        onProgress("전역 패키지를 확인하는 중")
        snapshot.globalPackages = await globalPackages()

        onProgress("로그인 항목과 홈 설정을 확인하는 중")
        snapshot.launchAgents = directoryEntries(at: Home.resolve("Library/LaunchAgents"))
            .filter { $0.hasSuffix(".plist") }
        snapshot.homeConfigs = homeConfigDirectories()

        return snapshot
    }

    // MARK: - 외부 도구

    /// GUI 앱은 로그인 셸의 PATH 를 물려받지 못한다. Codex 를 찾을 때와 같은 문제라
    /// 같은 방식으로 직접 뒤진다.
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private static func tool(_ name: String) -> String? {
        for directory in searchPaths {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 도구가 없거나 실패하면 nil. 목록이 비어 있는 것(`[]`)과 조사를 못 한 것(nil)은 다르다 —
    /// 전자는 "설치된 게 없다", 후자는 "확인할 방법이 없었다" 이고, 사용자에게 다르게 보여야 한다.
    private static func lines(_ toolName: String, _ arguments: String, limit: Int = 400) async -> [String]? {
        guard let path = tool(toolName) else { return nil }
        return await run("\(path.shellQuoted) \(arguments)", limit: limit)
    }

    private static func run(_ command: String, limit: Int) async -> [String]? {
        guard let result = try? await ProcessRunner.shell("\(command) 2>/dev/null"),
              result.succeeded else { return nil }
        let all: [String] = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(all.prefix(limit))
    }

    /// `mas list` 는 "497799835  Xcode  (26.6)" 형태로 나온다. 앞의 숫자 ID 는 조언에 쓸모가 없다.
    private static func stripLeadingID(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, Int(parts[0]) != nil else { return line }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    private static func vscodeExtensions() async -> [String]? {
        if let path = tool("code") {
            return await run("\(path.shellQuoted) --list-extensions", limit: 200)
        }
        // `code` 명령을 PATH 에 등록하지 않고 쓰는 사람이 많다. 번들 안을 직접 본다.
        let bundled = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        guard FileManager.default.isExecutableFile(atPath: bundled) else { return nil }
        return await run("\(bundled.shellQuoted) --list-extensions", limit: 200)
    }

    private static func globalPackages() async -> [String] {
        var packages: [String] = []

        // `npm ls -g --parseable` 은 경로를 뱉는다. 첫 줄은 루트 디렉터리라 이름이 아니다.
        if let paths = await lines("npm", "ls -g --depth=0 --parseable", limit: 200) {
            packages += paths.dropFirst().map { "npm: " + ($0 as NSString).lastPathComponent }
        }
        if let pipx = await lines("pipx", "list --short", limit: 200) {
            packages += pipx.map { "pipx: " + $0 }
        }
        // `cargo install --list` 는 레지스트리를 건드려 느릴 때가 있다. 설치 결과만 보면 충분하다.
        packages += directoryEntries(at: Home.resolve(".cargo/bin"))
            .filter { $0 != "cargo" && !$0.hasPrefix("rust") && $0 != "rustc" && $0 != "rustdoc" }
            .map { "cargo: " + $0 }

        return packages
    }

    // MARK: - 파일시스템

    private static func directoryEntries(at url: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return entries.filter { !$0.hasPrefix(".") || $0.hasSuffix(".plist") }.sorted()
    }

    private static func applicationNames() -> [String] {
        let roots = [URL(fileURLWithPath: "/Applications"), Home.resolve("Applications")]
        let names = roots.flatMap { root -> [String] in
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }
        return Array(Set(names)).sorted()
    }

    /// 홈 최상위의 점 디렉터리. 어떤 도구가 홈에 상태를 쌓고 있는지가 여기서 드러난다.
    private static func homeConfigDirectories() -> [String] {
        // 백업 판단에 도움이 안 되는 것들. 캐시이거나 macOS 가 알아서 다시 만든다.
        let noise: Set<String> = [".Trash", ".DS_Store", ".CFUserTextEncoding", ".localized"]

        let entries: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: Home.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []

        var names: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), !noise.contains(name) else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            names.append(name)
        }

        return Array(names.sorted().prefix(120))
    }
}
