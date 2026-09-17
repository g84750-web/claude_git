#!/bin/bash
# Claude Code on the web 세션 시작 시 의존성을 설치한다.
# 계정·환경 설정에 의존하지 않도록 저장소 안에 두어 이관 시에도 동일하게 동작한다.
set -euo pipefail

# 로컬 CLI 세션에서는 아무것도 하지 않는다 (웹 원격 세션 전용)
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

echo "[session-start] repo root: $ROOT"

# 1) 루트 Python 프로젝트 (src/, tests/) — pyyaml, pytest
if [ -f requirements.txt ]; then
  echo "[session-start] pip install -r requirements.txt"
  python3 -m pip install --quiet --disable-pip-version-check -r requirements.txt
fi

# 2) 프런트엔드 (douzone-erp-ai-platform) — package.json 은 하위 디렉터리에 있다.
#    루트에서 npm 을 실행하면 package.json 이 없어 ENOENT 로 실패하므로 반드시 하위로 이동한다.
FRONTEND="$ROOT/douzone-erp-ai-platform"
if [ -f "$FRONTEND/package.json" ]; then
  echo "[session-start] npm install (douzone-erp-ai-platform)"
  (cd "$FRONTEND" && npm install --no-audit --no-fund --loglevel=error)
fi

# 3) 세션 환경 변수 — 루트 파이썬 패키지(src)를 어디서든 import 가능하게 한다
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PYTHONPATH=\"$ROOT\"" >> "$CLAUDE_ENV_FILE"
fi

echo "[session-start] done"
