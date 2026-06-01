# Dockerizer API 아키텍처

> 작성일: 2026-06-01  
> 범위: 프론트엔드 ↔ 백엔드 ↔ AIPub 간 전체 API 흐름

---

## 1. 개요

Dockerizer는 AIPub의 선택적 플러그인으로, 배포 시 AIPub의 기존 k8s 오브젝트(Service, Ingress 등)를 수정하지 않는다.
프론트엔드는 단일 도메인(dockerizer Ingress)으로 요청을 보내며, Ingress가 경로에 따라 dockerizer backend 또는 AIPub backend로 라우팅한다.

## 2. 전체 요청 흐름

```
[브라우저]
  │  credentials: 'include' (AIPUB_ACCESS_COOKIE 자동 포함)
  │
  └─── 단일 도메인 ──→ [dockerizer Ingress]
                          │
          ┌───────────────┼───────────────────┐
          ▼               ▼                   ▼
   dockerizer backend  AIPub backend       dockerizer-web
   /api/v1alpha1/       /api/v1alpha1/       /
    dockerfiles          login, logout,
    builds               selfsubjectreviews
    volumes              k8sproxy/**
    registries
          │               │
          ▼               ├─→ JWT 발급/검증 (인증)
   [PostgreSQL]           └─→ k8s API Server (k8sproxy)
   [k8s API — ServiceAccount]
```

## 3. Ingress 라우팅 규칙

dockerizer Ingress가 경로별로 서비스를 분기한다:

| 경로 | 대상 서비스 | 설명 |
|------|-----------|------|
| `/api/v1alpha1/login` | AIPub backend | 로그인 (Set-Cookie 발급) |
| `/api/v1alpha1/logout` | AIPub backend | 로그아웃 |
| `/api/v1alpha1/selfsubjectreviews` | AIPub backend | 인증 상태 확인 |
| `/api/v1alpha1/k8sproxy/**` | AIPub backend | k8s API 프록시 (사용자 RBAC 적용) |
| `/api/**` (나머지) | dockerizer backend | Dockerfile CRUD, 빌드, 볼륨, 레지스트리 |
| `/` | dockerizer-web | 프론트엔드 정적 파일 |

AIPub backend는 ExternalName Service를 통해 참조된다 (크로스 네임스페이스).

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
[dockerizer Ingress — dockerizer 도메인]
  ├─ /api/v1alpha1/{login,logout,selfsubjectreviews,k8sproxy}
  │     → ExternalName Service (same namespace)
  │       → aipub-backend-gateway.aipub.svc.cluster.local:8080
  │
  ├─ /api → dockerizer-backend Service :8080
  └─ /    → dockerizer-web Service :80

[dockerizer-backend — 클러스터 내부 통신]
  └─ AipubAuthenticationFilter → aipub-backend-gateway.aipub.svc.cluster.local:8080
     (selfsubjectreviews Token Introspection)
```

- AIPub의 Ingress/Service는 수정하지 않는다.
- AIPub 서비스 URL은 Helm values로 주입 (`DOCKERIZER_AIPUB_BASE_URL`).
