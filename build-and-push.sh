#!/usr/bin/env bash
#
# ImageKit 로컬 빌드 & 푸시 헬퍼
#
# 각 repo 의 GitHub Actions CD(.github/workflows/cd.yml)가 하던 빌드/푸시를 로컬에서 재현한다.
# (GitHub Actions 결제/한도 문제로 CD 가 막혔을 때의 우회 경로 / 클러스터 노드에서 직접 빌드)
#
#   - 실행하면 이미지 태그를 한 번 입력받는다(기본값 1.0.0).
#   - image-build-controller / imagekit-web / imagekit-backend 각각에 대해
#     빌드 & 푸시할지 물어보고, 동의한 것만 진행한다.
#   - 이미지: <REGISTRY>/<HARBOR_PROJECT>/<name>:<tag>
#       · imagekit-web         : 멀티스테이지(컨테이너 내부 빌드) + VITE_APP_VERSION build-arg
#       · imagekit-backend     : ./gradlew bootJar -x test -x asciidoctor 후 jar COPY
#       · image-build-controller: ./gradlew bootJar -x test 후 jar COPY
#   - git 태그는 다루지 않는다(필요 시 본인 계정으로 직접 push).
#
# 사용법:
#   ./build-and-push.sh
#
# Harbor 정보 등 설정은 설정 파일(cicd.config)에서 읽는다.
#   cp cicd.config.example cicd.config  후 값 채우기
# 설정 키: REGISTRY / HARBOR_PROJECT / HARBOR_USERNAME / HARBOR_PASSWORD / DOCKER
# 환경변수로 미리 지정한 값이 설정 파일보다 우선한다. 설정 파일 경로는 CONFIG 로 바꿀 수 있다.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_TAG="1.0.0"

# ── 설정 파일 로딩 (env > config 파일 > 기본값) ───────────────
# 미리 설정된 env 값을 보존했다가 config 로 채운 뒤 되살린다(= env 우선).
_ENV_REGISTRY="${REGISTRY:-}"; _ENV_PROJECT="${HARBOR_PROJECT:-}"
_ENV_USER="${HARBOR_USERNAME:-}"; _ENV_PASS="${HARBOR_PASSWORD:-}"
_ENV_DOCKER="${DOCKER:-}"

CONFIG="${CONFIG:-${SCRIPT_DIR}/cicd.config}"
if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
    echo "[INFO]  설정 로드: ${CONFIG}"
else
    echo "[WARN]  설정 파일 없음: ${CONFIG}"
    echo "        cp cicd.config.example cicd.config 후 값을 채우세요."
    echo "        (계속 진행하려면 env 또는 기본값을 사용합니다)"
fi

# env 가 지정돼 있으면 config 값을 덮어쓴다(env 우선).
[[ -n "$_ENV_REGISTRY" ]] && REGISTRY="$_ENV_REGISTRY"
[[ -n "$_ENV_PROJECT"  ]] && HARBOR_PROJECT="$_ENV_PROJECT"
[[ -n "$_ENV_USER"     ]] && HARBOR_USERNAME="$_ENV_USER"
[[ -n "$_ENV_PASS"     ]] && HARBOR_PASSWORD="$_ENV_PASS"
[[ -n "$_ENV_DOCKER"   ]] && DOCKER="$_ENV_DOCKER"

# 최종 기본값 보정.
REGISTRY="${REGISTRY:-external.registry.ten1010.io:8443}"
HARBOR_PROJECT="${HARBOR_PROJECT:-aipub}"
DOCKER="${DOCKER:-sudo docker}"
HARBOR_USERNAME="${HARBOR_USERNAME:-java}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-}"

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
read -r -p "이미지 태그를 입력하세요 [${DEFAULT_TAG}]: " TAG < /dev/tty || TAG=""
TAG="$(printf '%s' "$TAG" | tr -d '[:space:]')"
TAG="${TAG:-$DEFAULT_TAG}"

# ── Harbor 로그인(자격증명이 주어진 경우에만) ───────────────────
if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    c_step "Harbor 로그인: ${REGISTRY}"
    if printf '%s' "$HARBOR_PASSWORD" | $DOCKER login "$REGISTRY" -u "$HARBOR_USERNAME" --password-stdin; then
        c_ok "로그인 성공"
    else
        c_err "Harbor 로그인 실패 — 자격증명을 확인하세요."
        exit 1
    fi
else
    c_warn "HARBOR_PASSWORD 미설정 — 이미 'docker login ${REGISTRY}' 된 상태(노드 자격증명)로 가정합니다."
fi

# ── repo 정의: "name|dir|prebuild|build_args" ──────────────────
# prebuild: 도커 빌드 전에 repo 디렉터리에서 실행할 명령(없으면 빈 문자열)
# build_args: docker build 에 넘길 --build-arg ... (없으면 빈 문자열)
REPOS=(
    "image-build-controller|image-build-controller|./gradlew bootJar -x test|"
    "imagekit-web|imagekit-web||--build-arg VITE_APP_VERSION=${TAG}"
    "imagekit-backend|imagekit-backend|./gradlew bootJar -x test -x asciidoctor|"
)

declare -a RESULTS=()

build_and_push() {
    local name="$1" dir="$2" prebuild="$3" build_args="$4"
    local image="${REGISTRY}/${HARBOR_PROJECT}/${name}:${TAG}"

    if [[ ! -d "$dir" ]]; then
        c_err "${name}: 디렉터리 '${dir}' 없음 — 건너뜀"
        RESULTS+=("${name}: SKIPPED (no dir)")
        return 1
    fi

    c_step "${name} → ${image}"

    # 1) 사전 빌드(gradlew bootJar 등)
    if [[ -n "$prebuild" ]]; then
        c_info "사전 빌드: (cd ${dir} && ${prebuild})"
        ( cd "$dir" && chmod +x gradlew 2>/dev/null; eval "$prebuild" )
        if [[ $? -ne 0 ]]; then
            c_err "${name}: 사전 빌드 실패"
            RESULTS+=("${name}: FAILED (prebuild)")
            return 1
        fi
    fi

    # 2) docker build (클러스터 노드 = amd64 네이티브, --platform 불필요)
    c_info "docker build"
    # shellcheck disable=SC2086
    $DOCKER build $build_args \
        -t "$image" \
        -f "${dir}/Dockerfile" \
        "$dir"
    if [[ $? -ne 0 ]]; then
        c_err "${name}: docker build 실패"
        RESULTS+=("${name}: FAILED (build)")
        return 1
    fi

    # 3) docker push
    c_info "docker push ${image}"
    if ! $DOCKER push "$image"; then
        c_err "${name}: docker push 실패"
        RESULTS+=("${name}: FAILED (push)")
        return 1
    fi
    c_ok "${name}: 이미지 푸시 완료 → ${image}"
    RESULTS+=("${name}: OK (${TAG})")
    return 0
}

# ── 메인 루프: repo 별로 물어보고 진행 ─────────────────────────
c_step "배포 대상 선택 (태그: ${TAG}, 레지스트리: ${REGISTRY}/${HARBOR_PROJECT})"
for entry in "${REPOS[@]}"; do
    IFS='|' read -r name dir prebuild build_args <<< "$entry"
    if ask "[$name] 빌드 & 푸시할까요?" n; then
        build_and_push "$name" "$dir" "$prebuild" "$build_args"
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
