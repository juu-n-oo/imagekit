#!/usr/bin/env bash
#
# ImageKit 롤아웃 헬퍼
#
# 입력받은 태그로 각 deployment 의 이미지를 교체(set image)하고 롤아웃한다.
# build-and-push.sh 로 빌드/푸시한 태그를 클러스터에 실제로 배포하는 단계.
#
#   - 실행하면 이미지 태그를 한 번 입력받는다(기본값 1.0.0).
#   - imagekit-web / imagekit-backend / image-build-controller 각각에 대해
#     롤아웃할지 물어보고, 동의한 것만 진행한다.
#   - 동작(대상별):
#       · 현재 이미지 != <REGISTRY>/<HARBOR_PROJECT>/<name>:<tag> → kubectl set image (→ 자동 롤아웃)
#       · 현재 이미지 == 동일(태그 변동 없음)                     → kubectl rollout restart (재pull)
#       · 이후 kubectl rollout status 로 완료를 기다린다.
#
# 설정은 build-and-push.sh 와 동일한 build-and-push.config 를 공유한다.
#   REGISTRY / HARBOR_PROJECT / NAMESPACE / KUBECTL
#   (cp build-and-push.config.example build-and-push.config 후 값 채우기)
# 환경변수로 미리 지정한 값이 설정 파일보다 우선한다. 설정 파일 경로는 CONFIG 로 바꿀 수 있다.
#
# 사용법:
#   ./rollout.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_TAG="1.0.0"

# ── 설정 파일 로딩 (env > config 파일 > 기본값) ───────────────
_ENV_REGISTRY="${REGISTRY:-}"; _ENV_PROJECT="${HARBOR_PROJECT:-}"
_ENV_NS="${NAMESPACE:-}"; _ENV_KUBECTL="${KUBECTL:-}"

CONFIG="${CONFIG:-${SCRIPT_DIR}/build-and-push.config}"
if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
    echo "[INFO]  설정 로드: ${CONFIG}"
else
    echo "[WARN]  설정 파일 없음: ${CONFIG}"
    echo "        cp build-and-push.config.example build-and-push.config 후 값을 채우세요."
    echo "        (계속 진행하려면 env 또는 기본값을 사용합니다)"
fi

[[ -n "$_ENV_REGISTRY" ]] && REGISTRY="$_ENV_REGISTRY"
[[ -n "$_ENV_PROJECT"  ]] && HARBOR_PROJECT="$_ENV_PROJECT"
[[ -n "$_ENV_NS"       ]] && NAMESPACE="$_ENV_NS"
[[ -n "$_ENV_KUBECTL"  ]] && KUBECTL="$_ENV_KUBECTL"

REGISTRY="${REGISTRY:-external.registry.ten1010.io}"
HARBOR_PROJECT="${HARBOR_PROJECT:-aipub}"
NAMESPACE="${NAMESPACE:-aipub}"
KUBECTL="${KUBECTL:-sudo kubectl}"

# ── 색상 로그 ────────────────────────────────────────────────
c_info()  { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
c_ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
c_warn()  { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
c_err()   { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }
c_step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# yes/no 질의 (기본값: $2 = y|n). /dev/tty 에서 직접 읽어 파이프 환경에서도 동작.
ask() {
    local prompt="$1" def="${2:-n}" hint yn
    if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "$prompt ($hint): " yn < /dev/tty || yn=""
        yn="${yn:-$def}"
        case "$yn" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "y 또는 n 으로 답하세요." ;;
        esac
    done
}

# ── 태그 입력 (기본값 1.0.0) ──────────────────────────────────
read -r -p "롤아웃할 이미지 태그를 입력하세요 [${DEFAULT_TAG}]: " TAG < /dev/tty || TAG=""
TAG="$(printf '%s' "$TAG" | tr -d '[:space:]')"
TAG="${TAG:-$DEFAULT_TAG}"

# ── 대상 deployment (사용자 명령 순서: web → backend → controller) ──
DEPLOYS=(imagekit-web imagekit-backend image-build-controller)

declare -a RESULTS=()

rollout_one() {
    local name="$1"
    local image="${REGISTRY}/${HARBOR_PROJECT}/${name}:${TAG}"

    c_step "${name} → ${image} (ns: ${NAMESPACE})"

    # deployment 존재 확인 + 첫 컨테이너 이름/현재 이미지 조회
    local container current
    container=$($KUBECTL get deploy "$name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)
    if [[ -z "$container" ]]; then
        c_err "${name}: deployment 를 찾을 수 없습니다(ns: ${NAMESPACE}) — 건너뜀"
        RESULTS+=("${name}: SKIPPED (not found)")
        return 1
    fi
    current=$($KUBECTL get deploy "$name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    c_info "컨테이너: ${container} / 현재 이미지: ${current:-<none>}"

    if [[ "$current" == "$image" ]]; then
        # 태그 변동 없음 → 강제 재시작으로 재pull (pullPolicy: Always 가정)
        c_info "이미지 동일 — rollout restart 로 재pull"
        if ! $KUBECTL rollout restart deploy "$name" -n "$NAMESPACE"; then
            c_err "${name}: rollout restart 실패"
            RESULTS+=("${name}: FAILED (restart)")
            return 1
        fi
    else
        # 태그 교체 → set image 가 롤아웃을 트리거
        c_info "set image: ${container}=${image}"
        if ! $KUBECTL set image deploy "$name" -n "$NAMESPACE" "${container}=${image}"; then
            c_err "${name}: set image 실패"
            RESULTS+=("${name}: FAILED (set image)")
            return 1
        fi
    fi

    c_info "rollout status 대기..."
    if $KUBECTL rollout status deploy "$name" -n "$NAMESPACE" --timeout=300s; then
        c_ok "${name}: 롤아웃 완료 → ${image}"
        RESULTS+=("${name}: OK (${TAG})")
        return 0
    else
        c_err "${name}: 롤아웃 status 실패/타임아웃"
        RESULTS+=("${name}: FAILED (status)")
        return 1
    fi
}

# ── 메인 루프: deployment 별로 물어보고 진행 ───────────────────
c_step "롤아웃 대상 선택 (태그: ${TAG}, 이미지: ${REGISTRY}/${HARBOR_PROJECT}/<name>, ns: ${NAMESPACE})"
for name in "${DEPLOYS[@]}"; do
    if ask "[$name] 롤아웃할까요?" n; then
        rollout_one "$name"
    else
        c_info "${name}: 건너뜀"
        RESULTS+=("${name}: skipped")
    fi
done

# ── 요약 ────────────────────────────────────────────────────
c_step "완료 요약"
if [[ ${#RESULTS[@]} -eq 0 ]]; then
    echo "  (수행한 작업 없음)"
else
    for line in "${RESULTS[@]}"; do echo "  - ${line}"; done
fi
