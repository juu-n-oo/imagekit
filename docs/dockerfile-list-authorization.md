# Dockerfile 목록 조회 권한별 분기 (작업 인계 문서)

> 작성일: 2026-06-09
> 상태: **구현 완료** (2026-06-09) — 백엔드 `compileJava`+테스트 통과, 프론트 `tsc`+`vite build` 통과, 양쪽 main push
> 관련 커밋: backend `fc17905`, web `bcdb8bb`
> 관련: [api-architecture.md](api-architecture.md), [PRD.md](PRD.md) §3.2 "Project 단위 귀속으로 팀 내 공유"

> ## ✅ 구현 완료 요약 (2026-06-09)
> - **계약 변경**: 프론트가 `username` 을 직접 넘기던 방식을 폐기. 백엔드가 **토큰 신원**으로 조회하고, 권한에 따라 분기한다.
> - **멤버**: `GET /api/v1alpha1/dockerfiles?projects=p1,p2` → `project IN(...) AND username=토큰의 호출자` 로 묶어 **본인 소유만** 반환. 생성 일시 최신순.
> - **관리자**: `GET /api/v1alpha1/dockerfiles?all=true(&username= 선택)` → **전체** 조회(+username 필터), 최신순. `all=true` 는 백엔드가 **토큰 roles 의 `aipub-admin`** (설정 `imagekit.aipub.admin-roles`) 검증, 비관리자 위조 시 **403**.
> - **삭제된 프로젝트 처리**: 멤버가 보내는 프로젝트 목록은 프론트 `useAuth()`(UserAuthorityReview)의 **현재 바인딩 프로젝트**라 삭제된 프로젝트는 자동 제외. 거기에 `username` AND 게이트까지 더해 "본인 것"을 완벽 보장.
> - **미반영(차기)**: 프론트/백엔드 admin 소스 통일 여부(아래 §6 정합성 전제), 배포 후 E2E 검증.

이 문서는 "Dockerfile 목록을 누가, 무엇을 볼 수 있는가"를 권한 기반으로 정리한 작업의 설계·결정·구현 내역을 담는다.

---

## 1. 문제 / 배경 (왜 하는가)

기존 `GET /api/v1alpha1/dockerfiles` 는 `?project=X&username=Y(optional)` 를 받아 단순 필터링했다.

- **보안 공백 1**: `username` 을 프론트가 임의로 넘길 수 있어 **타인의 Dockerfile 조회 가능**.
- **보안 공백 2**: `project` 도 임의 지정 가능 — 권한 없는 프로젝트의 Dockerfile 열람 가능.
- **요구**: 멤버는 본인 것만(삭제된 프로젝트 제외), 관리자는 전체 + username 필터 + 최신순 기본 정렬.

## 2. 사용자 결정 사항 (확정)

1. 프론트는 username 을 직접 넘기지 않고, **백엔드가 토큰에서 신원 추출**.
2. **멤버 분기는 프론트가 1차 수행** — `useAuth()`(UserAuthorityReview)의 바인딩 프로젝트 목록으로 쿼리.
3. **백엔드는 admin 여부만 검증** (전체 조회 게이트). 검증 수단은 **토큰 roles**(추가 RBAC/k8s 호출 회피).
4. 멤버가 보는 범위 = **본인이 만든 Dockerfile만**. 단 삭제된 프로젝트의 것은 안 보여야 하므로
   username 단독이 아니라 **`project IN` + `username` 을 AND** 로 묶어 완벽 보장.
5. admin role 문자열 = **`aipub-admin`** (멤버는 `aipub-member`, selfsubjectreviews `roles` 로 확인).

## 3. 최종 동작

| 호출자 | 프론트 요청 | 백엔드 동작 |
|---|---|---|
| **멤버** | `?projects=p1,p2` (바인딩 프로젝트) | `findByProjectInAndUsernameOrderByCreatedAtDesc(projects, 토큰username)` |
| **관리자** | `?all=true` (`&username=foo` 선택) | roles 에 `aipub-admin` 검증 → `findAllByOrderByCreatedAtDesc()` 또는 username 필터, 최신순 |

> **핵심 보안 포인트**: 멤버 경로는 프론트가 보낸 프로젝트 목록을 그대로 믿어도 `username=토큰` AND 게이트 때문에 **본인 Dockerfile만** 반환되므로 위변조가 무의미하다. 전체 조회(`all=true`)만 백엔드가 admin 을 직접 검증한다.

## 4. 구현 내역

