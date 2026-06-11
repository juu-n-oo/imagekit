# Dockerizer 백엔드 코드 구조 분석

> **작성일** 2026-06-11 · **대상 커밋** `main` (07621fe 기준) · **분석자** 코드 리뷰
> **범위** `imagebuild-controller`(k8s 오퍼레이터) + `dockerizer-backend-server`(REST 백엔드)
> 빌드 산출물·HTML 뷰는 같은 폴더의 `backend-architecture-review.html` 참조 (동일 내용).

이 문서는 두 가지 요청에 답한다.

1. **ImageBuild 컨트롤러**가 쿠버네티스가 권장하는 오퍼레이터 패턴을 지키는지, 백엔드와의 의존성이 최소화되어 있는지.
2. **백엔드 서버**의 구조가 적절한지, 조회·생성·수정 시 일관성 보장에 허점이 없는지.

심각도 표기: 🔴 **Critical**(출시 전 수정 권장) · 🟠 **High** · 🟡 **Medium** · ⚪ **Low/제안**

---

## 0. 요약 (Executive Summary)

전반적으로 **계층 분리·오퍼레이터 디커플링·예외 매핑** 등 기본기는 매우 잘 잡혀 있다. 특히 컨트롤러가 백엔드에 대한 컴파일 의존성이 0이고 오직 CR(ImageBuild) 을 경계로 통신하는 점은 교과서적이다.

다만 **다음 건은 출시 전 검토가 필요**하다. (🔴/🟠 중심, A 시리즈는 2차 심화 검토에서 추가)

