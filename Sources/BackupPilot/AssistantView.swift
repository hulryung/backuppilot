import SwiftUI

/// 자연어로 계획을 바꾸는 화면.
///
/// 여기서 모델이 하는 일은 "해석"까지다. 해석 결과는 사용자가 승인해야 계획에 반영되고,
/// 백업/복원 실행은 각 탭의 버튼으로만 시작된다. 되돌리기 어려운 작업을
/// 문장 한 줄로 시작하게 두지 않기 위해서다.
struct AssistantView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""
    @FocusState private var isInputFocused: Bool

    private let examples = [
        "Downloads 는 빼고 백업해줘",
        "dev 는 평문으로 복사해줘",
        "사진이랑 문서만 골라줘",
        "용량을 줄이려면 뭘 빼면 될까?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "어시스턴트",
                subtitle: "하고 싶은 것을 말하면 계획으로 옮겨 줍니다"
            ) {
                if !model.conversation.isEmpty {
                    Button {
                        model.conversation.removeAll()
                        model.pendingIntent = nil
                    } label: {
                        Label("대화 지우기", systemImage: "trash")
                    }
                }
            }

            if !model.isCodexAvailable {
                unavailableBanner
            }

            transcript

            if let intent = model.pendingIntent {
                IntentApprovalPanel(intent: intent) {
                    model.applyPendingIntent()
                } onDiscard: {
                    model.discardPendingIntent()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            if let error = model.codexError {
                ErrorBanner(message: error) { model.codexError = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            inputBar
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - Codex 없음

    private var unavailableBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.slash").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex CLI 를 찾지 못했습니다").font(.callout.weight(.medium))
                Text("`brew install codex` 로 설치하고 `codex login` 으로 로그인한 뒤 앱을 다시 실행하세요. Codex 없이도 백업과 복원은 그대로 됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - 대화

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.conversation.isEmpty {
                        emptyState
                    }
                    ForEach(model.conversation) { entry in
                        messageBubble(entry).id(entry.id)
                    }
                    if model.isAsking {
                        ThinkingBadge(status: model.askingStatus)
                            .padding(.leading, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.conversation.count) {
                guard let last = model.conversation.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이렇게 말해 보세요")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(examples, id: \.self) { example in
                Button {
                    input = example
                    isInputFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote").font(.caption).foregroundStyle(.secondary)
                        Text(example).font(.callout)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    private func messageBubble(_ entry: AppModel.ChatEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: entry.role))
                .font(.callout)
                .foregroundStyle(color(for: entry.role))
                .frame(width: 18)

            Text(entry.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(background(for: entry.role))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func icon(for role: AppModel.ChatEntry.Role) -> String {
        switch role {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .system: return "info.circle"
        }
    }

    private func color(for role: AppModel.ChatEntry.Role) -> Color {
        switch role {
        case .user: return .secondary
        case .assistant: return .accentColor
        case .system: return .secondary
        }
    }

    private func background(for role: AppModel.ChatEntry.Role) -> Color {
        switch role {
        case .user: return Color(nsColor: .controlBackgroundColor)
        case .assistant: return Color.accentColor.opacity(0.08)
        case .system: return Color.secondary.opacity(0.08)
        }
    }

    // MARK: - 입력

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("하고 싶은 것을 적어 주세요", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty
                      || model.isAsking
                      || !model.isCodexAvailable)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func submit() {
        let text = input
        input = ""
        Task { await model.send(text) }
    }
}

// MARK: - 해석 결과 승인

/// Codex 가 해석한 명령을 사용자가 확인하고 승인하는 패널.
struct IntentApprovalPanel: View {
    var intent: Advisor.CommandIntent
    var onApply: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("이대로 반영할까요?", systemImage: "checkmark.circle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("취소", role: .cancel, action: onDiscard)
                Button("반영", action: onApply).buttonStyle(.borderedProminent)
            }

            if !intent.includePaths.isEmpty {
                changeRow(label: "포함", items: intent.includePaths, color: .green)
            }
            if !intent.excludePaths.isEmpty {
                changeRow(label: "제외", items: intent.excludePaths, color: .secondary)
            }
            if !intent.strategyOverrides.isEmpty {
                changeRow(
                    label: "방식 변경",
                    items: intent.strategyOverrides.map {
                        "\($0.relativePath) → \(CopyStrategy(rawValue: $0.strategy)?.label ?? $0.strategy)"
                    },
                    color: .accentColor
                )
            }

            if intent.includePaths.isEmpty && intent.excludePaths.isEmpty && intent.strategyOverrides.isEmpty {
                Text("계획에는 변화가 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func changeRow(label: String, items: [String], color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            // 항목이 많을 수 있으니 줄바꿈되게 흘려 놓는다.
            Text(items.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
