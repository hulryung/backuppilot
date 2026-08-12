import SwiftUI

/// 백업을 실행하고 진행 상황을 보는 화면.
struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "백업 실행",
                subtitle: model.selectedVolume.map { "\($0.name) (\($0.url.path)) 로 복사합니다" }
                    ?? "대상 볼륨을 먼저 고르세요"
            ) {
                HStack(spacing: 10) {
                    if model.backup.isRunning {
                        Button(role: .destructive) {
                            model.backup.cancel()
                        } label: {
                            Label("중단", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            showConfirm = true
                        } label: {
                            Label("백업 시작", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedVolume == nil || model.plan.enabledItems.isEmpty)
                    }
                }
            }

            if model.backup.isRunning {
                progressPanel
            }

            if let failure = model.backup.failure, !model.backup.isRunning {
                failurePanel(failure)
            }

            if let diagnosis = model.diagnosis {
                DiagnosisPanel(diagnosis: diagnosis) { model.diagnosis = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            LogConsole(lines: model.backup.log)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            if let manifest = model.backup.lastManifest, !model.backup.isRunning {
                resultBar(manifest)
            }
        }
        .confirmationDialog(
            "백업을 시작할까요?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("시작") {
                Task { await model.startBackup() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            let estimated = model.plan.estimatedDestinationBytes(on: model.selectedVolume)
            Text("""
                \(model.plan.enabledItems.count)개 항목, 예상 \(Fmt.bytes(estimated))
                대상: \(model.selectedVolume?.url.path ?? "—")
                """)
        }
    }

    // MARK: - 진행률

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.backup.progress.currentItem.isEmpty
                     ? "준비 중"
                     : model.backup.progress.currentItem)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(model.backup.progress.itemIndex) / \(model.backup.progress.itemCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: model.backup.progress.overallFraction)

            if let fraction = model.backup.progress.itemFraction {
                HStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 180)
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("진행 중 — 이 항목은 진행률을 알 수 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 실패

    private func failurePanel(_ failure: BackupEngine.Failure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text(failure.itemPath.map { "\($0) 에서 실패" } ?? "백업 실패")
                    .font(.callout.weight(.medium))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            if model.isAsking {
                ThinkingBadge(status: model.askingStatus)
            } else {
                Button {
                    Task { await model.askForDiagnosis(operation: "백업") }
                } label: {
                    Label("Codex 에게 진단 요청", systemImage: "stethoscope")
                }
                .disabled(!model.isCodexAvailable)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 결과

    private func resultBar(_ manifest: Manifest) -> some View {
        let succeeded = manifest.items.filter(\.succeeded)
        let logical = manifest.items.reduce(Int64(0)) { $0 + $1.producedByteSize }
        let allocated = manifest.items.reduce(Int64(0)) { $0 + ($1.producedAllocatedBytes ?? $1.producedByteSize) }
        let elapsed = manifest.items.reduce(0.0) { $0 + $1.durationSeconds }
        let inflated = allocated > logical * 2 && logical > 0

        return HStack(spacing: 22) {
            Label("\(succeeded.count) / \(manifest.items.count) 항목", systemImage: "checkmark.circle")
                .foregroundStyle(succeeded.count == manifest.items.count ? .green : .orange)

            HStack(spacing: 5) {
                Text("디스크 사용 \(Fmt.bytes(allocated))").foregroundStyle(.secondary)
                if inflated {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("내용은 \(Fmt.bytes(logical)) 인데 \(Fmt.bytes(allocated)) 를 차지했습니다 — exFAT 할당 블록 때문입니다")
                }
            }

            Text("소요 \(Fmt.duration(elapsed))").foregroundStyle(.secondary)

            Spacer()

            Button {
                NSWorkspace.shared.selectFile(
                    nil,
                    inFileViewerRootedAtPath: manifest.destinationPath
                )
            } label: {
                Label("Finder 에서 열기", systemImage: "folder")
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - 진단 패널

/// Codex 가 낸 오류 진단. 명령은 복사만 되고, 앱이 자동으로 실행하지 않는다.
struct DiagnosisPanel: View {
    var diagnosis: Advisor.Diagnosis
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Codex 진단", systemImage: "stethoscope")
                    .font(.callout.weight(.semibold))
                severityBadge
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            Text(diagnosis.cause)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !diagnosis.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(diagnosis.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index + 1, step: step)
                    }
                }
            }

            if diagnosis.canRetry {
                Label("조치 후 같은 작업을 재시도해도 됩니다", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var severityBadge: some View {
        let (text, color): (String, Color) = switch diagnosis.severity {
        case "critical": ("심각", .red)
        case "warning": ("주의", .orange)
        default: ("정보", .secondary)
        }

        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func stepRow(index: Int, step: Advisor.Diagnosis.Step) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(step.description)
                    .font(.callout)
                    .textSelection(.enabled)
                if step.isDestructive {
                    Label("되돌리기 어려움", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            if !step.command.isEmpty {
                HStack(spacing: 8) {
                    Text(step.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(step.command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("복사 — 터미널에서 직접 실행하세요")
                }
                .padding(.leading, 22)
            }
        }
    }
}