| # | 심각도 | 요지 |
|---|--------|------|
| A-1 | 🔴 | **`/mcp/**` 가 `permitAll`(미인증)** + MCP 툴이 인가를 전면 우회. `username` 자유 입력으로 impersonation, 임의 id 삭제·빌드·로그 열람 가능 |
| B-1 | 🔴 | ImageBuild 계열 엔드포인트(빌드 트리거/목록/상태/**로그**)에 인가 검증이 전혀 없음 → 타 프로젝트 자원·로그 노출(IDOR). Dockerfile 쪽 인가와 비일관 |
| A-3 | 🟠 | Volume `browse`/`upload` 인가 부재 → 타 프로젝트 PVC 열람·**파일 업로드**(빌드 컨텍스트 주입 경로) |
| A-2 | 🟠 | CSRF 비활성 + 쿠키 기반 인증 → 상태 변경 CSRF 위험(쿠키 `SameSite` 가정에 의존) |
| B-2 | 🟠 | `triggerBuild` 가 트랜잭션 밖에서 LAZY 연관(`latestRevision`)을 접근 → `open-in-view: false` 환경에서 `LazyInitializationException` 위험 |
| B-3 | 🟠 | 리비전 `version` 채번이 read-modify-write → 동시 수정 시 유니크 충돌, 게다가 그 충돌이 "이름 중복" 409 메시지로 오인 매핑됨 |
| A-4 | 🟠 | OpenSearch 네임스페이스 필터가 `match`(분석형) → 하이픈 네임스페이스 간 **로그 누출** 가능 |
| C-1 | 🟠 ✅ | 컨트롤러가 watch 이벤트에만 의존(edge-triggered). 주기적 resync·workqueue 부재 → 이벤트 유실 시 빌드가 `Building` 에 영구 정지 가능 — **구현 완료(2026-06-11): SharedIndexInformer+workqueue 전환, C-3·C-4 동반 해결** |

그 외 인증 캐싱(A-5)·SSE 스레드풀(A-6)·exec 타임아웃(A-7)·actuator 노출(A-8)·컨트롤러 HA(leader election)·Kaniko Job 안전장치·빌드 ConfigMap 무한 누적(C-9)·CR POJO 이중정의 등은 §2·§3.5 에 정리한다.

> **인가 결론 / 일정 결정** — Dockerfile *목록* 조회만 엄격히 인가되고, **나머지 거의 모든 경로(ImageBuild 전체, Dockerfile 단건/삭제, Volume 전체, 그리고 미인증 MCP)는 프로젝트 격리가 사실상 없다.** 단, **`selfsubjectreview` 로 사용자/관리자를 구분하는 현행 메커니즘(`AipubAuthenticationFilter` → roles, `DockerfileController.isAdmin`)은 유지**한다. 그 외 **기본 인증/인가 정비(A-1·B-1·A-3·B-5·A-2)는 베타 기능 개발을 마친 뒤 가장 마지막에 횡단 관심사로 일괄 진행**하기로 한다(프로젝트 결정). 심각도는 높으나 일정상 후순위이며, 그 사이 MCP·Volume 등은 **네트워크 레벨(내부 전용 노출)로만 보호**됨을 전제한다.

---

## 1. 아키텍처 개요

```
[브라우저] ──REST──> [dockerizer-backend-server]
                          │  (1) Dockerfile CRUD → PostgreSQL
                          │  (2) 빌드 트리거: ImageBuild CR 생성
                          ▼
                    ┌─────────────┐   watch    ┌──────────────────────┐
                    │  k8s API    │ <───────── │ imagebuild-controller │
                    │  (CR 저장소)│ ─ patch ─> │  (오퍼레이터)         │
                    └─────────────┘            └──────────┬───────────┘
                          ▲                                │ ConfigMap/Job 생성
                          │ 로그(Pod stdout / OpenSearch)  ▼
                    [Kaniko Job/Pod] ──push──> [Harbor/ImageHub]
```

- **백엔드 → 컨트롤러** 통신은 전적으로 **ImageBuild CR** 을 통해 일어난다(직접 호출 없음).
- 컨트롤러는 CR `spec` 을 읽어 ConfigMap+Kaniko Job 을 만들고, 진행 상태를 CR `status` 로 patch 한다.
- 백엔드는 CR `status` 를 polling/조회해 프론트에 노출하고, 빌드 로그는 Pod stdout(완료 1h 후엔 OpenSearch fallback)을 읽는다.

---

## 2. ImageBuild 컨트롤러 (k8s 오퍼레이터)

### 2.1 잘 지켜진 점 ✅

- **CR 설계 정석**: `subresources.status: {}` 로 spec/status 분리, `additionalPrinterColumns`(Phase/Target Image/Age), `shortNames`(ib/imgbuild), `helm.sh/resource-policy: keep` 로 CRD 보존. (`crd.yaml`)
- **Owner reference 로 GC 위임**: ConfigMap·Job 에 `controller=true, blockOwnerDeletion=true` 부여(`KanikoJobFactory.ownerReference`) → CR 삭제 시 자식 리소스 cascade 삭제. 별도 finalizer 없이 깔끔.
- **상태 머신**: `Pending → Preparing → Building → Succeeded/Failed` 단방향 phase 전이(`ImageBuildReconciler.reconcile`).
- **Event 기록**: 전이/성공/실패를 Normal/Warning Event 로 남겨 `kubectl describe` 관측성 확보(`EventRecorder`).
- **informer + workqueue 기반 재조정** (C-1/C-3/C-4 전환 후): `SharedIndexInformer`(resync 45s)로 주기 재조정·재시작 회복, 단일 워크큐로 키 직렬화, Lister 캐시 read(`InformerControllerConfiguration`, `ControllerRunner`).
- **Job informer 라벨 셀렉터**: `app.kubernetes.io/managed-by=dockerizer-controller` 로 자기 소유 Job 만 watch → 노이즈 차단.
- **최소 권한 RBAC**: CR/configmap/job/event 에 필요한 verb 만 부여(`clusterrole.yaml`). configmaps 는 get/create 만, jobs 는 delete 없음 등 절제됨.
- **결정적 라벨 args**: `imageLabels` 를 key 정렬 후 `--label` 생성 → 동일 입력에 동일 Job 스펙(`KanikoJobFactory.kanikoContainer`).

### 2.2 이슈

#### C-1 🟠 edge-triggered 전용 — resync/workqueue 부재 — ✅ 구현 완료 (2026-06-11)
`reconcile` 은 watch 이벤트(ADDED/MODIFIED)에 의해서만 구동된다. 주기적 resync 가 없어, **Job 완료 MODIFIED 이벤트가 유실되면(watch gap/북마크 누락) 빌드가 `Building` 에 영구히 머문다.**
- 부분 완화: watch 가 끊겼다 재연결되면 `list...watch(true)` 가 기존 CR 을 ADDED 로 재전달 → 재조정됨. 즉 **컨트롤러 재시작/재연결 시점엔 회복**되지만, 연결이 유지된 채 단일 이벤트만 누락되면 회복 트리거가 없다.
- 권장: 이미 의존성에 있는 **`client-java-extended` 의 `SharedIndexInformer` + `Controller`(workqueue)** 로 전환. resyncPeriod(예: 30~60s)를 주면 주기적 재조정이 보장되고, 캐시 Lister 로 read 부하도 준다.
- **구현**: 직접 watch 루프(`ImageBuildWatcher`/`JobWatcher`, 삭제)를 `SharedIndexInformer`+`Controller`(workqueue)로 전환(`InformerControllerConfiguration`, `ControllerRunner`). `resyncPeriodSeconds=45`(`ControllerProperties`)로 캐시된 전 CR 이 주기 재조정 → 단일 MODIFIED 유실에도 `Building` 영구 정지 안 됨. 재시작 시 initial LIST 로 전체 enqueue 되어 `status.phase` 에서 이어서 재조정.

#### C-2 🟠 leader election 부재 + HPA 동봉 (다중 replica 시 중복 reconcile) — ✅ 구현 완료 (2026-06-11, 권장안 a)
컨트롤러에 **리더 선출이 없다.** 현재 `replicaCount: 1` 로 안전하지만, 차트에 **HPA 템플릿이 동봉**되어 있고 `autoscaling.maxReplicas: 100` 이다(`hpa.yaml`, `values.yaml`). 누군가 `autoscaling.enabled=true` 로 켜거나 replica 를 늘리면, **모든 replica 가 각자 watch·reconcile** 해서 동일 CR 에 대해 ConfigMap/Job 중복 생성·status patch 경합이 발생한다(409 가드로 일부만 방어됨).
- 권장(택1): (a) 컨트롤러 차트에서 **HPA 제거 + 단일 replica 고정**을 명시, 또는 (b) HA 가 필요하면 `client-java-extended` 의 **`LeaderElector`(Lease 기반)** 도입 후에만 다중 replica 허용. 컨트롤러는 CPU 로 스케일하는 워크로드가 아니므로 (a) 가 적합.
- **구현 (권장안 a)**: `helm/imagebuild-controller/templates/hpa.yaml` 삭제, `values.yaml` 의 `autoscaling` 블록 제거. `deployment.yaml` 에서 autoscaling 분기를 없애고 `replicas: {{ .Values.replicaCount }}` 고정 + **render 단계 가드**(`replicaCount>1` 이면 `fail` — "no leader election; replicaCount must be 1") 추가. `replicaCount` 주석에 리더 선출 부재·다중 replica 위험 명시. `helm template` 으로 기본값 `replicas:1`·HPA 0개, `--set replicaCount=2` 시 render 실패 확인. HA 필요 시 LeaderElector 도입은 별도 작업으로 남김.

#### C-3 🟡 두 watcher 가 같은 CR 을 동시 reconcile — 키 직렬화 없음 — ✅ 구현 완료 (2026-06-11)
`ImageBuildWatcher` 와 `JobWatcher` 가 **서로 다른 스레드에서 같은 `reconciler.reconcile(ns,name)` 을 직접 호출**한다. 동일 빌드에 대해 두 이벤트가 동시에 들어오면 reconcile 이 병렬 실행될 수 있다(존재 검사 후 생성하는 TOCTOU, status patch interleave).
- 현재는 409 처리·merge patch 로 치명적 결과는 대체로 회피되나, **키 단위 직렬화 보장이 없다.**
- 권장: C-1 의 workqueue 도입 시 자연 해결(키 dedup + 단일 워커 per key). 당장은 reconcile 을 `ns/name` 키 기준으로 직렬화(예: per-key lock 또는 단일 워크큐)하는 것만으로도 안전.
- **구현**: C-1 전환으로 해결. CR/Job 두 소스 이벤트가 모두 단일 워크큐로 들어가고(`InformerControllerConfiguration` 의 Job 이벤트 핸들러가 소유 ImageBuild `Request` 를 같은 큐에 enqueue), `workerCount=1` 로 동일 키 직렬 처리.

#### C-4 🟡 SharedInformer 캐시 미사용 — 매 이벤트 live GET — ✅ 구현 완료 (2026-06-11)
`handleEvent` 가 watch 로 **이미 전체 CR 객체를 받았는데도** `reconcile` 안에서 `getImageBuild` 로 API 서버를 다시 GET 한다(`ImageBuildReconciler.getImageBuild`). 이벤트 N건 = GET N회. informer 캐시를 쓰면 로컬 캐시에서 읽는다.
- 권장: C-1 전환 시 Lister 캐시 사용. 최소한 watch 로 받은 객체를 그대로 reconcile 에 넘겨 중복 GET 제거 가능.
- **구현**: `reconcile(Request)` 가 `Lister<ImageBuildResource>`(informer 캐시)에서 CR 을 읽도록 변경 — live `getNamespacedCustomObject` GET 제거.

#### C-5 🟡 Kaniko Job 안전장치 부재 (activeDeadlineSeconds·resources) — 🟢 부분 완료 (2026-06-11)
`KanikoJobFactory.createKanikoJob` 의 Job/Pod 에 **`activeDeadlineSeconds` 가 없어** 멈춘(hung) 빌드가 무한정 노드를 점유한다. 또 Kaniko 컨테이너에 **resources requests/limits 가 없어** 공유 클러스터에서 메모리 폭주 시 노드를 위협할 수 있다(`backoffLimit(0)`·`ttlSecondsAfterFinished` 는 설정됨).
- 권장: `activeDeadlineSeconds`(예: 30~60분, `ControllerProperties` 로 설정), Kaniko 컨테이너 resources(설정값)를 추가.
- **구현 (activeDeadlineSeconds만)**: Job 에 `activeDeadlineSeconds` 부여. 기본값 `ControllerProperties.buildTimeoutSeconds=3600`(60분), CR `spec.buildTimeoutSeconds`(CRD 추가) 로 빌드별 override — 프론트 빌드 다이얼로그에서 **분 단위 입력 → 초 변환**해 CR 에 전달. `activeDeadlineSeconds` 는 wall-clock 상한일 뿐 "느린 빌드 vs 멈춘 빌드" 를 구분하지 못하므로, ① 정상 빌드는 닿지 않을 관대한 기본값 + 사용자 조정, ② 실패 사유가 `DeadlineExceeded` 면 빌드 에러와 구분해 "제한 시간(N분) 초과" 메시지로 표출(`ImageBuildReconciler.extractFailureMessage`)하는 방식으로 보완.
- **미구현 (잔여)**: Kaniko 컨테이너 **resources requests/limits** 는 아직 없음 — 메모리 폭주 보호는 별도 작업으로 남음.

#### C-6 🟡 `imageDigest` 가 항상 null — ✅ 구현 완료 (2026-06-11)
`handleBuilding` 이 성공 시 `statusUpdater.markSucceeded(cr, null)` 로 **digest 를 항상 null** 로 기록한다. CRD·응답 DTO 에 `imageDigest` 필드가 있으나 채워지지 않는다.
- 권장: Kaniko `--digest-file=/dev/termination-log`(또는 파일) 출력을 Pod 에서 읽어 digest 를 status 에 채우기. 또는 digest 미지원을 명시적으로 문서화.
- **구현**: Kaniko 에 `--digest-file=/dev/termination-log` 추가(`KanikoJobFactory`, 컨테이너 `terminationMessagePath/Policy` 명시). `handleBuilding` 성공 시 빌드 Pod 의 kaniko 컨테이너 `terminated.message` 에서 digest 를 읽어(`readImageDigest`) `markSucceeded(cr, digest)` 로 기록. 미취득(Pod GC/빈 값/오류) 시 null 로 graceful — 빌드 성공은 유지.

#### C-7 🟡 `--insecure` / `--skip-tls-verify` 하드코딩 — ✅ 구현 완료 (2026-06-11)
모든 빌드가 무조건 insecure registry + TLS 검증 skip 으로 push 한다(`kanikoContainer`). 내부 Harbor(self-signed) 대상이라 의도된 것이나, **대상 레지스트리를 선택할 수 없고** 보안 옵션이 코드에 고정되어 있다.
- 권장: `ControllerProperties`/CR spec 으로 토글화(기본은 현행 유지).
- **구현**: `ControllerProperties.registryInsecure`/`registrySkipTlsVerify`(둘 다 기본 true=현행 유지) 토글 추가. `kanikoContainer` 가 토글 값에 따라 `--insecure`/`--skip-tls-verify` 를 조건부로 부여. (대상 레지스트리 선택은 별도 범위로 유지.)

#### C-8 ⚪ 기타
- `configMapExists`/`jobExists` 가 **모든 `ApiException` 을 false 로 간주**(500/403 도 "없음" 처리) → 진짜 오류를 생성 시도로 흘림. 404 만 false 로 좁히는 게 안전.
- `EventRecorder` 가 레거시 `core/v1` Event + 랜덤 8자 suffix 이름 사용. modern `events.k8s.io/v1` / `generateName` 권장(동작엔 무방).
- 각 컴포넌트가 `new Gson()` 개별 생성 — 공유 bean 으로 모아도 됨(사소).
- CRD `status.phase default: Pending` 은 status 서브리소스 특성상 생성 시 적용 안 될 수 있음(코드의 `currentPhase` 가 null→Pending 으로 보정하므로 무해).

#### C-9 🟠 빌드 ConfigMap 수명이 CR 수명에 묶여 무한 누적 — ✅ 구현 완료 (2026-06-11, 권장안 A)
빌드마다 `<cr>-dockerfile` ConfigMap(Dockerfile 본문 보관)을 만드는데(`ImageBuildReconciler.java:54-76`, `KanikoJobFactory.java:28-37`), 이 CM 의 `ownerReference` 가 **ImageBuild CR** 로 설정되어 있어(`KanikoJobFactory.java:36`) **CR 이 삭제될 때만** GC 된다. 코드 어디에도 `deleteNamespacedConfigMap` 호출이 없다. 따라서 **빌드 이력을 위해 CR 을 보존하면 CM 도 빌드 1건당 1개씩 영구 누적**된다.

- 비대칭 주의: Kaniko **Job/Pod 는 `jobTtlSeconds=3600`(1h) TTL 로 자동 GC** 되어 bounded 인 반면, **CR·CM 은 retention 정책이 없어 unbounded** 다. (`--max-pods`(노드당 110)는 *동시 실행* Pod 한도일 뿐 누적과 무관 — 진짜 누적 주체는 CR/CM.)
- 영향: ① 프로젝트 네임스페이스에 `count/configmaps` **ResourceQuota** 가 있으면 죽은 빌드 CM 이 한도를 잠식 → 새 빌드가 CM 생성 단계에서 실패(`markFailed`)하고, **같은 ns 의 다른 워크로드(Workspace 등) CM 예산까지 빼앗음**. ② etcd 저장 압박(빌드 수 × 수 KB). ③ informer(C-1 도입 시) 가 전 CR 을 메모리 캐싱 → CR 수에 비례해 메모리·LIST 지연 증가.
- 권장: **CM 수명을 CR 수명에서 분리.** Dockerfile 원본은 백엔드 DB(Dockerfile/revision) 와 **CR `spec.dockerfileContent` 자체에 이미 보존**되므로 CM 은 빌드 중에만 필요한 일회용 입력이다.
  - (A, 권장) terminal phase 진입(`markSucceeded`/`markFailed`) 직후 `deleteNamespacedConfigMap(<cr>-dockerfile)` 호출 — CR 은 이력 보존, CM 만 폐기. 재빌드 시 `configMapExists` 체크로 재생성됨.
  - (B) CM `ownerReference` 를 CR → Job 으로 변경하여 Job TTL 때 함께 GC(코드 변경 최소이나 재빌드 시 owner 꼬임 주의).
- 더불어 CR 자체를 무한 보관할 계획이면 별도 retention(Dockerfile 당 최근 N개 등)·백엔드 LIST 페이지네이션을 함께 검토.
- **구현 (권장안 A)**: `ImageBuildReconciler.deleteDockerfileConfigMap` 추가, terminal 전이 시 1회 호출 — `handleBuilding` 의 성공/실패, `handlePending`/`handlePreparing` 의 `markFailed` 직후. 404(이미 없음)는 무시. terminal-case 반복 삭제가 아닌 전이 시점 1회라 resync 마다 API 호출이 늘지 않음. CR retention·LIST 페이지네이션은 잔여 검토 항목으로 유지.

### 2.3 백엔드와의 의존성 최소화 평가

**강점 (매우 우수)** — 컨트롤러 모듈 `build.gradle` 의존성은 **Spring Boot + k8s client 뿐**, 백엔드 서버에 대한 컴파일 의존성이 **0**이다. 두 컴포넌트는 오직 **ImageBuild CR 을 API 경계**로 통신한다(백엔드는 CR 생성, 컨트롤러는 reconcile/status patch). 이는 오퍼레이터 디커플링의 정석이며, 컨트롤러를 독립 배포·확장·재시작해도 백엔드와 결합이 없다.

**약점 — 계약(CR 스키마)의 이중 정의로 인한 drift 위험** 🟡
같은 CR 모델이 **양쪽에 따로 정의**되어 수기로 동기화되고 있다.

| 개념 | 컨트롤러 | 백엔드 |
|------|----------|--------|
| 상수(GROUP/VERSION/PLURAL/Phase) | `cr/ImageBuildConstants` | `imagebuild/cr/ImageBuildConstants` |
| spec POJO | `cr/ImageBuildSpec` | `imagebuild/cr/ImageBuildSpec` |
| status POJO | `cr/ImageBuildStatus` | `imagebuild/cr/ImageBuildStatus` |
| CR 래퍼 | `cr/ImageBuildResource` | `imagebuild/cr/ImageBuildCr` |
| 라벨 키(`aipub.ten1010.io/...`) | `JobWatcher`/`KanikoJobFactory` 문자열 | `ImageBuildService` 문자열 |

- 예: 백엔드가 `spec` 에 필드를 추가해도 컨트롤러 POJO 에 미러링하지 않으면 Gson 역직렬화에서 **조용히 누락**된다. 라벨 키 오타도 컴파일에 안 걸린다.
- 권장: **`imagebuild-api`(또는 `imagebuild-contract`) 공유 Gradle 모듈** 신설 — CR POJO + 상수 + 라벨 키만 담아 양 모듈이 의존. 런타임 디커플링(별도 프로세스)은 유지한 채 **컴파일 타임에 계약을 공유**해 drift 제거. (대안: CRD 에서 모델 생성)

---

## 3. 백엔드 서버 구조 & 일관성

### 3.1 잘 지켜진 점 ✅

- **패키지 by feature + 계층 분리**: `dockerfile / imagebuild / volume / registry / aipub / common`, 각 도메인 안에서 controller→service→repository→entity/dto 일관.
- **트랜잭션 경계**: `DockerfileService`/`DockerfileRevisionService` 클래스에 `@Transactional(readOnly=true)`, 쓰기 메서드에 `@Transactional` 오버라이드(정석).
- **이름 유일성 방어 심층화**: 서비스 사전 검사(`existsBy...`) + DB 유니크 제약(`uq_dockerfiles_project_username_name`) + `GlobalExceptionHandler` 의 `DataIntegrityViolationException → 409` 안전망.
- **RFC 7807 ProblemDetail** 로 에러 표준화.
- **리비전 불변 이력**: 수정/롤백이 기존 리비전을 변경하지 않고 새 버전 append(롤백도 "새 리비전" 으로 기록). 감사·복원에 적합.
- **Dockerfile 인가가 백엔드에서 검증됨**: `list(all=true)` 는 토큰 roles 로 관리자 여부를 백엔드가 직접 확인(`DockerfileController.isAdmin`), 멤버 경로는 토큰의 본인 username 으로 gate → 프론트 분기를 신뢰하지 않음. **올바른 패턴.**

### 3.2 이슈

#### B-1 🔴 ImageBuild 엔드포인트 인가 부재 (IDOR) — Dockerfile 인가와 비일관
`ImageBuildController` 의 **어떤 엔드포인트에도 인가 검증이 없다.**
- `GET /builds?project=…`, `GET /builds/{ns}/{name}`, `GET /builds/{ns}/{name}/logs` : 인증된 사용자라면 **임의의 project/namespace 값을 넘겨 타 프로젝트의 빌드 목록·상태·빌드 로그를 열람**할 수 있다. 로그에는 빌드 과정의 민감 정보가 섞일 수 있다.
- `POST /builds` (`triggerBuild`) : 요청의 `dockerfileId` 로 Dockerfile 을 조회할 뿐 **호출자 소유/프로젝트 바인딩을 확인하지 않는다** → 타인의 Dockerfile 을 임의 target image 로 빌드 가능.
- 이는 `DockerfileController` 가 username/admin 으로 꼼꼼히 막아둔 것과 **정면으로 비일관**하며, 계획 문서(`build-log-opensearch-fallback.md`)가 전제한 "백엔드 권한 체크가 namespace 기준 동작" 도 실제로는 없다.
- 권장: ImageBuild 계열에도 **`Authentication` 주입 + 프로젝트 바인딩/소유권 검증**(멤버는 자신이 바인딩된 project 만, triggerBuild 는 dockerfile 소유·project 일치 확인, admin 예외)을 추가. Dockerfile 쪽 패턴을 그대로 재사용.

#### B-2 🟠 `triggerBuild` LAZY 연관 접근 → LazyInitializationException 위험
`ImageBuildService` 는 `@Transactional` 이 **없다.** `triggerBuild` 가 `dockerfileRepository.findById(...)` 로 받은 detached 엔티티에서 **LAZY `@OneToOne latestRevision`** 을 접근한다(`dockerfile.getLatestRevision().getId()`).
- 설정 확인 결과 `spring.jpa.open-in-view: false`(`application.yaml`). 즉 **요청 스레드에 열린 세션이 없어, lazy 접근 시점에 `LazyInitializationException` 이 날 수 있다.** (OSIV=true 였다면 우연히 동작했을 코드 — 설정상 false 이므로 실제 위험.)
- 권장: `triggerBuild` 를 `@Transactional(readOnly=true)` 로 감싸거나, `latestRevision` 을 fetch join 으로 즉시 로딩하는 조회 메서드 사용. (현 동작이 통과한다면 어딘가에서 세션이 유지되는 것이며, 의도에 의존하지 말 것.)

#### B-3 🟠 리비전 version 채번 race + 오인 유발 에러 메시지
`DockerfileService.update` 와 `DockerfileRevisionService.rollback` 의 다음 채번이 **read-modify-write** 다.
```java
int nextVersion = revisionRepository.findTopByDockerfileIdOrderByVersionDesc(id)
        .map(r -> r.getVersion() + 1).orElse(1);
```
- 같은 Dockerfile 에 동시 수정 2건이 들어오면 둘 다 같은 `nextVersion` 계산 → `uq_revisions_dockerfile_version` 위반으로 한쪽이 `DataIntegrityViolationException`.
- 그런데 `GlobalExceptionHandler.handleDataIntegrity` 가 **모든** `DataIntegrityViolationException` 을 `409 "이미 같은 이름의 Dockerfile 이 있습니다."` 로 매핑 → **버전 충돌인데 "이름 중복" 으로 오인** 표출.
- 권장: (1) Dockerfile 엔티티에 `@Version` 낙관적 락 또는 per-dockerfile 시퀀스로 채번 경쟁 제거, (2) 예외 핸들러를 제약명 기준으로 분기하거나 서비스에서 충돌을 잡아 재시도/적절한 메시지로 변환.

#### B-4 🟡 읽기 경로의 Map 스펠렁킹 vs 쓰기 경로의 타입 빌더 — 비일관
빌드 **쓰기**(`triggerBuild`)는 타입 안전한 `ImageBuildCr.builder()` 를 쓰는 반면, **읽기**(`listBuilds`/`getBuildStatus`)는 `(Map<String,Object>)` 캐스팅 + `@SuppressWarnings("unchecked")` + `gson.toJson(gson.fromJson(...))` 라운드트립으로 CR 을 헤집는다(`crMapToResponse`). 타입 안전성이 없고 키 오타·구조 변경에 취약하다.
- 권장: 이미 존재하는 `ImageBuildCr` POJO(또는 §2.3 의 공유 모델)로 직접 역직렬화하여 읽기/쓰기 표현을 통일.

#### B-5 🟡 `getById`/`delete` 소유권 미검증 (B-1 의 연장)
`DockerfileController.getById(id)` 와 `delete(id)` 는 **인증 주체를 받지 않고** id 만으로 동작한다. 목록은 username 으로 막아두었지만, **id 를 알면 타인 Dockerfile 단건 조회·삭제가 가능**하다(IDOR).
- 권장: 단건/삭제에도 호출자 소유 또는 admin 검증 추가(목록과 동일 기준).

#### B-6 ⚪ JPA cascade 미설정 — DB ON DELETE CASCADE 에 의존
`delete()` 주석은 "모든 리비전도 함께 삭제" 라 하지만, JPA 엔티티에는 cascade/orphanRemoval 이 없다. 실제 삭제는 **DB 스키마의 `dockerfile_revisions.dockerfile_id ... ON DELETE CASCADE`** 에 의존한다(`Dockerizer_1.0.0__initial_schema.sql`). 기능상 동작하나, JPA 영속성 컨텍스트는 이를 모른다.
- 또한 `dockerfiles.latest_revision_id → dockerfile_revisions` 순환 FK 는 cascade 가 아니다. 삭제 대상 행 자체가 사라지며 정리되므로 현재는 문제 없으나, **삭제 동작이 JPA 가 아닌 DB 제약에 묶여 있음**을 인지해야 한다(ddl-auto: validate 는 cascade 일치까지 검증하지 않음).
- 권장: 의존 관계를 코드/문서에 명시하거나 JPA cascade 와 DB 제약을 일치.

#### B-7 ⚪ 기타
- `listBuilds`/`getBuildLogs` 의 ApiException → `RuntimeException` 래핑은 `GlobalExceptionHandler` 에 매핑이 없어 **500** 으로 떨어진다(`ResourceNotFoundException` 만 404). k8s 오류(403/timeout 등)에 대한 분류된 응답이 없음.
- `findById` 류 헬퍼가 도메인 서비스마다 중복(소소).

### 3.3 일관성(조회/생성/수정) 종합

| 시나리오 | 현 상태 | 비고 |
|----------|---------|------|
| Dockerfile 생성·수정 트랜잭션 원자성 | ✅ 양호 | `@Transactional` 로 entity+revision 원자 저장 |
| 이름 중복 동시성 | ✅ 방어됨 | 사전검사+유니크제약+409 안전망 |
| **리비전 버전 동시성** | ⚠️ **B-3** | read-modify-write race + 오인 메시지 |
| **빌드 트리거 세션 일관성** | ⚠️ **B-2** | OSIV=false 에서 lazy 접근 위험 |
| 빌드 시 컨텐츠 스냅샷 | ✅ 양호 | CR spec 에 시점 content 복사(이후 수정과 분리) |
| CR 읽기/쓰기 표현 | ⚠️ B-4 | 쓰기 타입세이프 / 읽기 Map |
| **인가 일관성** | 🔴 **B-1/B-5** | Dockerfile 은 엄격, ImageBuild·단건/삭제는 무방비 |

---

## 3.5. 2차 심화 검토 — 추가 발견 (A 시리즈)

1차에서 다루지 않은 영역(인증 필터·시큐리티, 볼륨 파일 브라우징/업로드의 pod exec, MCP 노출, OpenSearch 신규 코드, SSE 스레드풀, 레지스트리)을 다시 정밀 검토한 결과다.

#### A-1 🔴 MCP 엔드포인트가 인증 없이 노출 + 인가 전면 우회 (impersonation)
`SecurityConfiguration` 가 **`/mcp/**` 를 `permitAll()`** 로 열어둔다. 그런데 `McpServerConfiguration` 의 MCP 툴들은 REST 컨트롤러를 거치지 않고 서비스를 직접 호출하며, **인가가 전혀 없다.**
- `createDockerfile(project, username, …)` : **`username` 이 호출자가 채우는 자유 입력** → 누구든(미인증 포함) **임의 사용자 소유로 Dockerfile 생성**(impersonation).
- `deleteDockerfile(id)` / `updateDockerfile(id, …)`(작성자 `"mcp-tool"` 하드코딩) : **인증·소유권 없이 임의 id 삭제·수정**.
- `triggerImageBuild(dockerfileId, targetImage, tag)` : **임의 Dockerfile 을 임의 이미지로 빌드/푸시**.
- `getBuildLogs(namespace, name)` : **임의 빌드 로그 열람**.
- 즉 MCP 표면은 REST(최소한 인증은 요구)보다도 약해, **앱 계층에서 완전 무방비**다. 네트워크 정책으로 클러스터 내부에만 노출되는지 여부에 보안이 전적으로 의존한다.
- 권장: (1) `/mcp/**` 를 인증 대상으로 전환하거나 최소한 별도 인증/내부 전용으로 제한, (2) MCP 툴에서 `username` 자유 입력 제거(인증 주체에서 유도), (3) 삭제/수정/빌드 툴에 소유권·관리자 검증을 REST 와 동일하게 적용. **노출 경로(ingress 포함 여부) 즉시 확인 필요.**

#### A-2 🟠 CSRF 비활성 + 쿠키 기반 인증 → CSRF 위험
인증은 `AIPUB_ACCESS_COOKIE` 쿠키로 이뤄지는데(`AipubAuthenticationFilter`), `SecurityConfiguration` 가 **`csrf().disable()`** 한다. 쿠키 기반 인증에서 CSRF 를 끄면, 악성 사이트가 사용자의 브라우저로 **상태 변경 요청(생성/수정/삭제/빌드/업로드)을 자동 전송**할 수 있다(쿠키가 자동 첨부됨).
- 완화 여부는 AIPub 로그인이 쿠키에 설정하는 `SameSite` 속성에 달려 있다(Lax/Strict 면 상당 부분 차단). 그러나 **앱이 그 가정을 검증하지 않는다.**
- 권장: 쿠키의 `SameSite` 보장을 확인하고, 불가하면 상태 변경 메서드에 CSRF 토큰 또는 `Origin/Referer` 검증 도입.

#### A-3 🟠 Volume 브라우징/업로드 인가 부재 (IDOR, B-1 확장)
`VolumeController` 의 `listVolumes`/`browse`/`upload` 가 `namespace`/`volumeName` 을 경로변수로 받되 **인가 검증이 없다.** 인증된(또는 A-1 경로로는 미인증) 사용자가 **타 프로젝트 볼륨을 열람**하고, 더 심각하게는 **타 프로젝트 PVC 에 임의 파일을 업로드**할 수 있다. 이 PVC 는 그대로 빌드 컨텍스트로 마운트되므로, **타인의 빌드에 파일을 주입**하는 경로가 된다.
- 권장: 볼륨 엔드포인트에도 프로젝트 바인딩/소유권 검증 추가(Dockerfile 패턴 재사용).
- 참고(양호): 경로/파일명은 셸을 거치지 않고 exec 인자로 직접 전달(`{"dd","of="+fullPath}`, `{"ls","-lan",fullPath}`)하며 `validatePath`(`..` 거부)·`resolveFilename`(구분자/`..` 거부)로 트래버설을 막아 **셸 인젝션·디렉토리 이탈은 방어**되어 있다.

#### A-4 🟠 OpenSearch 네임스페이스 필터가 `match`(분석형) → 네임스페이스 간 로그 누출 위험
`OpenSearchBuildLogClient.fetchPodLogs` 가 `kubernetes.namespace_name`·`container_name` 을 **`match`** 로 거른다. 매핑이 전부 `text`(`.keyword` 없음)라 `match` 는 **분석된 토큰 OR 매칭**이다. `aipub-foo` 같이 하이픈이 든 네임스페이스는 `aipub`/`foo` 토큰으로 쪼개져, **다른 네임스페이스(`aipub-bar`)의 로그가 섞여 반환될 수 있다.** 인가 부재(B-1 의 로그 경로)와 겹치면 타 프로젝트 빌드 로그 노출로 이어진다.
- 권장: 네임스페이스·컨테이너 필터를 **`match_phrase`** 로 변경(전체 구문 일치 요구)해 토큰 부분매칭 누출을 차단. pod_name 의 `match_phrase_prefix` 는 CR id 가 전역 유일하므로 유지 가능.

#### A-5 🟠 인증 필터가 매 요청마다 외부 selfsubjectreviews 호출 (캐시 없음)
`AipubAuthenticationFilter` 가 **모든 요청마다** AIPub `selfsubjectreviews` 로 원격 검증한다(캐시 없음). 결과: (1) 매 API 에 외부 왕복 지연 추가, (2) `aipub-web-server` 부하, (3) **가용성 결합** — 인증 서버 장애 시 전 요청이 미인증 → 403(fail-closed 자체는 안전).
- 권장: 쿠키값 기준 짧은 TTL 캐시(예: 30~60초) 도입으로 호출량·지연 절감.

#### A-6 🟡 SSE 로그 스트림 스레드풀이 무제한 + 종료 처리 없음
`ImageBuildService` 의 `logStreamExecutor = Executors.newCachedThreadPool()` 은 **상한 없는** 풀이고 `@PreDestroy` 종료도 없다. 각 SSE 작업은 최대 5분간 Pod 로그를 블로킹 read 한다. 동시 스트림이 많아지면(또는 악의적으로 다수 연결) **스레드 무한 증가 → 자원 고갈(DoS)**.
- 권장: 경계 있는 풀(또는 사용자/전역 동시 스트림 상한) + `@PreDestroy` 셧다운.

#### A-7 🟡 Volume exec 에 타임아웃 없음 (요청 스레드 무기한 블로킹)
`execListFiles`(WebSocket exec)·`upload`(`proc.waitFor()`)에 **타임아웃이 없다.** 헬퍼 Pod 가 멈추면 서블릿 요청 스레드가 무기한 블로킹되고, 예외 경로에서 WebSocket 스트림 정리가 보장되지 않아 누수 가능.
- 권장: exec/waitFor 에 타임아웃 부여(초과 시 `proc.destroyForcibly()` + 명확한 에러), 스트림 try-with-resources 보강.

#### A-8 🟡 `actuator/**` 전체 permitAll
`actuator/**` 가 `permitAll()` 이다. 노출 엔드포인트가 `MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE` 설정에 좌우되는데, `env`/`beans`/`heapdump` 등이 포함되면 **정보 노출**이 된다.
- 권장: actuator 노출을 `health`/`prometheus` 등 최소로 고정하거나 actuator 경로에 인증/네트워크 제한.

#### A-9 🟡 업로드 한도 2GB + dd 패스스루, 앱 레벨 쿼터 없음
`spring.servlet.multipart.max-file-size/max-request-size: 2GB` 이며 업로드는 dd 로 PVC 에 바로 흘려보낸다. 볼륨별/사용자별 쿼터 검증이 코드에 없어 **단일 업로드로 PVC 를 가득 채울** 수 있다(A-3 인가부재와 겹치면 타 프로젝트 PVC 도).
- 권장: 합리적 상한·볼륨 잔여용량 확인 또는 정책 문서화.

#### A-10 ⚪ `ls -lan` 출력 파싱 취약
`parseLine` 은 GNU/busybox `ls` 포맷에 강결합되어 있고, **심볼릭 링크**(`name -> target` 가 이름에 섞임), **공백/개행 포함 파일명**, 날짜 포맷 차이에 취약하다(헬퍼 이미지 고정이라 현재는 동작).
- 권장: 가능하면 구조적 출력(예: `find -printf`/`stat`) 또는 견고한 파서.

#### A-11 ⚪ 레지스트리 외부 호출 — 에어갭/타임아웃/Map 파싱
NGC/HuggingFace 검색은 **외부 인터넷 호출**이다(`nvcr.io`, catalog API). 에어갭 AIPub 에서는 비활성(`@Autowired(required=false)`)일 수 있으나, 활성 시 `RestClient` 에 **타임아웃 설정이 없어** 외부 지연이 요청 스레드를 묶을 수 있고, 응답을 다시 Map 으로 헤집는다.
- 권장: 외부 클라이언트에 connect/read 타임아웃, 에어갭 환경에서의 비활성 기본값 명시.

#### A-12 ⚪ DockerfileValidator 문서 불일치 + 동작 메모
검증기는 설정(`DockerizerProperties.forbiddenInstructions`) 기반 **denylist** 인데, **REST 설명("COPY는 허용")과 MCP `@Tool` 설명("COPY/ADD … 거부")이 상반**된다. 정규식(`^\s*INSTR\s`)은 라인 시작 기준이라 주석은 오탐하지 않으나, 실제 금지 목록과 문서를 일치시켜야 한다.
- 권장: 금지 지시자 목록을 단일 출처로 두고 REST/MCP/PRD 설명을 동기화.

---

## 4. 우선순위 개선 로드맵

> **일정 정책** — `selfsubjectreview` 기반 사용자/관리자 구분은 현행 유지. 그 외 **기본 인증/인가 정비(A-1·B-1·A-3·B-5·A-2)는 베타 기능 개발을 마친 뒤 마지막 단계에서 하나의 횡단 작업으로 일괄 처리**한다. 따라서 아래 순위는 **기능·정합성·안정성 작업을 우선**하고 인가 정비를 맨 뒤로 둔 것이다(심각도와 일정 우선순위는 별개임에 유의).

| 순위 | 항목 | 심각도 | 분류 | 예상 작업량 |
|------|------|--------|------|-------------|
| 1 | **B-2** triggerBuild 트랜잭션/패치 | 🟠 | 정합성 | 소 |
| 2 | **B-3** 리비전 채번 락 + 예외 메시지 분기 | 🟠 | 정합성 | 소~중 |
| 3 | **A-4** OpenSearch 필터 `match_phrase` 전환 | 🟠 | 정확성 | 소 |
| ~~4~~ | ~~**C-1/C-3** 컨트롤러 SharedInformer+workqueue 전환~~ ✅ 완료(2026-06-11, C-4 동반) | 🟠 | k8s 패턴 | 중 |
| ~~5~~ | ~~**C-2** HPA 제거(또는 leader election)~~ ✅ 완료(2026-06-11, 권장안 a: HPA 제거+단일 replica 고정) | 🟠 | k8s 패턴 | 소 |
| 6 | **A-5** 인증 결과 캐싱 | 🟠 | 성능/가용성 | 소 |
| 7 | **A-6/A-7** SSE 스레드풀 경계화 · exec 타임아웃 | 🟡 | 안정성 | 소~중 |
| 8 | **C-5** Kaniko activeDeadlineSeconds·resources — 🟢 activeDeadlineSeconds 완료(2026-06-11), **resources 잔여** | 🟡 | 안정성 | 소 |
| ~~8.5~~ | ~~**C-9** 빌드 CM 을 terminal phase 에서 삭제(수명 분리)~~ ✅ 완료(2026-06-11, 권장안 A) | 🟠 | 안정성/자원 | 소 |
| 9 | **A-8/A-9** actuator 노출 축소 · 업로드 쿼터 | 🟡 | 보안/안정성 | 소 |
| ~~10~~ | ~~**C-6** imageDigest 채우기~~ ✅ 완료(2026-06-11) | 🟡 | 기능완결 | 중 |
| 11 | **§2.3 / B-4** CR 계약 공유 모듈화 | 🟡 | 유지보수 | 중 |
| 12 | A-10/A-11/A-12/~~C-4~~/~~C-7~~/C-8/B-6/B-7 마무리 (C-4·C-7 ✅ 완료) | ⚪ | 개선 | 소 |
| **마지막** | **기본 인증/인가 일괄 정비: A-1, B-1, A-3, B-5, A-2** (selfsubjectreview 역할 구분은 현행 유지) | 🔴🟠 | 보안 | 중~대 |

---

## 5. 부록 — 주요 참조 위치

| 항목 | 파일 |
|------|------|
| Reconciler 상태머신 | `imagebuild-controller/.../reconciler/ImageBuildReconciler.java` |
| Kaniko Job 생성 | `imagebuild-controller/.../reconciler/KanikoJobFactory.java` |
| status patch | `imagebuild-controller/.../reconciler/ImageBuildStatusUpdater.java` |
| informer+workqueue 구성 | `.../config/InformerControllerConfiguration.java`, `.../reconciler/ControllerRunner.java` |
| CRD | `helm/imagebuild-controller/templates/crd.yaml` |
| 컨트롤러 RBAC/HPA | `helm/imagebuild-controller/templates/{clusterrole,hpa}.yaml` |
| 빌드 트리거/조회 | `dockerizer-backend-server/.../imagebuild/service/ImageBuildService.java` |
| 빌드 컨트롤러 | `.../imagebuild/controller/ImageBuildController.java` |
| Dockerfile 서비스/리비전 | `.../dockerfile/service/{DockerfileService,DockerfileRevisionService}.java` |
| 인가(Dockerfile) | `.../dockerfile/controller/DockerfileController.java` |
| 예외 매핑 | `.../common/exception/GlobalExceptionHandler.java` |
| 스키마/cascade | `sql/Dockerizer_1.0.0__initial_schema.sql` |
| OSIV/JPA 설정 | `dockerizer-backend-server/src/main/resources/application.yaml` |
