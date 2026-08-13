#!/bin/bash
#
# build-app.sh — SwiftPM 실행 파일을 macOS .app 번들로 조립합니다.
#
#   ./build-app.sh            릴리스 빌드 후 번들 생성
#   ./build-app.sh --debug    디버그 빌드
#   ./build-app.sh --run      번들 생성 후 실행
#
# Xcode 프로젝트 파일 없이 SwiftUI 앱을 만들기 위한 스크립트입니다.
# SwiftPM 이 만드는 것은 맨 실행 파일이라서, 창을 제대로 띄우고 TCC 권한을
# 기억시키려면 번들 구조와 서명이 필요합니다.

set -euo pipefail

CONFIG="release"
RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG="debug" ;;
    --run)   RUN=1 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
  esac
  shift
done

cd "$(dirname "$0")"

APP_NAME="BackupPilot"
BUNDLE_ID="com.dkkang.backuppilot"
# 릴리스 스크립트가 태그 버전을 그대로 넘길 수 있도록 밖에서 덮어쓸 수 있게 둡니다.
VERSION="${BACKUPPILOT_VERSION:-1.0}"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "✗ 실행 파일을 찾지 못했습니다: $BIN" >&2; exit 1; }

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# NS*UsageDescription 은 TCC 대화상자에 뜨는 문구입니다.
# 이게 없으면 macOS 가 접근을 물어보지 않고 그냥 거부합니다.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>BackupPilot</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>

    <key>NSDesktopFolderUsageDescription</key>
    <string>바탕화면을 백업하려면 접근 권한이 필요합니다.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>문서 폴더를 백업하려면 접근 권한이 필요합니다.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>다운로드 폴더를 백업하려면 접근 권한이 필요합니다.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>외장 SSD 에 백업을 기록하려면 접근 권한이 필요합니다.</string>
</dict>
</plist>
PLIST

# 임시 서명(ad-hoc). 서명이 아예 없으면 번들이 실행조차 되지 않을 수 있습니다.
#
# 주의: ad-hoc 서명은 TCC 허용 기록을 재빌드 너머로 유지해 주지 못합니다.
# 서명 주체가 인증서가 아니라 cdhash 라서, 빌드할 때마다 해시가 바뀌고
# macOS 는 그것을 다른 앱으로 봅니다.
#
# BACKUPPILOT_SIGN_IDENTITY 에 인증서 이름을 주면 그것으로 서명합니다.
# 이때는 공증에 필요한 두 가지를 함께 겁니다:
#   --options runtime  강화된 런타임. 공증의 전제 조건입니다.
#   --timestamp        보안 타임스탬프. 없으면 공증이 거부됩니다.
SIGN_IDENTITY="${BACKUPPILOT_SIGN_IDENTITY:--}"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null \
    && echo "✓ 임시 서명 완료 (배포용이 아닙니다)" \
    || echo "! 서명 실패 — 실행은 되지만 권한을 매번 다시 물어볼 수 있습니다"
else
  codesign --force --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --timestamp \
    "$APP" \
    && echo "✓ 서명 완료 — $SIGN_IDENTITY" \
    || { echo "✗ 서명 실패" >&2; exit 1; }
fi

echo "✓ $APP"
echo
echo "  실행:        open $APP"
echo "  전체 디스크 접근 필요 시:"
echo "    시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한 에 이 앱을 추가하세요."
echo "    (~/Library 하위나 다른 사용자 데이터까지 백업하려면 필요합니다)"

if [ "$RUN" = "1" ]; then
  echo
  echo "▸ 실행"
  open "$APP"
fi
