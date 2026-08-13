import Foundation

// MARK: - 복사 전략

/// 백업 대상을 디스크에 옮기는 방식.
///
/// exFAT 외장 SSD가 기본 전제라서 두 방식의 차이가 크다.
/// - `rsync`: 파일이 그대로 놓여 Finder에서 바로 열람된다. 대신 POSIX 권한이 소실되고
///   할당 블록(128KB) 단위로 잘려 작은 파일이 많으면 용량이 몇 배로 부푼다.
/// - `tarGz`: 권한·심볼릭링크·확장속성을 그대로 보존하고 블록 증폭도 없다. 대신 열람하려면 풀어야 한다.
enum CopyStrategy: String, Codable, CaseIterable, Identifiable {
    case rsync
    case tarGz

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rsync: return "평문 복사"
        case .tarGz: return "tar.gz"
        }
    }

    var symbol: String {
        switch self {
        case .rsync: return "doc.on.doc"
        case .tarGz: return "shippingbox"
        }
    }
}

/// 전략이 그렇게 정해진 이유. UI에서 사용자에게 근거를 보여주기 위한 것.
enum StrategyReason: String, Codable {
    case permissionSensitive   // 권한이 보존되어야 하는 경로 (.ssh 등)
    case manyFiles             // 파일 수가 많아 블록 증폭이 심한 경로
    case browsable             // 그대로 두고 열람하는 편이 나은 경로
    case userOverride          // 사용자가 직접 바꿈
    case llmSuggested          // Codex 제안을 사용자가 수락

    var explanation: String {
        switch self {
        case .permissionSensitive:
            return "권한이 보존되어야 하는 경로라 아카이브로 묶습니다 (exFAT은 chmod를 보존하지 못함)"
        case .manyFiles:
            return "파일 수가 많아 평문 복사 시 할당 블록 증폭이 큽니다"
        case .browsable:
            return "Finder에서 바로 열람할 수 있도록 평문으로 복사합니다"
        case .userOverride:
            return "사용자가 직접 지정했습니다"
        case .llmSuggested:
            return "Codex 제안을 수락했습니다"
        }
    }
}

// MARK: - 백업 항목

/// 백업 대상 하나. 경로는 홈 디렉터리 기준 상대경로로 다룬다.
/// (복원 시 계정명이 같아야 한다는 제약을 경로 표현 수준에서 강제하기 위함)
struct BackupItem: Identifiable, Codable, Hashable {
    var relativePath: String
    var note: String
    var strategy: CopyStrategy
    var reason: StrategyReason
    var isEnabled: Bool = true
    var excludes: [String] = []

    /// 소스 코드를 담고 있다고 판단된 항목.
    ///
    /// 소스를 홈 어디에 두는지는 사람마다 다르다(`dev`, `src`, `Projects`, …).
    /// 하나도 찾지 못했다면 그 사실을 사용자에게 알려야 한다 — 가장 잃으면 안 되는 것이
    /// 아무 말 없이 계획에서 빠지는 상황을 막기 위한 표식이다.
    var isSourceDirectory: Bool = false

    /// 측정 결과. 스캔 전에는 nil.
    var byteSize: Int64?
    var fileCount: Int?

    var id: String { relativePath }

    var sourceURL: URL {
        Home.resolve(relativePath)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: sourceURL.path)
    }

    /// 백업 대상 디렉터리 안에서의 산출물 이름.
    /// tar.gz는 경로 구분자를 `_`로 바꿔 평평하게 놓는다 (dev/uo → dev_uo.tar.gz).
    var artifactName: String {
        switch strategy {
        case .rsync: return relativePath
        case .tarGz: return relativePath.replacingOccurrences(of: "/", with: "_") + ".tar.gz"
        }
    }
}

// MARK: - 볼륨

struct Volume: Identifiable, Hashable {
    var url: URL
    var name: String
    var fileSystem: String
    var totalBytes: Int64
    var freeBytes: Int64
    var allocationBlockSize: Int64
    var isRemovable: Bool
    var isReadOnly: Bool

    var id: String { url.path }

    /// exFAT / FAT 계열인지. 권한·하드링크가 보존되지 않는 파일시스템을 통칭한다.
    var isPermissionLossy: Bool {
        let fs = fileSystem.lowercased()
        return fs.contains("exfat") || fs.contains("msdos") || fs.contains("fat")
    }

    var isSystemVolume: Bool {
        url.path == "/" || url.path.hasPrefix("/System/")
    }
}

// MARK: - 백업 계획

struct BackupPlan: Codable {
    var items: [BackupItem]

    var enabledItems: [BackupItem] { items.filter { $0.isEnabled && $0.exists } }

    /// 소스 디렉터리로 판단된 항목이 하나도 없는지.
    ///
    /// 켜짐/꺼짐이 아니라 **존재 여부**로 본다. 사용자가 일부러 끈 것은 선택이지만,
    /// 애초에 찾지 못한 것은 도구가 놓친 것이라 서로 다르게 다뤄야 한다.
    var lacksSourceDirectory: Bool {
        !items.contains { $0.isSourceDirectory }
    }

