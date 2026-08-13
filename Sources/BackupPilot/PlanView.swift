import AppKit
import SwiftUI

/// 무엇을 어떤 방식으로 백업할지 정하는 화면.
struct PlanView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAdvice = false
    /// 소스 디렉터리 경고를 닫았는지. 사용자가 알고도 넘어가는 선택을 존중한다.
    @State private var dismissedSourceWarning = false
    /// 폴더 추가 결과를 한 줄로 알린다.
    @State private var addNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "백업 계획",
                subtitle: "무엇을 어떤 방식으로 옮길지 정합니다"
            ) {
                HStack(spacing: 10) {
                    Button {
                        presentFolderPicker()
                    } label: {
                        Label("폴더 추가", systemImage: "folder.badge.plus")
                    }
                    .help("자동으로 잡히지 않은 폴더를 계획에 넣습니다")

                    Button {
                        Task { await model.scanSizes() }
                    } label: {
                        Label("크기 측정", systemImage: "ruler")
                    }
                    .disabled(model.isScanning)

                    Button {
                        Task {
                            await model.askForPlanAdvice()
                            showAdvice = model.planAdvice != nil
                        }
                    } label: {
                        Label("Codex 에게 상담", systemImage: "sparkles")
                    }
                    .disabled(model.isAsking || !model.isCodexAvailable)
                }
            }

            destinationBar

            sourceWarning

            if let notice = addNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice).font(.callout)
                    Spacer()
                    Button { addNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if model.isScanning || model.isAsking {
                HStack {
                    ThinkingBadge(status: model.isScanning
                        ? "크기 측정 중 — \(model.scanningItem ?? "")"
                        : model.askingStatus)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if let error = model.codexError {
                ErrorBanner(message: error) { model.codexError = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            itemTable

            summaryBar
        }
        .sheet(isPresented: $showAdvice) {
            if let advice = model.planAdvice {
                PlanAdviceSheet(advice: advice)
                    .environmentObject(model)
            }
        }
    }

    // MARK: - 대상 볼륨

    private var destinationBar: some View {
        HStack(spacing: 12) {
            Picker("대상", selection: Binding(
                get: { model.selectedVolume?.id ?? "" },
                set: { id in
                    model.selectedVolume = model.volumes.first { $0.id == id }
                    model.refreshBundles()
                }
            )) {
                Text("선택 안 됨").tag("")
                ForEach(model.volumes) { volume in
                    Text("\(volume.name) — \(volume.fileSystem), 여유 \(Fmt.bytes(volume.freeBytes))")
                        .tag(volume.id)
                }
            }
            .frame(maxWidth: 460)

            Button {
                model.refreshVolumes()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("볼륨 다시 검색")

            Spacer()

            if let volume = model.selectedVolume, volume.isPermissionLossy {
                Label(
                    "exFAT — 권한이 보존되지 않아 민감한 항목은 tar.gz 로 묶습니다",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 소스 디렉터리 경고

    /// 소스로 보이는 것을 하나도 찾지 못했으면 알린다.
    ///
    /// 이 경고가 필요한 이유: 계획은 존재하지 않는 경로를 조용히 버린다. 소스를
    /// 흔치 않은 이름의 폴더에 두었다면 가장 중요한 것이 아무 표시 없이 빠지고,
    /// 사용자는 백업이 끝난 뒤에야 알게 된다.
    @ViewBuilder
    private var sourceWarning: some View {
        if model.plan.lacksSourceDirectory && !dismissedSourceWarning {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("소스 디렉터리를 찾지 못했습니다")
                        .font(.callout.weight(.medium))
                    Text("홈에서 git 저장소를 품은 폴더를 찾지 못했습니다. 소스를 다른 곳에 두었다면 「폴더 추가」로 직접 넣으세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("폴더 추가") { presentFolderPicker() }
                Button { dismissedSourceWarning = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Home.url
        panel.prompt = "추가"
        panel.message = "백업에 추가할 폴더를 고르세요. 홈 디렉터리 안에 있어야 합니다."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addNotice = model.addItem(at: url).message
    }

    // MARK: - 항목 표

    private var itemTable: some View {
        Table(model.plan.items) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in model.toggle(item) }
                ))
                .labelsHidden()
            }
            .width(28)

            TableColumn("경로") { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.relativePath)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(item.isEnabled ? .primary : .secondary)
                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 200, ideal: 260)

            TableColumn("크기") { item in
                Text(Fmt.bytes(item.byteSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("파일 수") { item in
                Text(Fmt.count(item.fileCount))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(100)

            TableColumn("방식") { item in
                Picker("", selection: Binding(
                    get: { item.strategy },
                    set: { model.setStrategy($0, for: item) }
                )) {
                    ForEach(CopyStrategy.allCases) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .width(120)

            TableColumn("근거") { item in
                Text(item.reason.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: 180, ideal: 280)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 요약

    private var summaryBar: some View {
        let estimated = model.plan.estimatedDestinationBytes(on: model.selectedVolume)
        let free = model.selectedVolume?.freeBytes ?? 0
        let fits = estimated <= free
        let measured = model.plan.enabledItems.contains { $0.byteSize != nil }

        return HStack(spacing: 22) {
            stat("선택", "\(model.plan.enabledItems.count)개 항목")
            stat("원본", Fmt.bytes(model.plan.totalSourceBytes))
            stat("파일", Fmt.count(model.plan.totalFileCount))

            VStack(alignment: .leading, spacing: 2) {
                Text("예상 사용량").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(Fmt.bytes(estimated))
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(fits ? .primary : Color.red)
                    if measured, let volume = model.selectedVolume, volume.isPermissionLossy {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("exFAT 할당 블록(\(volume.allocationBlockSize / 1024)KB)과 AppleDouble 파일을 감안한 보수적 추정입니다")
                    }
                }
            }

            stat("여유", Fmt.bytes(free))

            Spacer()

            if !measured {
                Text("크기를 측정해야 예측이 정확해집니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !fits {
                Label("공간이 부족합니다", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium).monospacedDigit())
        }
    }
}

// MARK: - Codex 제안 시트

struct PlanAdviceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var advice: Advisor.PlanAdvice

    @State private var applied: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Codex 의 검토", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(advice.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !advice.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("주의").font(.headline)
                            ForEach(Array(advice.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if advice.suggestions.isEmpty {
                        Label("바꿀 것이 없다고 판단했습니다", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("제안 \(advice.suggestions.count)건").font(.headline)
                                Spacer()
                                Button("모두 적용") {
                                    model.applyAllSuggestions()
                                    applied = Set(advice.suggestions.map(\.relativePath))
                                }
                            }

                            ForEach(advice.suggestions) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 660, height: 560)
    }

    private func suggestionRow(_ suggestion: Advisor.PlanAdvice.Suggestion) -> some View {
        let isApplied = applied.contains(suggestion.relativePath)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.relativePath).font(.callout.weight(.medium))
                    Text(suggestion.include ? "포함" : "제외")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(suggestion.include ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    if let strategy = suggestion.parsedStrategy {
                        Text(strategy.label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(suggestion.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(isApplied ? "적용됨" : "적용") {
                model.apply(suggestion)
                applied.insert(suggestion.relativePath)
            }
            .disabled(isApplied)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
