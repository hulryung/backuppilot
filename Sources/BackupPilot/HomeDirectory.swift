import Foundation

/// "홈 디렉터리가 어디인가"를 한 곳에서만 답한다.
///
/// `NSHomeDirectory()` 를 코드 곳곳에서 부르면 두 가지가 곤란해진다.
///  - 진짜 홈을 백업/복원하지 않고는 동작을 확인할 방법이 없다.
///  - 복원 대상 경로를 바꿔야 할 때(계정명이 달라진 경우) 손댈 곳이 흩어진다.
///
/// `NSHomeDirectory()` 는 `getpwuid` 를 보기 때문에 `HOME` 환경변수로는 바뀌지 않는다.
/// 그래서 전용 변수를 따로 둔다.
enum Home {

    /// 백업·복원의 기준이 되는 홈 디렉터리.
    ///
    /// `BACKUPPILOT_HOME` 이 설정되어 있으면 그쪽을 쓴다. 실제 홈을 건드리지 않고
    /// 앱 전체를 돌려 보기 위한 장치다.
    static let path: String = {
        if let override = ProcessInfo.processInfo.environment["BACKUPPILOT_HOME"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return NSHomeDirectory()
    }()

    static var url: URL { URL(fileURLWithPath: path) }

    /// 실제 사용자 홈. Codex CLI 를 찾는 것처럼 "이 컴퓨터의 진짜 사용자" 를
    /// 가리켜야 하는 곳에서만 쓴다.
    static var realPath: String { NSHomeDirectory() }

    /// 지금 기준 홈이 진짜 홈이 아닌지. UI 에 눈에 띄게 표시해야 한다 —
    /// 테스트용 설정으로 돌고 있는 줄 모르고 진짜 백업이라 믿으면 곤란하다.
    static var isOverridden: Bool { path != NSHomeDirectory() }

    static func resolve(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }
}