### 백엔드 (`imagekit-backend`, 커밋 `fc17905`)
- `dockerfile/repository/DockerfileRepository.java`
  - `findByProjectInAndUsernameOrderByCreatedAtDesc(List<String>, String)` (멤버)
  - `findAllByOrderByCreatedAtDesc()` / `findByUsernameOrderByCreatedAtDesc(String)` (관리자)
- `dockerfile/service/DockerfileService.java`
  - `listForUser(projects, username)` — projects 비면 빈 목록
  - `listAll(usernameFilter)` — filter 없으면 전체, 둘 다 최신순
  - `listByProject(project)` 는 **MCP 툴 전용**으로 유지
- `dockerfile/controller/DockerfileController.java`
  - `list(projects, username, all, authentication)` 로 시그니처 변경
  - `all=true` 면 `isAdmin(authentication)`(아래) 검증 → 아니면 `ForbiddenException`
  - 그 외엔 `listForUser(projects, authentication.getName())`
  - `isAdmin()` = `authentication.getAuthorities()` 에 `aipubProperties.getAdminRoles()` 중 하나라도 포함되면 true
- `aipub/config/AipubProperties.java`: `adminRoles`(기본 `[aipub-admin]`) 추가 — `imagekit.aipub.admin-roles` 로 오버라이드
- `common/exception/ForbiddenException.java`(신규) + `GlobalExceptionHandler` → **403 ProblemDetail**
- `application.yaml`: `imagekit.aipub.admin-roles: [aipub-admin]` 명시
- 테스트 `DockerfileControllerDocsTest`: list 테스트를 멤버 경로(`?projects=` + principal)로 갱신, REST Docs 파라미터 갱신

### 프론트엔드 (`imagekit-web`, 커밋 `bcdb8bb`)
- `api/dockerfile.ts`: `list(projects[])` (params `projects=join(',')`) / `listAll(username?)` (`all=true`)
- `hooks/useDockerfiles.ts`: `useDockerfileList({ isAdmin, projects, owner })` 단일 훅 — 기존 `useDockerfiles`/`useDockerfilesMulti` 대체
- `pages/dockerfile/DockerfileListPage.tsx`: 멤버=프로젝트 셀렉터 / 관리자=소유자(username) 서버사이드 필터, 둘 다 최신순 기본
- `layouts/RootLayout.tsx` `NoProjectGuard`: 관리자는 바인딩 프로젝트 0개여도 `/dockerfiles`·`/builds` 접근 허용
- i18n `dockerfile.ownerFilter`(ko/en), MSW 목 핸들러를 새 계약(`projects`/`all`/`username`)으로 갱신

## 5. 인증 파이프라인 참고

- `AipubAuthenticationFilter` 가 쿠키 `AIPUB_ACCESS_COOKIE` 로 AIPub `selfsubjectreviews` 를 호출 →
  `username` + `roles` 를 `UsernamePasswordAuthenticationToken(username, null, roles→SimpleGrantedAuthority)` 로 SecurityContext 에 세팅.
- 그래서 컨트롤러에서 `authentication.getName()`(=username), `authentication.getAuthorities()`(=roles) 를 그대로 쓴다. 추가 호출 없음.

## 6. ⚠️ 정합성 전제 (배포 시 확인)

프론트는 **`useAuth().isAdmin`** (UserAuthorityReview 의 `status.aipubRole.isAdmin`) 으로 admin 을 1차 분기하고,
백엔드는 **토큰 roles 의 `aipub-admin`** 으로 게이트한다. **서로 다른 소스**다.

- 한 사용자에 대해 두 값이 **일치해야** 정상 동작한다(AIPub 플랫폼에서 동일 권한 부여를 반영).
- 어긋나면: 프론트가 admin 으로 판단해 `all=true` 를 보냈는데 백엔드 roles 에 `aipub-admin` 이 없어 **403**.
- 배포 후 관리자 계정으로 Dockerfile 전체 조회가 200 인지 1회 확인 권장.
- 불안하면 프론트 admin 분기도 `selfsubjectreviews.roles` 의 `aipub-admin` 기준으로 통일 가능(프론트는 이미 roles 를 받아옴).

## 7. 범위 / 비범위
- **포함**: 권한별 목록 조회 계약, 멤버 본인+바인딩 프로젝트 보장(삭제 프로젝트 제외), 관리자 전체+username 필터+최신순, 403 게이트, 설정화된 admin role, 프론트 UI 분기, 컴파일/빌드/테스트 검증
- **제외**: 프론트/백엔드 admin 소스 통일, 페이지네이션(현재 전량 반환), 멤버의 "팀 공유"(타인 것까지) 모드 — 본 작업은 "본인 것만" 으로 확정
