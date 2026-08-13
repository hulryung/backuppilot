import Combine
import Foundation
import SwiftUI

/// 앱 전체 상태.
///
/// 엔진(백업/복원)은 각자 상태를 들고 있고, 여기서는 그것들을 묶고
/// Codex 와 주고받는 조언 상태를 관리한다.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 볼륨과 계획

    @Published var volumes: [Volume] = []
    @Published var selectedVolume: Volume?
    @Published var plan = BackupPlan(items: [])
    @Published var isScanning = false
    @Published var scanningItem: String?

    // MARK: - 엔진

    // `@Published` 로 두어도 소용없다. 참조가 바뀌는 일이 없으므로 절대 발행되지 않고,
    // 안쪽 객체가 바뀌어도 이 객체를 보는 뷰는 다시 그려지지 않는다.
    // 대신 아래 init 에서 두 엔진의 변경 알림을 이쪽으로 넘겨받는다.
    let backup = BackupEngine()
    let restore = RestoreEngine()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 복원 대상

    @Published var bundles: [BackupBundle] = []
    @Published var selectedBundle: BackupBundle?
    @Published var selectedForRestore: Set<String> = []

    // MARK: - Codex

    @Published var codexPath: String?
    @Published var isAsking = false
    /// Codex 가 지금 무엇을 하고 있는지 보여줄 한 줄.
    @Published var askingStatus: String = ""
    @Published var codexError: String?

    @Published var planAdvice: Advisor.PlanAdvice?
    @Published var diagnosis: Advisor.Diagnosis?
    @Published var verifyReport: Advisor.VerifyReport?

    // MARK: - 환경 조사

    @Published var inventory: SystemInventory.Snapshot?
    @Published var isSurveying = false
    /// 지금 무엇을 읽고 있는지. 조사는 외부 명령을 여러 번 부르므로 멈춘 것처럼 보이기 쉽다.
    @Published var surveyStatus = ""
    @Published var environmentAdvice: Advisor.EnvironmentAdvice?

    /// 어시스턴트 탭의 대화 기록.
    @Published var conversation: [ChatEntry] = []
    /// 사용자 승인을 기다리는 해석된 명령.
    @Published var pendingIntent: Advisor.CommandIntent?

    struct ChatEntry: Identifiable {
        enum Role { case user, assistant, system }
        let id = UUID()
        var role: Role
        var text: String
    }

    private var client: CodexClient? {
        codexPath.map { CodexClient(executablePath: $0) }
    }

    var isCodexAvailable: Bool { codexPath != nil }

    // MARK: - 초기화

    init() {
        refreshVolumes()
        plan = PlanBuilder.defaultPlan()
        codexPath = CodexClient.locate()

        // 엔진의 변경을 이 객체의 변경으로 되쏜다.
        // 이게 없으면 진행률과 로그가 화면에서 움직이지 않는다 — 다른 이유로 화면이
        // 다시 그려질 때만 갱신된 값이 얼떨결에 보인다.
        for publisher in [backup.objectWillChange, restore.objectWillChange] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - 볼륨

    func refreshVolumes() {
        volumes = VolumeScanner.scan()
        // 선택이 사라졌으면(언마운트) 외장 매체 중 첫 번째로 되돌린다.
        if let current = selectedVolume, !volumes.contains(where: { $0.id == current.id }) {
            selectedVolume = nil
        }
        if selectedVolume == nil {
            // 외장 매체 중 **여유 공간이 가장 큰** 것을 고른다.
            // 단순히 첫 번째를 집으면 macOS 설치 디스크나 앱 설치용 DMG 가 걸린다 —
            // 백업 대상으로는 최악의 선택이다.
            selectedVolume = volumes
                .filter { $0.isRemovable && !$0.isReadOnly }
                .max { $0.freeBytes < $1.freeBytes }
                ?? volumes.first { !$0.isReadOnly }
        }
        refreshBundles()
    }

    func refreshBundles() {
        guard let volume = selectedVolume else {
            bundles = []
            selectedBundle = nil
            return
        }
        bundles = RestoreEngine.discover(on: volume)
        if let current = selectedBundle, !bundles.contains(where: { $0.id == current.id }) {
            selectedBundle = nil
        }
        if selectedBundle == nil { selectedBundle = bundles.first }
        if let bundle = selectedBundle, selectedForRestore.isEmpty {
            selectedForRestore = Set(bundle.manifest.items.filter(\.succeeded).map(\.relativePath))
        }
    }

    // MARK: - 크기 측정

    /// 백업 대상의 크기와 파일 수를 잰다.
    ///
    /// 이걸 해야 용량 예측이 의미를 갖는다. 38만 개짜리 트리는 몇 분 걸릴 수 있다.
    func scanSizes() async {
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            scanningItem = nil
        }

        for index in plan.items.indices {
            guard plan.items[index].isEnabled, plan.items[index].exists else { continue }
            scanningItem = plan.items[index].relativePath
            if let measured = await SizeEstimator.measure(plan.items[index]) {
                plan.items[index].byteSize = measured.byteSize
                plan.items[index].fileCount = measured.fileCount
            }
        }

        // 파일 수를 알고 나면 전략을 다시 판단할 수 있다.
        PlanBuilder.refineStrategies(&plan)
    }

    // MARK: - 계획 편집

    func toggle(_ item: BackupItem) {
        guard let index = plan.items.firstIndex(where: { $0.id == item.id }) else { return }
        plan.items[index].isEnabled.toggle()
    }

    func setStrategy(_ strategy: CopyStrategy, for item: BackupItem, reason: StrategyReason = .userOverride) {
        guard let index = plan.items.firstIndex(where: { $0.id == item.id }) else { return }
        plan.items[index].strategy = strategy
        plan.items[index].reason = reason
    }

    /// 폴더를 직접 계획에 넣는다. 자동 탐지가 놓친 곳을 사용자가 보탤 수 있어야 한다.
    enum AddResult {
        case added(String)
        case outsideHome
        case duplicate(String)

        var message: String {
            switch self {
            case .added(let path):
                return "\(path) 를 계획에 추가했습니다. 「크기 측정」을 눌러 용량을 반영하세요."
            case .outsideHome:
                return "홈 디렉터리 안의 폴더만 추가할 수 있습니다. 이 도구는 홈만 옮깁니다."
            case .duplicate(let path):
                return "\(path) 는 이미 계획에 있습니다."
            }
        }
    }

    @discardableResult
    func addItem(at url: URL) -> AddResult {
        // 심볼릭 링크를 거쳐 들어온 경로도 홈 안인지 제대로 판정되도록 양쪽을 푼다.
        let home = Home.url.resolvingSymlinksInPath().path
        let target = url.resolvingSymlinksInPath().path

        guard target.hasPrefix(home + "/") else { return .outsideHome }
        let relative = String(target.dropFirst(home.count + 1))

        if let existing = plan.items.first(where: { $0.relativePath.lowercased() == relative.lowercased() }) {
            return .duplicate(existing.relativePath)
        }

        plan.items.append(BackupItem(
            relativePath: relative,
            note: "직접 추가한 항목",
            strategy: .rsync,
            // `.userOverride` 로 두면 크기 측정 후 전략 재조정에서 제외된다.
            // 방식을 고른 것이 아니라 대상을 고른 것이므로 재조정 대상으로 남긴다.
            reason: .browsable,
            excludes: PlanBuilder.commonExcludes,
            isSourceDirectory: PlanBuilder.looksLikeSource(url)
        ))
        return .added(relative)
    }

    // MARK: - Codex: 계획 상담

    func askForPlanAdvice() async {
        guard let client else {
            codexError = CodexClient.Failure.notInstalled.errorDescription
            return
        }
        guard !isAsking else { return }

        isAsking = true
        askingStatus = "Codex 가 계획을 검토하는 중"
        codexError = nil
        defer { isAsking = false; askingStatus = "" }

        do {
            let advice = try await Advisor.requestPlanAdvice(
                client: client,
                items: plan.items,
                volume: selectedVolume,
                plan: plan
            )
            planAdvice = advice
        } catch {
            codexError = error.localizedDescription
        }
    }

    /// 제안 하나를 계획에 반영한다. 사용자가 항목 단위로 수락/거절할 수 있게 한다.
    func apply(_ suggestion: Advisor.PlanAdvice.Suggestion) {
        guard let index = plan.items.firstIndex(where: { $0.relativePath == suggestion.relativePath }) else { return }
        plan.items[index].isEnabled = suggestion.include
        if let strategy = suggestion.parsedStrategy {
            plan.items[index].strategy = strategy
        }
        plan.items[index].reason = .llmSuggested
    }

    func applyAllSuggestions() {
        planAdvice?.suggestions.forEach(apply)
    }

    // MARK: - 환경 조사

    /// 설치된 소프트웨어 목록을 모은다. 읽기만 하므로 언제 눌러도 안전하다.
    func surveyEnvironment() async {
        guard !isSurveying else { return }
        isSurveying = true
        surveyStatus = "조사를 시작하는 중"
        defer { isSurveying = false; surveyStatus = "" }

        // 다시 조사했다는 것은 근거가 바뀌었다는 뜻이다. 옛 조언을 남겨 두면
        // 지금 목록에 대한 판단인 것처럼 읽힌다.
        environmentAdvice = nil

        inventory = await SystemInventory.collect { [weak self] status in
            Task { @MainActor in
                // 조사가 끝난 뒤 늦게 도착한 진행 상황이 빈 문자열을 덮어쓰지 않도록.
                guard let self, self.isSurveying else { return }
                self.surveyStatus = status
            }
        }
    }

    func askForEnvironmentAdvice() async {
        guard let client else {
            codexError = CodexClient.Failure.notInstalled.errorDescription
            return
        }
        guard let snapshot = inventory else { return }
        guard !isAsking else { return }

        isAsking = true
        askingStatus = "Codex 가 설치 목록을 살펴보는 중"
        codexError = nil
        defer { isAsking = false; askingStatus = "" }

        do {
            environmentAdvice = try await Advisor.requestEnvironmentAdvice(
                client: client,
                inventory: snapshot,
                items: plan.items,
                volume: selectedVolume
            )
        } catch {
            codexError = error.localizedDescription
        }
    }

    /// 추천받은 경로가 이미 계획에 있는지. UI 에서 중복 제안을 표시하는 데 쓴다.
    func planContains(_ relativePath: String) -> Bool {
        plan.items.contains { $0.relativePath == relativePath }
    }

    // MARK: - Codex: 오류 진단

    func askForDiagnosis(operation: String) async {
        guard let client else {
            codexError = CodexClient.Failure.notInstalled.errorDescription
            return
        }
        let failure = operation == "복원" ? restore.failure : backup.failure
        guard let failure else { return }
        guard !isAsking else { return }

        isAsking = true
        askingStatus = "Codex 가 로그를 읽는 중"
        codexError = nil
        defer { isAsking = false; askingStatus = "" }

        do {
            diagnosis = try await Advisor.requestDiagnosis(
                client: client,
                operation: operation,
                item: failure.itemPath,
                logTail: failure.logTail,
                volume: selectedVolume
            )
        } catch {
            codexError = error.localizedDescription
        }
    }

    // MARK: - Codex: 자연어 명령

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client else {
            codexError = CodexClient.Failure.notInstalled.errorDescription
            return
        }
        guard !isAsking else { return }

        conversation.append(ChatEntry(role: .user, text: trimmed))
        isAsking = true
        askingStatus = "Codex 가 해석하는 중"
        codexError = nil
        defer { isAsking = false; askingStatus = "" }

        do {
            let intent = try await Advisor.requestIntent(
                client: client,
                userText: trimmed,
                items: plan.items,
                volume: selectedVolume
            )

            if !intent.clarification.isEmpty {
                conversation.append(ChatEntry(role: .assistant, text: intent.clarification))
                pendingIntent = nil
            } else {
                conversation.append(ChatEntry(role: .assistant, text: intent.explanation))
                // 실행은 사용자가 승인한 뒤에. 모델이 해석했다는 이유로 바로 돌리지 않는다.
                pendingIntent = intent
            }
        } catch {
            codexError = error.localizedDescription
            conversation.append(ChatEntry(role: .system, text: "해석 실패: \(error.localizedDescription)"))
        }
    }

    /// 승인된 명령을 계획에 반영한다. 실제 백업/복원 실행은 별도 버튼으로 남긴다.
    func applyPendingIntent() {
        guard let intent = pendingIntent else { return }

        for path in intent.includePaths {
            if let index = plan.items.firstIndex(where: { $0.relativePath == path }) {
                plan.items[index].isEnabled = true
            }
        }
        for path in intent.excludePaths {
            if let index = plan.items.firstIndex(where: { $0.relativePath == path }) {
                plan.items[index].isEnabled = false
            }
        }
        for override in intent.strategyOverrides {
            if let index = plan.items.firstIndex(where: { $0.relativePath == override.relativePath }),
               let strategy = CopyStrategy(rawValue: override.strategy) {
                plan.items[index].strategy = strategy
                plan.items[index].reason = .llmSuggested
            }
        }

        conversation.append(ChatEntry(role: .system, text: "계획에 반영했습니다."))
        pendingIntent = nil
    }

    func discardPendingIntent() {
        pendingIntent = nil
        conversation.append(ChatEntry(role: .system, text: "취소했습니다."))
    }

    // MARK: - Codex: 검증 리포트

    func askForVerifyReport() async {
        guard let client, let bundle = selectedBundle else { return }
        guard !restore.checks.isEmpty else { return }
        guard !isAsking else { return }

        isAsking = true
        askingStatus = "Codex 가 검증 결과를 정리하는 중"
        codexError = nil
        defer { isAsking = false; askingStatus = "" }

        do {
            verifyReport = try await Advisor.requestVerifyReport(
                client: client,
                manifest: bundle.manifest,
                checks: restore.checks
            )
        } catch {
            codexError = error.localizedDescription
        }
    }

    // MARK: - 실행

    func startBackup() async {
        guard let volume = selectedVolume else { return }
        backup.clearLog()
        diagnosis = nil
        await backup.run(plan: plan, to: volume)
        refreshBundles()
    }

    func startRestore() async {
        guard let bundle = selectedBundle else { return }
        restore.clearLog()
        diagnosis = nil
        verifyReport = nil
        await restore.restore(bundle: bundle, selected: selectedForRestore)
    }

    func runVerification() async {
        guard let bundle = selectedBundle else { return }
        await restore.verify(bundle: bundle)
    }
}
