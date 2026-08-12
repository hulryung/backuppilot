import SwiftUI

/// 백업본을 골라 홈 디렉터리로 되돌리고, 빠진 것이 없는지 검증하는 화면.
struct RestoreView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "복원",
                subtitle: "백업본을 홈 디렉터리로 되돌립니다"
            ) {
                HStack(spacing: 10) {
                    Button {
                        model.refreshBundles()
                    } label: {
                        Label("다시 검색", systemImage: "arrow.clockwise")
                    }

                    if model.restore.isRunning {
                        Button(role: .destructive) {
                            model.restore.cancel()
                        } label: {
                            Label("중단", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            showConfirm = true
                        } label: {
                            Label("복원 시작", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedBundle == nil || model.selectedForRestore.isEmpty)
                    }
                }
            }

            if model.bundles.isEmpty {
                emptyState
            } else {
                bundlePicker

                if let bundle = model.selectedBundle {
                    if !bundle.homePathMatches {
                        homePathWarning(bundle)
                    }
                    itemList(bundle)
                }

                if model.restore.isRunning {
                    progressPanel
                }

                if !model.restore.checks.isEmpty {
                    verificationPanel
                }

                if let diagnosis = model.diagnosis {
                    DiagnosisPanel(diagnosis: diagnosis) { model.diagnosis = nil }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                LogConsole(lines: model.restore.log)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                bottomBar
            }
        }
        .confirmationDialog(
            "복원을 시작할까요?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("시작") {
                Task { await model.startRestore() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("""
                \(model.selectedForRestore.count)개 항목을 \(Home.path) 로 되돌립니다.
                같은 이름의 파일은 덮어씁니다. 기존 파일을 지우지는 않습니다.
                """)
        }
    }

    // MARK: - 비어 있을 때

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("이 볼륨에서 BackupPilot 백업을 찾지 못했습니다")
                .font(.callout)
            Text(model.selectedVolume.map { "검색한 위치: \($0.url.path)" } ?? "대상 볼륨을 먼저 고르세요")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 백업본 선택

    private var bundlePicker: some View {
        HStack(spacing: 12) {
            Picker("백업본", selection: Binding(
                get: { model.selectedBundle?.id ?? "" },
                set: { id in
                    model.selectedBundle = model.bundles.first { $0.id == id }
                    if let bundle = model.selectedBundle {
                        model.selectedForRestore = Set(
                            bundle.manifest.items.filter(\.succeeded).map(\.relativePath)
                        )
                    }
                    model.restore.clearLog()
                }
            )) {
                ForEach(model.bundles) { bundle in
                    Text(label(for: bundle)).tag(bundle.id)
                }
            }
            .frame(maxWidth: 520)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func label(for bundle: BackupBundle) -> String {
        let date = bundle.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(bundle.displayName) — \(date), \(bundle.manifest.items.count)개 항목"
    }

    // MARK: - 홈 경로 경고

    private func homePathWarning(_ bundle: BackupBundle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("홈 경로가 다릅니다").font(.callout.weight(.medium))
                Text("""
                    백업 당시 \(bundle.manifest.homePath) → 현재 \(Home.path)
                    Claude Code 대화 기록은 프로젝트 절대경로로 색인되므로, 경로가 어긋나면 \
                    파일은 복원돼도 `claude --resume` 이 과거 세션을 찾지 못합니다.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 항목 목록

    private func itemList(_ bundle: BackupBundle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("복원할 항목").font(.callout.weight(.medium))
                Spacer()
                Button("모두 선택") {
                    model.selectedForRestore = Set(
                        bundle.manifest.items.filter(\.succeeded).map(\.relativePath)
                    )
                }
                .buttonStyle(.link)
                Button("모두 해제") { model.selectedForRestore = [] }
                    .buttonStyle(.link)
            }
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(bundle.manifest.items) { item in
                        itemRow(item)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func itemRow(_ item: Manifest.ManifestItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedForRestore.contains(item.relativePath) },
                set: { on in
                    if on { model.selectedForRestore.insert(item.relativePath) }
                    else { model.selectedForRestore.remove(item.relativePath) }
                }
            ))
            .labelsHidden()
            .disabled(!item.succeeded)

            Image(systemName: item.strategy.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.relativePath).font(.callout)
                Text("\(item.strategy.label) · \(Fmt.bytes(item.producedByteSize)) · 백업 당시 \(Fmt.count(item.sourceFileCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !item.succeeded {
                Label("백업 실패", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 진행률

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.restore.progress.currentItem.isEmpty ? "준비 중" : model.restore.progress.currentItem)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(model.restore.progress.itemIndex) / \(model.restore.progress.itemCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.restore.progress.overallFraction)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 검증

    private var verificationPanel: some View {
        let failed = model.restore.checks.filter { !$0.passed }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    failed.isEmpty ? "검증 통과" : "검증에서 \(failed.count)건이 걸렸습니다",
                    systemImage: failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(failed.isEmpty ? .green : .orange)

                Spacer()

                if model.isAsking {
                    ThinkingBadge(status: model.askingStatus)
                } else {
                    Button {
                        Task { await model.askForVerifyReport() }
                    } label: {
                        Label("Codex 리포트", systemImage: "text.badge.checkmark")
                    }
                    .disabled(!model.isCodexAvailable)
                }
            }

            if let report = model.verifyReport {
                VerifyReportPanel(report: report)
            }

            // 실패한 것만 펼쳐 보인다. 통과한 항목까지 나열하면 정작 중요한 게 묻힌다.
            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failed) { check in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("\(check.label) — \(check.detail)")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 하단

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.runVerification() }
            } label: {
                Label("복원 결과 검증", systemImage: "checkmark.shield")
            }
            .disabled(model.selectedBundle == nil || model.restore.isRunning)

            if let failure = model.restore.failure, !model.restore.isRunning {
                Divider().frame(height: 18)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button {
                    Task { await model.askForDiagnosis(operation: "복원") }
                } label: {
                    Label("진단", systemImage: "stethoscope")
                }
                .disabled(model.isAsking || !model.isCodexAvailable)
            }

            Spacer()

            if let bundle = model.selectedBundle {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bundle.url.path)
                } label: {
                    Label("Finder 에서 열기", systemImage: "folder")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - 검증 리포트

struct VerifyReportPanel: View {
    var report: Advisor.VerifyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verdictText)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(verdictColor.opacity(0.18))
                    .foregroundStyle(verdictColor)
                    .clipShape(Capsule())
                Text("Codex 요약").font(.caption).foregroundStyle(.secondary)
            }

            Text(report.summary)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !report.missing.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("빠진 것").font(.caption.weight(.medium))
                    ForEach(Array(report.missing.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: "minus.circle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if !report.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("다음 할 일").font(.caption.weight(.medium))
                    ForEach(Array(report.nextSteps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)").font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var verdictText: String {
        switch report.verdict {
        case "ok": return "정상"
        case "partial": return "일부 누락"
        default: return "실패"
        }
    }

    private var verdictColor: Color {
        switch report.verdict {
        case "ok": return .green
        case "partial": return .orange
        default: return .red
        }
    }
}
