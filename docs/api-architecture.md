# Dockerizer API 아키텍처

> 작성일: 2026-06-01  
> 최종 수정: 2026-06-02  
> 범위: 프론트엔드 ↔ 백엔드 ↔ AIPub 간 전체 API 흐름

---

## 1. 개요

Dockerizer는 AIPub의 선택적 플러그인으로, **기존 AIPub Ingress(`aipub-backend-adapter`)에 path를 추가**하여 라우팅한다.
프론트엔드는 AIPub과 동일한 도메인(`aipub.cluster10.idc1.ten1010.io`)을 사용하며, Ingress가 경로에 따라 dockerizer backend, AIPub backend, 또는 dockerizer-web으로 라우팅한다.

- **프론트엔드 접근**: `https://aipub.cluster10.idc1.ten1010.io/dockerizer`
- **API 경로**: 기존 AIPub과 동일한 `/api/v1alpha1` prefix 사용 (별도 prefix 없음)
- **라우팅 분기**: Ingress가 리소스 경로(`dockerfiles`, `builds`, `volumes`, `registries`)를 기준으로 dockerizer backend로 분기

## 2. 전체 요청 흐름

```
[브라우저]
  │  credentials: 'include' (AIPUB_ACCESS_COOKIE 자동 포함)
  │
  └─── aipub.cluster10.idc1.ten1010.io ──→ [AIPub Ingress (aipub-backend-adapter)]
                                              │
                  ┌───────────────────────────┼───────────────────┐
                  ▼                           ▼                   ▼
           dockerizer backend           AIPub backend       dockerizer-web
           /api/v1alpha1/                /api/v1alpha1/       /dockerizer
            dockerfiles                   login, logout,
            builds                        selfsubjectreviews
            volumes                       k8sproxy/**
            registries                   /api (나머지)
                  │                           │
                  ▼                           ├─→ JWT 발급/검증 (인증)
           [PostgreSQL]                       └─→ k8s API Server (k8sproxy)
           [k8s API — ServiceAccount]
```

## 3. Ingress 라우팅 규칙

기존 AIPub Ingress(`aipub-backend-adapter`)에 dockerizer 경로가 추가된다.
`install.sh`가 `kubectl patch`로 아래 path를 추가한다:

| 경로 | 대상 서비스 | 설명 |
|------|-----------|------|
| `/api/v1alpha1/dockerfiles` | dockerizer-backend :8080 | Dockerfile CRUD |
| `/api/v1alpha1/builds` | dockerizer-backend :8080 | 이미지 빌드 |
| `/api/v1alpha1/volumes` | dockerizer-backend :8080 | AIPubVolume 조회/탐색 |
| `/api/v1alpha1/registries` | dockerizer-backend :8080 | NGC/HuggingFace 레지스트리 |
| `/dockerizer` | dockerizer-web :80 | 프론트엔드 정적 파일 |

기존 AIPub 경로는 그대로 유지된다:

| 경로 | 대상 서비스 | 설명 |
|------|-----------|------|
| `/api/v1alpha1/login` | aipub-backend-gateway | 로그인 |
| `/api/v1alpha1/logout` | aipub-backend-gateway | 로그아웃 |
| `/api/v1alpha1/selfsubjectreviews` | aipub-backend-gateway | 인증 확인 |
| `/api/v1alpha1/k8sproxy/**` | aipub-backend-gateway | k8s API 프록시 |
| `/api` (나머지) | aipub-backend-gateway | AIPub API |
| `/` | aipub-backend-adapter | AIPub 프론트엔드 |

## 4. API 버전

모든 엔드포인트는 `/api/v1alpha1` 버전을 사용한다 (AIPub과 통일).

## 5. 인증 구조

### 로그인 (AIPub이 직접 처리 — Ingress 라우팅)

```
브라우저 → Ingress → AIPub backend
  POST /api/v1alpha1/login (form-urlencoded)
  ← Set-Cookie: AIPUB_ACCESS_COOKIE (JWT, HttpOnly, Secure)
```

### dockerizer backend 요청 인증 (Token Introspection)

dockerizer backend는 자체 엔드포인트 요청 시 AIPub의 `selfsubjectreviews`를 서버-to-서버로 호출하여 인증한다.

```
브라우저 → Ingress → dockerizer backend
  → AipubAuthenticationFilter
    1. AIPUB_ACCESS_COOKIE에서 토큰 추출
    2. AIPub selfsubjectreviews 호출 (클러스터 내부 HTTP, 쿠키 전달)
    3. isAuthenticated: true → username, roles로 SecurityContext 설정
    4. isAuthenticated: false 또는 실패 → 401
    5. 컨트롤러로 요청 진행
```

- JWT secret key 공유 없음 — 인증 주체는 AIPub에 일원화
- 캐싱 없음 — 매 요청마다 AIPub 호출
- 잠금/휴면/탈퇴 등 사용자 상태 관리를 AIPub이 일괄 처리

### k8sproxy 요청 인증 (AIPub이 직접 처리 — Ingress 라우팅)

```
브라우저 → Ingress → AIPub backend
  → 쿠키의 JWT를 Bearer token으로 변환 → k8s API Server
  → k8s webhook으로 JWT 검증 → k8s RBAC 적용
```

## 6. 배포 토폴로지

```
[AIPub Ingress (aipub-backend-adapter) — aipub.cluster10.idc1.ten1010.io]
  │
  ├─ /api/v1alpha1/dockerfiles  → dockerizer-backend Service :8080
  ├─ /api/v1alpha1/builds       → dockerizer-backend Service :8080
  ├─ /api/v1alpha1/volumes      → dockerizer-backend Service :8080
  ├─ /api/v1alpha1/registries   → dockerizer-backend Service :8080
  ├─ /dockerizer                → dockerizer-web Service :80
  │
  ├─ /api/v1alpha1/{login,logout,selfsubjectreviews,k8sproxy}
  │     → aipub-backend-gateway :8080
  ├─ /api (나머지)              → aipub-backend-gateway :8080
  └─ /                          → aipub-backend-adapter :8080

[dockerizer-backend — 클러스터 내부 통신]
  └─ AipubAuthenticationFilter → aipub-backend-gateway.aipub.svc.cluster.local:8080
     (selfsubjectreviews Token Introspection)
```

- Dockerizer는 자체 Ingress를 생성하지 않는다.
- `install.sh`가 기존 AIPub Ingress에 `kubectl patch`로 path를 추가한다.
- AIPub 서비스 URL은 Helm values로 주입 (`DOCKERIZER_AIPUB_BASE_URL`).
