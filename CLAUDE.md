# CLAUDE.md (umbrella)

이 파일은 `dockerizer-web` / `dockerizer-backend` **양쪽에 공통으로 적용되는** 정책을 정의한다.
각 서브 repo 의 `CLAUDE.md` 는 그 도메인의 세부 규칙을 다룬다. Claude Code 는 cwd 에서 home 까지 거슬러 올라가며 만나는 모든 `CLAUDE.md` 를 누적 로드하므로 본 파일이 자동 상속된다.

## 1. 서비스 개요

- **Dockerizer** 는 AIPub(쿠버네티스 기반 ML 개발 플랫폼) 내에서 동작하는 **웹 기반 Dockerfile 편집 · 이미지 빌드/관리 서비스**다. 사용자가 로컬 환경 없이 브라우저에서 Dockerfile 을 작성 → 저장 → Kaniko 기반 k8s Job 으로 빌드 → Harbor(ImageHub) 로 push 하는 플로우를 제공한다.
- 빌드 엔진은 **Kaniko 고정** (Docker daemon 불필요, rootless). 빌드는 `ImageBuild` CR 을 컨트롤러가 watch 하여 Kaniko Pod/Job 으로 수행한다.
- 자세한 기획 · MVP 범위는 [`dockerizer-backend/CLAUDE.md`](dockerizer-backend/CLAUDE.md) (서비스 기획서) 참조.

## 2. 리포지토리 구조 (umbrella)

이 디렉토리(`dockerizer/`)는 **umbrella git repo** 다. 두 서브 프로젝트는 **각자 독립된 git repo** 이며, 같은 디렉토리 안에 clone 되어 있다.

| 디렉토리 | 역할 | 원격 |
|---|---|---|
| `dockerizer-web` | 프론트엔드 (Dockerfile 에디터, 빌드 트리거, 로그/결과 조회 UI) | `juu-n-oo/dockerizer-web` |
| `dockerizer-backend` | 백엔드 + ImageBuild 컨트롤러 (Dockerfile 저장, CR 생성, 빌드 상태/로그 제공) | `juu-n-oo/dockerizer-backend` |

- 두 서브 repo 는 본 umbrella 의 git 추적 대상이 **아니다** (`.gitignore` 로 제외). 각 repo 안에서 직접 commit / push 한다.
- umbrella repo 는 양쪽 공통 정책(`CLAUDE.md`), 공유 도구(`.claude/`), 공통 문서를 보관한다.

## 3. AIPub 리브랜드 주의사항 (중요)

이 프로젝트는 **"aipub brewery" → "dockerizer"** 로 리브랜드되었으나, **외부 AIPub 플랫폼과 연동**되는 식별자는 의도적으로 보존되어 있다. 잔존하는 `aipub` / `brewery` 문자열은 **버그가 아니라 의도된 것**이며, 임의로 "리네임을 마저 완료"하면 클러스터 / API / 레지스트리 연동이 깨진다.

보존 대상 (변경 금지):
- k8s API group `aipub.ten1010.io` / `project.aipub.ten1010.io`, CR 필드 `aipubRole` / `aipubUser` / `allBoundAipubUsers`
- Harbor host `aipub-harbor.cluster7.idc1.ten1010.io`, 이미지 경로 `.../aipub/brewery-web`
- k8s namespace `aipub`, ingress `aipub-brewery.cluster7.idc1.ten1010.io`, 외부 백엔드 서비스 `aipub-web-server`, `AIPub Volume` / `AIPub ImageHub`, copyright `©AIPub, TEN Inc`
- DB username 기본값 `${DB_USERNAME:brewery}` (DB *이름* 만 `dockerizer` 로 변경)

본 프로젝트 고유의 CRD API group 은 `dockerizer.aipub.ten1010.io` 로 변경됨 (`.aipub.ten1010.io` 접미사는 유지).

## 4. 작업 시 참조 우선순위

1. 본 파일 (`dockerizer/CLAUDE.md`) — 양쪽 공통 정책 + 리브랜드 주의사항
2. 작업 대상 repo 의 `CLAUDE.md` — 도메인 세부 규칙 / 기획
3. 각 repo 의 `docs/` 및 코드
