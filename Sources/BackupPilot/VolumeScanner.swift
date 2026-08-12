import Foundation

/// 마운트된 볼륨을 훑어 백업 대상 후보를 찾는다.
///
/// 파일시스템 종류를 알아야 하는 이유가 분명하다: exFAT이면 권한이 소실되고 용량이 부푸는데,
/// 그 사실을 백업이 끝난 뒤에 알면 이미 늦는다.
enum VolumeScanner {

    static func scan() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey,
            .volumeIsInternalKey
        ]

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }

            let (fsType, blockSize, freeFromStatfs) = statfsInfo(at: url.path)

            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)

            let volume = Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                fileSystem: fsType,
                totalBytes: total,
                freeBytes: free > 0 ? free : freeFromStatfs,
                allocationBlockSize: blockSize,
                isRemovable: (values.volumeIsRemovable ?? false)
                    || (values.volumeIsEjectable ?? false)
                    || (values.volumeIsInternal == false),
                isReadOnly: values.volumeIsReadOnly ?? false
            )

            // 시스템 볼륨은 백업 대상지가 될 수 없다.
            return volume.isSystemVolume ? nil : volume
        }
        .sorted { lhs, rhs in
            // 외장 매체를 위로. 백업 대상은 거의 항상 외장이다.
            if lhs.isRemovable != rhs.isRemovable { return lhs.isRemovable }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `statfs(2)`로 파일시스템 이름과 할당 블록 크기를 읽는다.
    /// URLResourceValues에는 파일시스템 종류가 없어서 이쪽으로 내려가야 한다.
    private static func statfsInfo(at path: String) -> (fsType: String, blockSize: Int64, freeBytes: Int64) {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return ("unknown", 4096, 0) }

        let fsType = withUnsafeBytes(of: &st.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }

        let blockSize = Int64(st.f_bsize)
        let freeBytes = Int64(st.f_bavail) * blockSize
        return (fsType, blockSize > 0 ? blockSize : 4096, freeBytes)
    }

    /// 지정한 경로가 속한 볼륨. 복원할 때 백업 디렉터리가 어디에 있는지 판별하는 데 쓴다.
    static func volume(containing url: URL) -> Volume? {
        let target = url.resolvingSymlinksInPath().path
        return scan()
            .filter { target.hasPrefix($0.url.path) }
            .max { $0.url.path.count < $1.url.path.count }   // 가장 깊게 겹치는 마운트 지점
    }
}

// MARK: - 크기 측정

/// 백업 대상의 크기와 파일 수를 잰다.
///
/// `du`와 `find`를 쓴다. Swift의 디렉터리 열거로도 되지만, 38만 개짜리 트리에서는
/// 시스템 도구 쪽이 확연히 빠르고 권한 오류도 알아서 넘어간다.
enum SizeEstimator {

    struct Measurement {
        /// 파일 내용의 크기 합계.
        var byteSize: Int64
        var fileCount: Int
        /// 디스크가 실제로 내준 크기.
        ///
        /// exFAT 에서는 이 둘이 크게 벌어진다. 실측하면 6바이트 파일이 131,072바이트를
        /// 차지한다 — 할당 블록이 128KB 라서다. 사용자에게 "얼마나 썼는가"를 말할 때는
        /// 반드시 이쪽을 써야 한다.
        var allocatedBytes: Int64 = 0
    }

    /// 제외 패턴을 반영해서 잰다. 제외를 빼먹으면 실제 백업량과 크게 어긋난다.
    static func measure(_ item: BackupItem) async -> Measurement? {
        let path = item.sourceURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let quoted = path.shellQuoted
        let pruneClause = item.excludes
            .map { "-path \(("*/" + $0).shellQuoted) -prune -o" }
            .joined(separator: " ")

        // 한 번의 find 로 파일 수와 바이트 수를 동시에 얻는다.
        // -print0 대신 awk 합산을 쓰는 이유는 출력량을 줄이기 위함이다.
        let command = """
        find \(quoted) \(pruneClause) -type f -print0 2>/dev/null \
        | xargs -0 stat -f '%z' 2>/dev/null \
        | awk '{ n++; s += $1 } END { print n+0, s+0 }'
        """

        guard let result = try? await ProcessRunner.shell(command), result.succeeded else { return nil }

        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2,
              let count = Int(parts[0]),
              let bytes = Int64(parts[1]) else { return nil }

        return Measurement(byteSize: bytes, fileCount: count)
    }

    /// 산출물이 실제로 대상 볼륨에서 차지한 크기. 백업 후 매니페스트에 기록한다.
    ///
    /// 논리 크기(`%z`)와 할당 크기(`%b` × 512)를 함께 잰다. exFAT 에서는 후자가
    /// 수십 배 클 수 있고, 다음 백업이 들어갈지 판단하려면 그쪽을 알아야 한다.
    /// - Parameter excludingAppleDouble: exFAT 이 만든 `._` 짝 파일을 세지 않는다.
    ///   복원 결과를 원본과 대조할 때는 빼야 한다 — 원본에는 없던 파일이라
    ///   그대로 세면 손실이 있어도 개수가 맞는 것처럼 보인다.
    ///   반대로 대상 볼륨의 소비량을 잴 때는 포함해야 한다. 그 파일들도 자리를 차지한다.
    static func measureProduced(at url: URL, excludingAppleDouble: Bool = false) async -> Measurement {
        let quoted = url.path.shellQuoted
        let filter = excludingAppleDouble ? "-not -name '._*' -not -name '.DS_Store'" : ""
        let command = """
        if [ -d \(quoted) ]; then
          find \(quoted) -type f \(filter) -print0 2>/dev/null | xargs -0 stat -f '%z %b' 2>/dev/null \
          | awk '{ n++; s += $1; a += $2 * 512 } END { print n+0, s+0, a+0 }'
        elif [ -f \(quoted) ]; then
          stat -f '1 %z %b' \(quoted) | awk '{ print $1, $2, $3 * 512 }'
        else
          echo '0 0 0'
        fi
        """
        guard let result = try? await ProcessRunner.shell(command) else {
            return Measurement(byteSize: 0, fileCount: 0)
        }
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3,
              let count = Int(parts[0]),
              let bytes = Int64(parts[1]),
              let allocated = Int64(parts[2]) else {
            return Measurement(byteSize: 0, fileCount: 0)
        }
        return Measurement(byteSize: bytes, fileCount: count, allocatedBytes: allocated)
    }
}
