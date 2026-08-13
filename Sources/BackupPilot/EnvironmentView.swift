import SwiftUI

/// 설치된 소프트웨어를 근거로 백업 대상을 제안받는 화면.
///
/// "계획" 탭의 상담과 무엇이 다른가: 그쪽은 이미 계획에 올라온 홈 디렉터리 항목만 보고
/// 방식을 조정한다. 여기서는 **무엇이 설치되어 있는가**에서 출발해, 홈을 훑어서는
/// 존재조차 알기 어려운 경로(앱이 설정을 숨겨 두는 곳)를 짚어내는 것이 목적이다.
struct EnvironmentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "환경 조사",
                subtitle: "이 맥에 설치된 것을 근거로 백업 대상을 제안받습니다"
            ) {
                HStack(spacing: 10) {
                    Button {
                        Task { await model.surveyEnvironment() }
                    } label: {
                        Label(model.inventory == nil ? "환경 조사" : "다시 조사",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(model.isSurveying)

                    Button {
                        Task { await model.askForEnvironmentAdvice() }
                    } label: {
                        Label("Codex 에게 의견 묻기", systemImage: "sparkles")
                    }
                    .disabled(model.inventory == nil || model.isSurveying
                              || model.isAsking || !model.isCodexAvailable)
                }
            }

            statusStrip

            if let inventory = model.inventory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        inventoryCard(inventory)

                        if let advice = model.environmentAdvice {
                            adviceView(advice)
                        } else if !model.isAsking {
                            nextStepHint
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - 진행/오류

    @ViewBuilder
    private var statusStrip: some View {
        if model.isSurveying || model.isAsking {
            HStack {
                ThinkingBadge(status: model.isSurveying ? model.surveyStatus : model.askingStatus)
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
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("아직 조사하지 않았습니다")
                .font(.title3.weight(.medium))
            Text("설치된 Homebrew 패키지·응용 프로그램·확장을 읽어 목록을 만듭니다.\n읽기만 하며 아무것도 바꾸지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("환경 조사 시작") {
                Task { await model.surveyEnvironment() }
            }
            .disabled(model.isSurveying)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nextStepHint: some View {
        Label(
            model.isCodexAvailable
                ? "「Codex 에게 의견 묻기」 를 누르면 이 목록을 근거로 백업 대상을 제안받습니다."
                : "Codex 가 없어 제안을 받을 수 없습니다. 목록만 참고하세요.",
            systemImage: model.isCodexAvailable ? "arrow.up.circle" : "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - 조사 결과

    private func inventoryCard(_ inventory: SystemInventory.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("조사 결과").font(.headline)
                Text("\(inventory.totalCount)개 항목")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(inventory.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 무엇이 전송되는지 사용자가 먼저 볼 수 있어야 한다. 목록을 접어 두더라도
            // "이게 나간다"는 사실은 접지 않는다.
            Label("아래 목록이 Codex 로 전송됩니다. 파일 내용은 보내지 않습니다.",
                  systemImage: "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(inventory.sections.filter { !$0.items.isEmpty }) { section in
                DisclosureGroup {
                    Text(section.items.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text(section.label).font(.callout.weight(.medium))
                        Text("\(section.items.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !inventory.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(inventory.skipped, id: \.self) { note in
                        Label(note, systemImage: "minus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Codex 제안

    private func adviceView(_ advice: Advisor.EnvironmentAdvice) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(advice.summary)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if advice.recommendations.isEmpty {
                Label("추가로 백업할 것이 없다고 판단했습니다", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("백업 제안 \(advice.recommendations.count)건").font(.headline)
                    ForEach(advice.recommendations.sorted { $0.level < $1.level }) { item in
                        recommendationRow(item)
                    }
                }
            }

            droppedNote

            if !advice.reinstallInstead.isEmpty {
                listSection(
                    title: "백업하지 않아도 되는 것",
                    caption: "재설치로 돌아옵니다",
                    symbol: "arrow.down.circle",
                    tint: .secondary,
                    entries: advice.reinstallInstead
                )
            }

            if !advice.cautions.isEmpty {
                listSection(
                    title: "파일로는 돌아오지 않는 것",
                    caption: "재로그인·라이선스 키가 필요합니다",
                    symbol: "exclamationmark.triangle",
                    tint: .orange,
                    entries: advice.cautions
                )
            }
        }
    }

    /// 홈에 없어서 버린 제안이 있었다는 사실만 조용히 남긴다.
    ///
    /// 아예 말하지 않으면 "제안이 3건뿐이네" 로 읽히고, 크게 띄우면 정작 쓸 만한
    /// 제안보다 눈에 띈다. 접어 두되 개수는 보이게 하는 편이 맞다.
    @ViewBuilder
    private var droppedNote: some View {
        if !model.droppedRecommendations.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.droppedRecommendations, id: \.self) { path in
                        Text("~/" + path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("홈에 없는 경로 \(model.droppedRecommendations.count)건은 제외했습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func listSection(
        title: String, caption: String, symbol: String, tint: Color, entries: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { entry in
                Label(entry, systemImage: symbol)
                    .font(.callout)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
            }
        }
    }

    private func recommendationRow(_ item: Advisor.EnvironmentAdvice.Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.title).font(.callout.weight(.medium))
                chip(item.level.label, tint: color(for: item.level))
                if let strategy = item.parsedStrategy {
                    chip(strategy.label, tint: .accentColor)
                }
                Spacer()
                statusChip(for: item.path)
            }

            Text("~/" + item.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(item.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 제안받은 경로가 실제로 어떤 상태인지.
    ///
    /// "홈에 없음"이 특히 중요하다 — 모델이 그럴듯한 경로를 지어낸 경우가 여기서 드러난다.
    @ViewBuilder
    private func statusChip(for path: String) -> some View {
        if model.planContains(path) {
            chip("이미 계획에 있음", tint: .secondary)
        } else if FileManager.default.fileExists(atPath: Home.resolve(path).path) {
            chip("홈에 있음", tint: .green)
        } else {
            chip("홈에 없음", tint: .orange)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }

    private func color(for level: Advisor.EnvironmentAdvice.Importance) -> Color {
        switch level {
        case .critical: return .red
        case .recommended: return .accentColor
        case .optional: return .secondary
        }
    }
}