    /// 원본 기준 총 바이트. 측정되지 않은 항목은 0으로 센다.
    var totalSourceBytes: Int64 {
        enabledItems.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    var totalFileCount: Int {
        enabledItems.reduce(0) { $0 + ($1.fileCount ?? 0) }
    }

    /// 대상 볼륨에서 실제로 소비될 것으로 예측되는 바이트.
    ///
    /// exFAT에서는 두 가지가 겹쳐 원본보다 훨씬 커진다.
    ///  1. 할당 블록(보통 128KB) 단위 반올림 — 1KB 파일도 128KB를 차지
    ///  2. 확장속성 저장용 AppleDouble(`._`) 파일이 파일마다 하나씩 더 생김 — 이것도 한 블록
    /// tar.gz로 묶은 항목은 파일이 하나뿐이라 두 증폭 모두 사라진다.
    func estimatedDestinationBytes(on volume: Volume?) -> Int64 {
        let block = volume?.allocationBlockSize ?? 4096
        let lossy = volume?.isPermissionLossy ?? false

        return enabledItems.reduce(0) { total, item in
            let bytes = item.byteSize ?? 0
            let files = Int64(item.fileCount ?? 0)

            switch item.strategy {
            case .tarGz:
                // 압축률은 내용에 따라 크게 다르다. 소스코드·텍스트 위주라는 가정에서
                // 보수적으로 70%로 잡는다 (실제로는 대개 이보다 작다).
                return total + Int64(Double(bytes) * 0.7)
            case .rsync:
                guard lossy else { return total + bytes }
                let rounded = roundUpToBlock(bytes, block: block, fileCount: files)
                let appleDouble = files * block   // ._ 짝 파일이 각각 한 블록
                return total + rounded + appleDouble
            }
        }
    }

    /// 파일 각각이 블록 단위로 반올림되는 것을 근사한다.
    /// 파일별 크기를 모르므로 "평균 파일 크기"를 블록에 맞춰 올리는 방식으로 추정한다.
    private func roundUpToBlock(_ bytes: Int64, block: Int64, fileCount: Int64) -> Int64 {
        guard fileCount > 0, block > 0 else { return bytes }
        let avg = bytes / fileCount
        let roundedAvg = ((avg + block - 1) / block) * block
        return roundedAvg * fileCount
    }
}

// MARK: - 매니페스트 (복원 검증 기준값)

/// 백업 시점의 실측값. 복원 후 이 값과 대조해서 빠진 게 없는지 확인한다.
/// 하드코딩된 기대치 대신 "그때 실제로 이만큼 있었다"를 남기는 것이 요점.
struct Manifest: Codable {
    var createdAt: Date
    var hostName: String
    var userName: String
    var homePath: String
    var osVersion: String
    var destinationPath: String
    var destinationFileSystem: String
    var items: [ManifestItem]

    struct ManifestItem: Codable, Identifiable {
        var relativePath: String
        var strategy: CopyStrategy
        var artifactName: String
        var sourceByteSize: Int64
        var sourceFileCount: Int
        var producedByteSize: Int64
        var producedFileCount: Int
        /// 대상 볼륨이 실제로 내준 크기. exFAT 에서는 `producedByteSize` 보다 훨씬 크다.
        /// 옵셔널인 것은 이 필드가 없던 시절의 매니페스트도 읽기 위해서다.
        var producedAllocatedBytes: Int64?
        var durationSeconds: Double
        var succeeded: Bool
        var message: String?

        var id: String { relativePath }
    }
}

// MARK: - 실행 로그

struct LogLine: Identifiable, Hashable {
    enum Level: String {
        case info, ok, warn, error, command
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let text: String

    init(_ level: Level, _ text: String) {
        self.timestamp = Date()
        self.level = level
        self.text = text
    }
}

// MARK: - 진행 상태

struct JobProgress {
    var currentItem: String = ""
    var itemIndex: Int = 0
    var itemCount: Int = 0
    /// 현재 항목의 진행률 0...1. 알 수 없으면 nil (부정형 인디케이터).
    var itemFraction: Double?
    var bytesCopied: Int64 = 0

    var overallFraction: Double {
        guard itemCount > 0 else { return 0 }
        let done = Double(itemIndex)
        let partial = itemFraction ?? 0
        return min(1.0, (done + partial) / Double(itemCount))
    }
}

// MARK: - 포맷 도우미

enum Fmt {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        // ByteCountFormatter 는 0 을 "Zero KB" 로 쓴다. 아직 재지 않았다는 뜻으로 읽히도록 대체한다.
        guard value > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        // useBytes 를 빼면 300바이트짜리가 "0 KB" 로 나온다 — 실패한 것처럼 보인다.
        f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        return f.string(fromByteCount: value)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) + "개"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f초", seconds) }
        if seconds < 3600 { return String(format: "%.0f분 %.0f초", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.1f시간", seconds / 3600)
    }
}
