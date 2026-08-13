#!/bin/bash
#
# release.sh — 배포용 빌드를 만들고 Apple 공증까지 마칩니다.
#
#   BACKUPPILOT_SIGN_IDENTITY="Developer ID Application: ..." \
#   BACKUPPILOT_NOTARY_PROFILE=backuppilot \
#   ./release.sh 1.0.0
#
# 공증 자격증명은 이 스크립트가 들고 있지 않습니다. 키체인에 한 번만 넣어 두고
# 프로파일 이름으로만 참조합니다 — 배포 스크립트가 암호를 갖고 있을 이유가 없습니다.
#
#   xcrun notarytool store-credentials <프로파일이름> \
#     --apple-id <Apple ID> --team-id <팀 ID> --password <앱 전용 암호>
#
# 왜 ad-hoc 서명으로는 안 되는가:
#   공증을 받지 않은 앱은 인터넷에서 받는 순간 격리 속성이 붙고, Gatekeeper 가 실행을 막습니다.
#   받는 사람이 시스템 설정을 파고들어 허용해야 하므로 사실상 배포가 되지 않습니다.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BackupPilot"
APP="build/$APP_NAME.app"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "사용법: ./release.sh <버전>   (예: ./release.sh 1.0.0)" >&2; exit 1; }

: "${BACKUPPILOT_SIGN_IDENTITY:?BACKUPPILOT_SIGN_IDENTITY 가 필요합니다 (security find-identity -v -p codesigning 으로 확인)}"
: "${BACKUPPILOT_NOTARY_PROFILE:?BACKUPPILOT_NOTARY_PROFILE 이 필요합니다 (xcrun notarytool store-credentials 로 등록)}"

DIST="dist"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

mkdir -p "$DIST"

# ── 1. 빌드 + 서명 ─────────────────────────────────────────
echo "▸ [1/6] 빌드와 서명"
BACKUPPILOT_VERSION="$VERSION" ./build-app.sh

# ── 2. 서명 검증 ───────────────────────────────────────────
# 공증에 올리기 전에 여기서 걸러야 합니다. 업로드 후 거부되면 왕복이 길어집니다.
echo "▸ [2/6] 서명 검증"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags" || true

# ── 3. 압축 ────────────────────────────────────────────────
# ditto 를 쓰는 이유: zip 명령은 번들의 심볼릭 링크와 확장속성을 망가뜨려
# 공증 검사에서 서명이 깨진 것으로 나옵니다.
echo "▸ [3/6] 압축"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── 4. 공증 ────────────────────────────────────────────────
echo "▸ [4/6] 공증 제출 (몇 분 걸립니다)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$BACKUPPILOT_NOTARY_PROFILE" \
  --wait

# ── 5. 스테이플 ────────────────────────────────────────────
# 공증 결과를 앱에 박아 넣습니다. 이게 있어야 네트워크가 없는 환경에서도
# Gatekeeper 가 통과시킵니다.
echo "▸ [5/6] 스테이플"
xcrun stapler staple "$APP"

# 스테이플이 번들을 고쳤으므로 배포할 zip 을 다시 만듭니다.
# 이 단계를 빠뜨리면 공증은 받았는데 배포본에는 반영되지 않은 상태가 됩니다.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── 6. 최종 확인 ───────────────────────────────────────────
echo "▸ [6/6] 최종 확인"
xcrun stapler validate "$APP"
spctl --assess --verbose=4 --type execute "$APP"

echo
echo "✓ $ZIP"
echo "  크기: $(du -h "$ZIP" | cut -f1)"
