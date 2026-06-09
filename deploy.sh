#!/usr/bin/env bash
#
# Dockerizer 일괄 배포 헬퍼
#
# `make install` 을 ARGS(이미지 빌드 + 무확인) 와 함께 실행한다.
# 매번 `make install ARGS="--build --skip-confirmation"` 를 치지 않아도 되도록 감싼 스크립트.
#
# 사용법:
#   ./deploy.sh                  # 프론트+백엔드 모두 (--build --skip-confirmation)
#   ./deploy.sh install-web      # 프론트만
#   ./deploy.sh install-backend  # 백엔드만
#
# 환경변수로 인자 재정의:
#   DEPLOY_ARGS="--skip-confirmation" ./deploy.sh   # 빌드 없이 배포만
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 배포 대상 make 타깃 (기본: install = 백엔드+프론트)
TARGET="${1:-install}"

# install.sh 로 전달할 인자 (기본: 이미지 빌드 + 확인 프롬프트 생략)
ARGS="${DEPLOY_ARGS:---build --skip-confirmation}"

echo "==> sudo make ${TARGET} ARGS=\"${ARGS}\""
exec sudo make "${TARGET}" ARGS="${ARGS}"
