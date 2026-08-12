import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case plan = "계획"
    case environment = "환경 조사"
    case backup = "백업"
    case restore = "복원"
    case assistant = "어시스턴트"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .plan: return "list.bullet.clipboard"
        case .environment: return "square.grid.2x2"
        case .backup: return "externaldrive.badge.timemachine"
        case .restore: return "arrow.uturn.backward.circle"
        case .assistant: return "bubble.left.and.text.bubble.right"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .plan

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch tab {
                case .plan: PlanView()
                case .environment: EnvironmentView()
                case .backup: BackupView()
                case .restore: RestoreView()
                case .assistant: AssistantView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 사이드바 아래에 대상 볼륨과 Codex 상태를 항상 띄워 둔다.
    /// 백업은 "어디에 쓰는지"를 잘못 알면 되돌리기 어려운 작업이라 늘 보이는 편이 낫다.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if let volume = model.selectedVolume {
                VStack(alignment: .leading, spacing: 3) {
                    Label(volume.name, systemImage: volume.isRemovable ? "externaldrive" : "internaldrive")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(volume.fileSystem) · 여유 \(Fmt.bytes(volume.freeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if volume.isPermissionLossy {
                        Label("권한 미보존", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Label("대상 볼륨 없음", systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(model.isCodexAvailable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.isCodexAvailable ? "Codex 연결됨" : "Codex 없음")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 홈 경로가 대체된 채로 도는 것을 모르면, 테스트 실행을 진짜 백업으로 착각한다.
            if Home.isOverridden {
                VStack(alignment: .leading, spacing: 1) {
                    Label("테스트 홈 사용 중", systemImage: "flask")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.purple)
                    Text(Home.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - 공용 컴포넌트

/// 화면 상단 제목 + 설명 + 우측 버튼 영역.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// 로그를 보여주는 콘솔. 새 줄이 오면 자동으로 따라 내려간다.
struct LogConsole: View {
    var lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol(for: line.level))
                                .font(.caption2)
                                .foregroundStyle(color(for: line.level))
                                .frame(width: 12)
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.level == .command ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .onChange(of: lines.count) {
                guard let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func symbol(for level: LogLine.Level) -> String {
        switch level {
        case .info: return "circle"
        case .ok: return "checkmark"
        case .warn: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .command: return "chevron.right"
        }
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        case .command: return .blue
        }
    }
}

/// Codex 가 응답을 만드는 동안 보여줄 표시.
struct ThinkingBadge: View {
    var status: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// 오류를 한 줄로 보여주는 배너.
struct ErrorBanner: View {
    var message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
