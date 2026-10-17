#!/bin/bash
# LiveSub (실시간 자막) 설치 스크립트 — macOS 13 이상, Apple Silicon 권장
# 실행: 터미널에서  bash ~/Downloads/LiveSub/설치하기.command
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SUP="$HOME/Library/Application Support/LiveSub"
APP="$HOME/Applications/LiveSub.app"
ARCH="$(uname -m)"
LOG="$HOME/Library/Logs/LiveSub.log"

say() { printf "\n\033[1;34m▶ %s\033[0m\n" "$1"; }

echo "========================================"
echo "   LiveSub 실시간 자막 설치 (약 5~10분)"
echo "========================================"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "macOS 13(Ventura) 이상이 필요합니다."; exit 1
fi

PREBUILT="$SRC/LiveSub.app"
if [ ! -d "$PREBUILT" ]; then
  say "1/6 개발 도구 확인 (앱 빌드용)"
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    echo "  Apple 명령어 개발 도구가 필요합니다. 설치 창이 뜨면 '설치'를 눌러 주세요."
    xcode-select --install || true
    echo "  설치가 끝나면 이 명령을 다시 실행해 주세요."
    exit 1
  fi
fi

# 실행 중인 앱 종료
pkill -x LiveSub 2>/dev/null || true

say "2/6 파일 복사"
mkdir -p "$SUP" "$HOME/Library/Logs" "$HOME/Applications"
touch "$LOG"
cp "$SRC/worker.py" "$SUP/worker.py"
[ -f "$SUP/config.json" ] || echo '{"claude_model": "claude-haiku-4-5", "source_lang": "ja", "target_lang": "ko"}' > "$SUP/config.json"
chmod 600 "$SUP/config.json"

say "3/6 Python 실행 환경 준비 (uv)"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
[ -x "$SUP/venv/bin/python" ] || uv venv --python 3.12 "$SUP/venv"

say "4/6 라이브러리 설치"
PKGS=(numpy anthropic huggingface_hub)
if [ "$ARCH" = "arm64" ]; then
  PKGS+=(mlx-whisper); MODEL_REPO="mlx-community/whisper-large-v3-turbo"
else
  PKGS+=(faster-whisper); MODEL_REPO="Systran/faster-whisper-small"
  echo "  ※ Intel 맥은 인식 속도가 느려 자막이 늦게 나올 수 있어요."
fi
uv pip install --python "$SUP/venv/bin/python" --upgrade "${PKGS[@]}"

say "5/6 음성 인식 모델 받기 (약 1.5GB, 최초 1회)"
"$SUP/venv/bin/python" -c "from huggingface_hub import snapshot_download; snapshot_download('$MODEL_REPO')"

say "6/6 LiveSub 앱 설치"
rm -rf "$APP"
if [ -d "$PREBUILT" ]; then
  ditto "$PREBUILT" "$APP"
else
  bash "$SRC/build_app.sh" "$APP" 2> "$SUP/build.log" || { echo "빌드 실패 — $SUP/build.log 내용을 보내 주세요."; cat "$SUP/build.log"; exit 1; }
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo
echo "========================================"
echo " ✅ 설치 완료!"
echo "  · 메뉴 막대(화면 오른쪽 위)에 말풍선 아이콘이 생깁니다."
echo "  · 처음 실행 시 '화면 및 시스템 오디오 녹음' 권한을 허용해 주세요."
echo "    (허용 후 LiveSub을 한 번 종료했다가 다시 열어야 적용됩니다.)"
echo "  · 앱 위치: ~/Applications/LiveSub"
echo "========================================"
open "$APP"
