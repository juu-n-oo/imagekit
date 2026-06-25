# CLAUDE.md (imagekit 서브 umbrella)

> 이 디렉토리는 `aipub-workspace` super-umbrella 의 멤버다. **AIPub-wide 공통 정책·불변식·공유 워크플로우는 상위 `aipub-workspace/CLAUDE.md`** 에 있고 cascade 로 상속된다. 본 파일은 **imagekit 도메인 세부 규칙**만 다룬다.

이 파일은 `imagekit-web` / `imagekit-backend` / `image-build-controller` 에 공통 적용되는 imagekit 정책을 정의한다. 각 서브 repo 의 `CLAUDE.md` 는 그 도메인의 세부를 다룬다.

## 1. 서비스 개요

- **ImageKit** 는 AIPub 내에서 동작하는 **웹 기반 Dockerfile 편집 · 이미지 빌드/관리 서비스**다. 사용자가 로컬 환경 없이 브라우저에서 Dockerfile 을 작성 → 저장 → Kaniko 기반 k8s Job 으로 빌드 → Harbor(ImageHub) 로 push 하는 플로우를 제공한다.
- 빌드 엔진은 **Kaniko 고정** (Docker daemon 불필요, rootless). 빌드는 `ImageBuild` CR 을 컨트롤러가 watch 하여 Kaniko Pod/Job 으로 수행한다.
- 자세한 기획 · MVP 범위는 [`imagekit-backend/CLAUDE.md`](imagekit-backend/CLAUDE.md) (서비스 기획서) 참조.

## 2. 리포지토리 구조

`imagekit/` 는 umbrella git repo 이며, 세 서브 프로젝트는 **각자 독립된 git repo** 다(`.gitignore` 로 제외, 각 repo 안에서 직접 commit/push).

| 디렉토리 | 역할 | 원격 |
|---|---|---|
| `imagekit-web` | 프론트엔드 (Dockerfile 에디터, 빌드 트리거, 로그/결과 조회 UI) | `ten1010-io/imagekit-web` |
| `imagekit-backend` | 백엔드 (Dockerfile 저장/버전관리, 빌드 **로그** 제공, Volume·ImageHub 조회) — **ImageBuild CR 은 생성하지 않는다**(프론트가 k8sproxy로 직접) | `ten1010-io/imagekit-backend` |
| `image-build-controller` | ImageBuild CR watch → Kaniko Job 관리 (k8s 컨트롤러) | `ten1010-io/image-build-controller` |

## 3. imagekit 고유 보존 식별자 (변경 금지)

> `aipub`/`brewery` 식별자를 의도적으로 보존하는 **일반 원칙**과 공통 식별자(API group `aipub.ten1010.io`, namespace `aipub`, copyright 등)는 상위 `aipub-workspace/CLAUDE.md` 및 `aipub-workspace/docs/aipub-domain.md` 참조. 아래는 **imagekit 에만 해당하는** 구체값이다.

- Harbor host `aipub-harbor.cluster7.idc1.ten1010.io`, 이미지 경로 `.../aipub/brewery-web`
- ingress `aipub-brewery.cluster7.idc1.ten1010.io`, 외부 백엔드 서비스 `aipub-web-server`
- DB username 기본값 `${DB_USERNAME:brewery}` (DB *이름* 만 `imagekit` 로 변경)
- ImageBuild CRD 및 imagekit 가 부여하는 라벨/어노테이션은 **코어 AIPub group `aipub.ten1010.io`** 를 따른다 (CRD: `imagebuilds.aipub.ten1010.io`, 라벨: `aipub.ten1010.io/dockerfile-id` 등). 향후 aipub backend 로 통합될 것을 전제로 코어 AIPub 리소스(`workspaces`/`operations`/`aipubvolumes` 등)와 동일 group 에 편입한 결정이다. (이전 `imagekit.aipub.ten1010.io` 서브도메인에서 이관 — 이미 배포된 `imagebuilds.imagekit.aipub.ten1010.io` CRD 가 있으면 새 group 으로 재생성·CR 마이그레이션 필요, 해당 group 은 플랫폼 소유라 AIPub 플랫폼팀과 조율 전제.)

## 4. 작업 시 참조 우선순위

1. `aipub-workspace/CLAUDE.md` — AIPub-wide 공통 정책·불변식 (상속됨)
2. 본 파일 (`imagekit/CLAUDE.md`) — imagekit 공통 정책
3. 작업 대상 서브 repo 의 `CLAUDE.md` — 도메인 세부 규칙 / 기획
4. 각 repo 의 `docs/` 및 코드
