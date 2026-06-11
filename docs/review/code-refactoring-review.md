# Dockerizer 코드 리팩토링 리뷰 (프론트엔드 · 백엔드)

| | |
|---|---|
| 작성일 | 2026-06-11 |
| 대상 | `dockerizer-backend` (`099c84a`) · `dockerizer-web` (`e569ad0`) |
| 범위 | 유지보수성 관점의 **리팩토링 포인트** (코드 스멜·중복·관심사 분리·타입 안전성·테스트). 아키텍처 적정성/보안 인가는 [`backend-architecture-review.md`](backend-architecture-review.md) 참조 |
| 식별자 | `SRV-n` 백엔드 서버 · `CTL-n` ImageBuild 컨트롤러 · `WEB-n` 프론트엔드 |

> 심각도: **High** 유지보수/정확성에 실질적 해 · **Medium** 명확한 개선 · **Low** 사소/제안.
> `aipub`/`brewery` 및 `aipub.ten1010.io` 라벨 키는 외부 연동을 위해 **의도적으로 보존**되는 값이므로 리네임 대상이 아니다. 기본 인증/인가 정비는 [아키텍처 리뷰의 일정 결정](backend-architecture-review.md)대로 **후순위**이며 본 문서의 헤드라인이 아니다.

---

## 0. 요약

| 영역 | High | Medium | Low | 합계 |
|---|---|---|---|---|
| 백엔드 서버 (SRV) | 4 | 6 | 3 | 13 |
| ImageBuild 컨트롤러 (CTL) | 2 | 4 | 4 | 10 |
| 프론트엔드 (WEB) | 6 | 8 | 7 | 21 |

기능 동작 자체는 견고하다. 리팩토링 여지는 주로 **(1) 중복된 단일 진실원본의 부재**(라벨/상수/CR 모델/포맷 헬퍼가 모듈·페이지마다 재정의), **(2) 타입 안전성 우회**(`Map<String,Object>`+Gson 왕복, `unknown`/`as` 캐스트), **(3) 거대 컴포넌트/메서드**(에디터 페이지 1.9k 라인), **(4) 반쪽짜리 i18n 채택**, **(5) 핵심 로직(컨트롤러 reconcile·CR 매핑)의 테스트 공백**에 집중된다.

**가장 효과가 큰 통합 작업** — 백엔드의 `ImageBuildConstants`·CR 모델(`ImageBuildSpec`/`ImageBuildStatus`)·라벨 키·`K8sProperties` 를 **공유 Gradle 모듈**로 추출하면 SRV-1·SRV-2·SRV-3·SRV-6·CTL-4 의 상당 부분이 한 번에 해소된다(이미 drift 발생 — 컨트롤러의 `ImageBuildSpec` 에는 `imageLabels` 가 있으나 서버 쪽엔 없음). 프론트는 `src/lib/`(format·build-phase·dockerfile-content) + `<Pagination>`/`useTableSelection` 추출이 동급의 효과를 낸다.

---

## 1. 공통 횡단 테마

1. **단일 진실원본 부재** — `aipub.ten1010.io/*` 라벨·어노테이션 키가 백엔드 서버(`ImageBuildService`), 컨트롤러(`KanikoJobFactory`/`InformerControllerConfiguration`/`ImageBuildReconciler`), 프론트(`api/build.ts`)에서 **각자 private 리터럴로 3중 이상 재정의**된다. 컴파일 타임 검증이 없어 한쪽 오타/리네임이 조용히 상호 연동을 깬다.
2. **타입 안전성 우회** — 백엔드는 `Map<String,Object>` + `gson.toJson→fromJson` 왕복으로 CR 을 파싱하고, 프론트는 `cr: unknown` / `spec: { [key]:unknown }` / `as Record<string,string>` 로 CR 스펙을 사실상 무타입 처리한다.
3. **중복 헬퍼** — 백엔드: `ApiException→RuntimeException` 변환·`parseLong`·path 정규화. 프론트: 날짜/age/duration 포맷, 이미지명 단축, 페이지네이션/선택 로직, `(e as Error).message`.
4. **예외/오류 처리 비일관** — 백엔드는 404 만 도메인 예외로 매핑하고 나머지는 `RuntimeException("...: "+responseBody)` 로 던져 **원문 노출 + 일반 fallback 부재**. 프론트는 `k8s.ts` 가 `api-client.ts` 와 별개의 fetch/에러 래퍼를 중복 구현.
5. **테스트 공백** — 컨트롤러 모듈은 컨텍스트 로드 테스트 1개뿐, 서버의 CR 매핑(`crMapToResponse`/`parseStatus`/`parseSpec`)도 직접 테스트가 없다. 가장 회귀 위험이 큰 코드가 미검증.

---

## 2. 백엔드 서버 (`dockerizer-backend-server`)

### SRV-1 — `ImageBuildService` 의 무타입 Map + Gson 왕복 파싱 · **High**
`ImageBuildService.java` `listBuilds`/`getCrMap`(`@SuppressWarnings("unchecked")` 다수)이 `Object→Map<String,Object>`·`List<Map<String,Object>>` 로 캐스팅하고, `crMapToResponse` 가 `metadata/labels/annotations` 를 손으로 파헤친 뒤 `parseStatus`/`parseSpec` 이 `gson.fromJson(gson.toJson(obj), …)` 로 **이미 존재하는 타입 클래스로 재직렬화**한다.
**문제** — 호출마다 이중 직렬화, 흩어진 캐스트, 스키마 변경 시 여러 메서드의 문자열 키를 동시 수정해야 함.
**권장** — 컨트롤러의 `ImageBuildResource` 를 공유 모델로 승격해 `GenericKubernetesApi<ImageBuildResource,…>` 로 통째 역직렬화하거나, 최소한 `metadata/labels/annotations/spec/status` 접근을 단일 `CrMapAccessor` 헬퍼로 추출해 캐스트·Gson 왕복을 한 곳(+테스트)에 가둔다.

### SRV-2 — 라벨/어노테이션 상수 3중 정의 · **High**
`ImageBuildService.java` 가 `LABEL_DOCKERFILE_ID`/`LABEL_REVISION_ID`/`LABEL_USERNAME`/`ANNOTATION_BASE_IMAGE` 를 private 리터럴로 정의. 컨트롤러의 `KanikoJobFactory`·`InformerControllerConfiguration`·`ImageBuildReconciler` 가 `LABEL_MANAGED_BY`/`LABEL_IMAGEBUILD_NAME`/`MANAGER_NAME` 를 각자 재정의. 프론트(`api/build.ts`)도 동일 키를 직접 기록.
**문제** — 같은 키의 정의가 3곳 이상, 한쪽 변경이 list/status 상관(correlation)을 말없이 깨뜨림. `dockerizer-controller` manager 이름이 세 파일에 리터럴로 흩어짐.
**권장** — 모든 라벨/어노테이션 키 + `MANAGER_NAME` 를 (공유) `ImageBuildConstants` 로 이동. 두 모듈이 이미 이 클래스를 통째 중복하므로 공유 모듈 추출이 근본 해법(SRV-3 과 묶어 처리).

### SRV-3 — 모듈 간 CR 모델·상수 중복 (이미 drift 발생) · **High**
서버 `imagebuild/cr/ImageBuildConstants.java` 와 컨트롤러의 동명 클래스는 거의 동일(컨트롤러가 Kaniko/secret prefix 만 추가). `ImageBuildSpec`/`ImageBuildStatus` 도 중복인데 **서버 쪽 `ImageBuildSpec` 에는 컨트롤러에 있는 `imageLabels` 필드가 빠져 있다**. `K8sProperties` 는 두 모듈에서 바이트 단위로 동일.
**문제** — 와이어 계약(contract)의 진실원본이 둘이고, 이미 필드 누락 drift 가 일어남.
**권장** — `dockerizer-cr-model`(또는 `dockerizer-common`) Gradle 모듈을 분리해 CR 클래스·상수·`K8sProperties` 를 공유.

### SRV-4 — `GlobalExceptionHandler` 일반 fallback 부재 + 원문 노출 · **High**
`GlobalExceptionHandler` 가 `ResourceNotFound`/`Duplicate`/`DataIntegrity`/`Forbidden`/validation/`IllegalArgument` 는 처리하나 **`RuntimeException`/`Exception` catch-all 이 없다**. 그런데 k8s/proxy 실패 경로(`ImageBuildService`, `K8sAipubVolumeClient`, `ProxyAipubVolumeClient`, `VolumeBrowserService` 등)는 일제히 `RuntimeException("...: " + e.getResponseBody())` 를 던진다.
**문제** — 그 경로들이 **k8s API 원문을 body 에 노출한 채 500** 으로 표출되고, 나머지 `ProblemDetail` 스타일과 비일관.
**권장** — 클라이언트가 던지는 도메인 예외(`UpstreamServiceException`/`KubernetesOperationException`)를 도입해 `502/503 ProblemDetail` 로 매핑하고, `@ExceptionHandler(Exception.class)` 로 정제된 500(원문은 로깅만, body 미노출) 을 추가.

### SRV-5 — `ApiException→RuntimeException` 변환 로직 중복 · **Medium**
`if (e.getCode()==404) throw new ResourceNotFoundException(...); throw new RuntimeException("...: "+e.getResponseBody(), e);` 패턴이 `getCrMap`·`getBuildLogs`·`findBuildPodName`·`K8sAipubVolumeClient` 에 반복.
**권장** — `K8sExceptions.translate(ApiException, String context)` 정적 헬퍼로 404-vs-기타 매핑과 메시지 포맷을 일원화.

### SRV-6 — `findBuildPodName` 이 Job 이름·라벨을 직접 재유도 · **Medium**
`findBuildPodName` 에서 `name + "-job"`, `"job-name=" + jobName` 을 하드코딩. `-job` 접미사는 컨트롤러 `KanikoJobFactory` 의 명명 규약이고 `job-name` 은 k8s 내장 Job pod 라벨.
**문제** — 컨트롤러가 접미사/라벨링을 바꾸면 서버의 pod 조회가 조용히 빈 결과 → 잘못된 404/fallback. 컨트롤러는 이미 pod 에 `aipub.ten1010.io/imagebuild-name` 라벨을 달고 자기 `readImageDigest` 에서 그 셀렉터를 쓴다.
**권장** — 명명 헬퍼를 공유하고, 암묵적 `job-name` 대신 컨트롤러가 소유한 안정적 라벨(`imagebuild-name`)로 pod 를 선택.

### SRV-7 — `getBuildLogs` 가 분기를 예외로 처리 · **Medium**
`readNamespacedPodLog` 의 404 를 `ResourceNotFoundException` 으로 바꿔 던진 뒤 **같은 메서드의 바깥 try 에서 즉시 catch** 해 OpenSearch fallback 을 트리거. throw-then-catch-locally 흐름이 읽기 어렵다.
**권장** — `findBuildPodName` 을 `Optional` 반환으로 바꾸고 `pod 있음 → live 로그(404 → fallback) / 없음 → fallback` 의 선형 구조로 정리.

### SRV-8 — `logStreamExecutor` 무제한 cached pool · 미종료 · **Medium**
`Executors.newCachedThreadPool()` 은 상한이 없어 SSE 동시 접속 폭주 시 스레드 고갈 위험이 있고, `@PreDestroy` 종료가 없어 셧다운 시 스트림/스레드 누수 가능. 중첩 `catch (Exception ignored) { emitter.completeWithError(e); }` 도 의도가 모호.
**권장** — 상한이 있는 `ThreadPoolTaskExecutor` 빈(named threads + queue cap)으로 교체하고 `@PreDestroy` 종료 추가.

### SRV-9 — 레지스트리 파서의 무타입 Map · **Medium**
`NgcRegistryService`·`HuggingfaceRegistryService` 가 `Map<String,Object>` 로 받아 `results`/`tags`/`count` 를 unchecked 캐스트(SRV-1 과 동일 스멜). `encodeCredentials` 는 inline `java.util.Base64` + 기본 charset `getBytes()`.
**권장** — 레지스트리별 타입 record 로 Jackson 직접 바인딩, `StandardCharsets.UTF_8` 명시.

### SRV-10 — `VolumeBrowserService` 관심사 혼재 + `ls` 파싱 취약 · **Medium**
`parseLine` 이 `ls -lan` 출력을 공백 9칼럼으로 분해해 `parts[5..7]` 을 날짜로 읽음 → 공백 포함 파일명·로캘 날짜·심링크(`a -> b`) 에서 오파싱. 290여 라인이 exec 경로 조립·WebSocket 스트리밍·멀티파트·경로 검증을 모두 소유.
**권장** — `PodExec`(exec/websocket)·`LsOutputParser`(독립 테스트 가능)로 분리, 구분자 안전한 `stat`/`find -printf` 포맷 검토.

### SRV-11 — 경로 유틸·`parseLong` 중복 · **Low**
`VolumeBrowserService.parseLong` 가 `ImageBuildService.parseLong` 과 중복. `validatePath`(`..` 차단)와 `normalizePath`(슬래시 재부착)가 같은 경로를 두 함수로 추론.
**권장** — 공유 `PathUtils`/`SafePath` 값 객체, 단일 `parseLongOrNull`.

### SRV-12 — MCP actor 귀속 비일관 (관련 주석은 본 패스에서 수정) · **Low**
`McpServerConfiguration` 의 `updateDockerfile` 은 actor 를 `"mcp-tool"` 리터럴로 고정하는데 `createDockerfile` 은 `username` 파라미터를 받는다 — 귀속 방식 비일관. (※ `ImageBuildController` 의 "MCP triggerImageBuild 로 여전히 제공" 주석은 도구 제거와 어긋났던 것을 본 리뷰 패스에서 바로잡음.)
**권장** — MCP actor 귀속 방식을 통일.

### SRV-13 — `AipubAuthenticationFilter` 광범위 catch (인가 후순위 — 참고만) · **Low**
`catch (Exception)` 후 로깅만 → AIPub 일시 장애와 잘못된 쿠키가 구분 안 됨(둘 다 미인증 continue). 인가 정비 시 함께 재검토할 알려진 스멜로만 기록.

---

## 3. ImageBuild 컨트롤러 (`imagebuild-controller`)

### CTL-1 — `configMapExists`/`jobExists` 가 모든 `ApiException` 을 `false` 로 삼킴 · **High** (아키텍처 리뷰의 C-8)
`ImageBuildReconciler` 의 존재 검사가 500/timeout/403 을 깨끗한 404 와 동일하게 "없음" 으로 결론 → create 시도. create 는 409 catch 로 멱등성을 유지하지만, **비-404 read 오류에 이어 비-409 create 오류가 나면 일시적 API 장애로도 빌드를 `markFailed`** 할 수 있다.
**권장** — 404(→false)와 기타 코드(→rethrow, `reconcile` 의 `catch(RuntimeException)` 가 requeue)를 구분. 더 낫게는 사전 검사를 제거하고 create + 409-already-exists 에만 의존(이미 409 처리됨)해 read 왕복과 삼킴을 함께 제거.

### CTL-2 — `handleBuilding` 의 비-404 오류가 requeue 없이 no-op · **Medium**
Job 읽기에서 비-404 `ApiException` 시 로깅 후 `Result(false)`(요청 미재시도). resync 로 자가 치유되나, 종료 감지 구간의 일시 read 실패엔 `Result(true)` requeue 가 더 정확.
**권장** — 비-404 를 rethrow(바깥 catch 가 requeue) 하거나 명시적 requeue 결과 반환.

### CTL-3 — `KanikoJobFactory` 의 장황한 명령형 빌더 · **Medium**
`kanikoContainer` 가 `hasBuildContext` true/false 분기를 교차로 엮어 각자 `--dockerfile`/`--context` + 마운트를 추가한 뒤 공통 args/mounts 를 붙임 → 두 분기가 dockerfile 마운트 구성을 중복. `createKanikoJob` 은 깊게 중첩된 단일 표현식.
**권장** — `buildArgs(cr, hasContext)`·`buildMounts(cr, hasContext)`·`labelArgs(imageLabels)` 로 추출(현재 미검증인 args 생성을 단위 테스트 가능하게).

### CTL-4 — 팩토리 전반의 매직 문자열 · **Medium/Low**
apiVersion/kind/policy 리터럴(`"v1"`,`"ConfigMap"`,`"batch/v1"`,`"Job"`,`"Never"`,`"File"`), 마운트 경로(`/kaniko-config`,`/build-context`,`/workspace`,`/kaniko/.docker`), configmap 키 `"Dockerfile"`, `-job`/`-dockerfile` 접미사가 raw 문자열로 산재.
**권장** — 마운트 경로·kind/apiVersion 리터럴을 named 상수로 승격(SRV-2/3 공유 모듈과 연계).

### CTL-5 — `ImageBuildStatusUpdater.patchStatus` 의 Gson 왕복 + 실패 삼킴 · **Medium**
`Map.of("status", gson.fromJson(gson.toJson(status), Map.class))` 로 status→JSON→Map→JSON(SRV-1 과 동일 이중 직렬화). `ApiException` 시 로깅만 하고 반환 → 호출부(`reconcile`)는 전환 성공으로 오인, CR 은 이전 phase 에 머물러 resync 때만 재시도(조용한 실패). merge-patch 라 필드 클리어 불가(`startTime` 보존이 우연히 동작).
**권장** — 타입 status 를 직접 patch 로 직렬화(Map 우회 제거), patch 실패 시 throw 해 requeue 유도, merge-patch 필드 보존 가정을 문서화.

### CTL-6 — `transitionTo` 의 도달 불가 terminal 처리 · **Low**
`transitionTo` 가 terminal phase 의 `completionTime` 분기를 갖지만 실제 종료는 전용 `markSucceeded`/`markFailed` 로만 구동되어 해당 분기는 사실상 dead.
**권장** — `markSucceeded`/`markFailed` 가 단일 private `applyStatus` 에 위임하게 하고 `transitionTo` 의 unreachable terminal 처리 제거.

### CTL-7 — 컨트롤러 모듈 테스트 거의 없음 · **High**
`src/test` 에 컨텍스트 로드 테스트 1개뿐. `ImageBuildReconciler`(phase 상태머신·409 멱등·digest 추출·timeout 메시지 분기), `KanikoJobFactory`(args/mount/volume 조립·subPath·라벨 정렬), `ImageBuildStatusUpdater`, `enqueueOwner` 모두 **무테스트** — 가장 로직 밀도가 높고 회귀 위험이 큰 코드.
**권장** — Mockito 로 `CoreV1Api`/`BatchV1Api`/`CustomObjectsApi` 모킹해 reconcile 전환 테스트, `KanikoJobFactory`·`extractFailureMessage`·`resolveBuildTimeoutSeconds` 는 k8s 불필요한 순수 단위 테스트.

### CTL-8 — 서버 CR 매핑 경로도 무테스트 · **Medium**
`ImageBuildControllerDocsTest` 는 service 를 모킹한 REST-docs 테스트라 `crMapToResponse`/`parseStatus`/`parseSpec`/`parseInstant`/`parseLong`(가장 위험한 로직)에 직접 테스트가 없다.
**권장** — status 누락·null 타임스탬프·잘못된 라벨 숫자 등 대표 CR `Map` 픽스처를 `crMapToResponse` 에 흘려보내는 단위 테스트 추가.

### CTL-9 — `EventRecorder` 의 core/v1 · events.k8s.io 관례 혼용 · **Low**
`eventTime` 와 legacy `firstTimestamp`/`lastTimestamp`, `source.component` 와 신규 `reportingComponent` 를 동시 설정 → 동작은 하나 중복.
**권장** — modern(`eventTime`+`reportingController`) 또는 legacy 한쪽으로 통일.

### CTL-10 — boxed `Integer`/`Boolean` 프로퍼티 언박싱 NPE 표면 · **Low**
`ControllerProperties` 가 모두 boxed + 기본값인데 언박싱 사용(`resyncPeriodSeconds * 1000L` 등). YAML 에서 빈 값을 주면 null → 시작 시 NPE.
**권장** — primitive `int`/`boolean` 필드 + 기본값(Spring 바인딩 정상)으로 언박싱 NPE 표면 제거.

---

## 4. 프론트엔드 (`dockerizer-web`)

### WEB-1 — `DockerfileEditorPage.tsx` 1,891줄 god-component · **High**
순수 헬퍼(`parseDockerfileContent`/`generateDockerfileContent`/`buildLabelLines`/`parseLabelInstruction`)부터 `~20 useState + 7 useEffect`, 폼 제출, 빌드/저장 다이얼로그, 이미지 셀렉터 와이어링, 두 개의 큰 중첩 JSX 다이얼로그까지 한 파일이 소유. 단위 테스트 불가 + 최고 churn 위험.
**권장** — 순수 함수는 `src/lib/dockerfile-content.ts` 로(React 무관, 테스트 가능), `<BuildDialog>`/`<SaveRevisionDialog>`/`<LabelEditor>` 컴포넌트 추출, 폼/콘텐츠 동기화·dirty 추적은 `useDockerfileEditorState` 훅으로. 목표: 페이지 < 300줄 오케스트레이션.

### WEB-2 — `handleBuild` 내 빌드 옵션 조립·다이얼로그 정리 로직 3중 중복 · **High**
`runBuildMutation.mutate(..., {onSuccess, onError})` + 동일한 `setShowBuildDialog(false); setBuildAfterCreate(false); navigate(...)` 정리가 EDIT/CREATE-성공/CREATE-실패 3경로에 반복. "COPY 볼륨 자동 감지" 블록도 두 빌드 버튼에 동일 복붙.
**권장** — 이미 존재하는 `startBuild(df)` 클로저로 EDIT·CREATE-성공 경로를 모두 라우팅, 볼륨 자동 감지를 `resolveBuildContextVolume()` 로 추출, 다이얼로그 정리/네비게이션을 mutation `onSuccess` 또는 단일 `finishBuild` 로 이동.

### WEB-3 — `phaseConfig` 가 형태가 다른 채 두 번 정의 + phase 순서 하드코딩 · **High**
`BuildDetailPage`(`{label,variant,icon}`)와 `BuildListPage`(`{label,color,dotClass}`)가 phase→라벨/색을 각자 정의, 한국어 라벨도 양쪽 하드코딩. phase 순서 배열·`buildSteps` 도 인라인.
**권장** — `src/lib/build-phase.ts`(또는 `usePhaseMeta`)에 단일 `BUILD_PHASES` 순서 + `phaseMeta` record(라벨은 `t()`)를 두고 두 페이지가 공유.

### WEB-4 — 죽은/잘못된 i18n `build.phase.*` 키 · **High**
locale 의 `build.phase` 블록이 `Pending/Running/Succeeded/Failed` 인데 `BuildPhase` 는 `Pending|Preparing|Building|Succeeded|Failed` — **`Running` 은 없고 `Preparing`/`Building` 누락**, 게다가 `t('build.phase'` 사용처 0. phase 라벨은 대신 컴포넌트에 하드코딩(WEB-3).
**권장** — `build.phase` 블록을 삭제하거나(권장: WEB-3 과 함께) 실제 `BuildPhase` union 에 맞춰 정렬해 정식 라벨 소스로 삼는다.

### WEB-5 — i18n 을 우회하는 한국어 하드코딩 만연 · **High**
대표 예: 에디터(`'기본 설정'`,`'베이스 이미지'`,`'생성 후 빌드'`,`'변경 사항 저장'`, 빌드 다이얼로그 본문, `InstructionBlock` 문자열), `BuildDetailPage`(`'빌드 상세'`,`'빌드 단계'`,`'빌드 정보'`, 스텝/phase 라벨, `'목록으로'`), 리스트 페이지(`'모든 프로젝트'`,`'빌드 기록이 없습니다'`), `ImageSelector`(`'Base Image 선택'`,`'준비 중'` 등).
**문제** — 반쪽 i18n 은 미적용보다 나쁘다 — `en` 사용자가 `t()` 영어와 하드코딩 한국어를 섞어 보게 됨. locale 은 ~30키뿐인데 수백 문자열이 인라인.
**권장** — 위 페이지 우선으로 사용자 노출 문자열을 `editor.*`/`build.*`/`common.*` 네임스페이스로 스윕. 반복 리터럴(`'모든 프로젝트'`, "of N pages", "Rows per page")은 공유 키화.

### WEB-6 — `api/k8s.ts` 가 `apiClient` 대신 fetch/에러 래퍼를 재구현 · **High**
`k8sRequest` 가 `api-client.ts` 의 `request`(credentials/JSON 헤더/401→`/welcome`/`!ok` throw)를 통째 중복. `k8sApi` 는 volume/registry 호출엔 `apiClient` 를 쓰면서 CR 호출만 자체 래퍼 사용.
**문제** — HTTP 계층 이원화. `k8sRequest` 는 `K8s API error: <status>` 만 던지고 RFC-7807 `detail` 무시 → CR 생성 오류는 불투명 코드로, 백엔드 오류는 가독 메시지로 표출되는 비일관. 401 리다이렉트도 3곳 복붙.
**권장** — `apiClient` 에 base path 옵션(또는 동일 `request` 기반 `k8sClient`)을 추가해 401 리다이렉트·에러 추출을 일원화하고 `k8sRequest` 제거.

### WEB-7 — 날짜/age/duration/이미지명 헬퍼 중복 · **Medium**
`formatDateTime`(3곳, 2개 동일), `formatCreatedAt`, `formatAge`, `formatDuration`, `shortenImageName`/`shortenImage`(미묘하게 `>2` vs `>=3` 불일치)가 페이지마다 복붙.
**권장** — `src/lib/format.ts`(`formatDateTime`/`formatRelativeAge`/`formatDuration`/`shortenImageRef`)로 통합하고 `>2`/`>=3` 동작 차이 정리.

### WEB-8 — `PageBtn` + 페이지네이션 블록 + 선택 로직 중복 · **Medium**
`PageBtn` 이 `BuildListPage`/`DockerfileListPage` 에 동일, 주변 페이지네이션 JSX(rows-per-page Select, "of N pages", 4 버튼)도 중복. `toggleAll`/`toggleOne`/`buildKey` 선택 Set 로직도 양쪽 거의 동일.
**권장** — `<Pagination>` 컴포넌트 + `useTableSelection<T>` 훅 추출(두 페이지는 이미 `useTableSort`/`SortableHead`/`Table` 공유).

### WEB-9 — CR 처리의 타입 안전성 공백 · **Medium**
`createImageBuild(namespace, cr: unknown)`, `ImageBuildCr.spec: { targetImage; [key]:unknown }`, `src.spec.imageLabels as Record<string,string>` 캐스트, `InstructionBlock` 의 `volumes?: unknown`(선언만 되고 미사용).
**권장** — 제대로 된 `ImageBuildSpec` 인터페이스(`dockerfileContent`/`targetImage`/`imageLabels?`/`pushSecretRef?`/`buildContextPvc?`/`buildContextSubPath?`/`buildTimeoutSeconds?`)와 생성용 `ImageBuildCrInput` 타입 정의 → `createImageBuild(cr: ImageBuildCrInput)`. 미사용 `volumes` prop 제거 또는 실제 사용.

### WEB-10 — `run`/`rebuild` 의 CR 조립 중복 · **Medium**
두 함수가 동일 `{apiVersion, kind, metadata:{generateName:'imagebuild-', namespace, labels, annotations}, spec}` 골격을 각자 조립.
**권장** — `makeImageBuildCr({namespace, labels, annotations, spec})` 헬퍼 추출(둘은 라벨 셋·spec 출처만 다름).

### WEB-11 — 폴링·timeout 경계의 매직 넘버 · **Medium**
`useBuilds.ts` 의 `3000`/`5000`, 타임아웃 clamp `Math.min(360, Math.max(1, …||60))`·`*60` 이 input 의 `min={1} max={360}` 와 따로 존재, `useK8s.ts` 의 `5*60*1000` staleTime 중복.
**권장** — `BUILD_POLL_MS`/`LOG_POLL_MS`/`DEFAULT_STALE_MS`/`BUILD_TIMEOUT_{MIN,MAX,DEFAULT}_MINUTES` named 상수로 input·clamp 공유.

### WEB-12 — 쿼리 키 형태 비일관 · **Medium**
`[KEY,{project}]` vs `[KEY,namespace,name]`(위치형) vs `[...,'logs']` 혼재. `useRunBuild` 의 `invalidateQueries({queryKey:[KEY]})` 가 두 형태 prefix 매칭에 의존.
**권장** — TanStack 관례의 쿼리 키 팩토리(`buildKeys.list(project)`/`detail(ns,name)`/`logs(ns,name)`) 채택.

### WEB-13 — mutation 오류 처리 비일관 · **Medium**
create/update mutation 엔 `onError` 토스트가 있으나 **EDIT 경로의 `runBuildMutation` 엔 `onError` 없음** → 실패가 조용히 무시(토스트 없음, 다이얼로그 유지). `useRebuild` 도 오류 표면 없음 → `BuildDetailPage` 는 `onSuccess` 만 전달해 재빌드 실패가 비가시.
**권장** — QueryClient 기본 `onError` 또는 `useMutationToast` 래퍼로 표준화. 최소한 EDIT `startBuild` 와 rebuild 호출에 `onError` 추가.

### WEB-14 — `(e as Error).message` 캐스트 반복 · **Medium**
`(e as Error).message` 가 에디터 토스트 4곳, `api-client.ts` 는 무타입 `any` 에서 `message`/`detail` 을 읽음.
**권장** — `getErrorMessage(e: unknown): string` 유틸로 통일, ProblemDetail 형태를 타입화.

### WEB-15 — form↔editor 전환 시 미지원 지시자 소실 · **Low**
`switchToForm` 이 재파싱·재생성하며 ENTRYPOINT/ARG/multistage 를 드롭(주석에 문서화됨). 의도적이나 데이터 소실 footgun — 전환 시 경고 가드 검토.

### WEB-16 — `instrTypeOptions` 라벨/설명/아이콘 한국어 하드코딩 · **Low**
WEB-5 의 i18n 공백이 표시 문자열을 config 배열에 결합. i18n 으로 접기.

### WEB-17 — `getStepStatus` 가 매 호출 phase 배열 재할당 · **Low**
`['Pending','Preparing','Building','Push']` 를 함수 내부에서 step·render 마다 할당. 모듈 상수로 호이스트(WEB-3 연계).

### WEB-18 — `BuildDetailPage` 의 날짜 포맷만 `toLocaleString('ko-KR')` · **Low**
다른 두 페이지의 수동 패딩 방식과 같은 개념(생성 시각)에 다른 포맷. `lib/format.ts`(WEB-7)로 통일.

### WEB-19 — `ImageSelector` catalog 탭 placeholder + 죽은 NGC/HF 코드 · **Low**
`RegistryTab='catalog'` 가 영구 "준비 중" placeholder. 대응하는 `useNgc*`/`useHuggingface*` 훅과 `k8s.ts` 레지스트리 메서드가 **어느 컴포넌트에서도 import 되지 않는 dead code** 로 보임 — 확인 후 catalog 가 보류면 제거.

### WEB-20 — env 읽기 중복 · **Low**
`VITE_HARBOR_URL` 이 에디터·`ImageSelector` 양쪽, `API_BASE_URL` 유도가 `k8s.ts`·`api-client.ts`·`useBuilds.ts` 에 반복.
**권장** — `src/lib/env.ts` 단일 모듈에서 타입화된 config 상수 export.

### WEB-21 — `nextInstrId` 모듈 레벨 가변 카운터 · **Low**
모듈 수명 동안 단조 증가하는 공유 가변 상태. `useRef`/`crypto.randomUUID()` 가 더 깔끔.

---

## 5. 권장 진행 순서

**1순위 (High · 구조적)**
- 백엔드 **공유 모듈 추출** — `ImageBuildConstants`·CR 모델·라벨 키·`K8sProperties` (SRV-1·SRV-2·SRV-3·SRV-6·CTL-4 동시 해소, drift 차단).
- `GlobalExceptionHandler` catch-all + 원문 미노출 (SRV-4).
- 컨트롤러/CR 매핑 **테스트 도입** (CTL-7·CTL-8).
- 존재 검사 404 구분 (CTL-1).
- 프론트 **`lib/` 추출** — `format.ts`·`build-phase.ts`·`dockerfile-content.ts` + 에디터 god-component 분해 (WEB-1·WEB-3·WEB-4·WEB-7).
- 프론트 HTTP 계층 통합 — `k8sRequest` 제거 (WEB-6).

**2순위 (Medium)**
- 백엔드: 예외 변환 헬퍼(SRV-5), `getBuildLogs` 선형화(SRV-7), SSE 풀 상한(SRV-8), 레지스트리 타입화(SRV-9), `VolumeBrowserService` 분리(SRV-10), 컨트롤러 status patch 직렬화/실패 전파(CTL-5), Kaniko 팩토리 추출(CTL-3·CTL-2).
- 프론트: 빌드 옵션/다이얼로그 정리 통합(WEB-2), `<Pagination>`/`useTableSelection`(WEB-8), CR 타입화(WEB-9·WEB-10), 매직 상수(WEB-11), 쿼리 키 팩토리(WEB-12), mutation 오류 표준화(WEB-13·WEB-14).

**3순위 (Low)**
- 백엔드: path 유틸/`parseLong` 통합(SRV-11), MCP actor 귀속(SRV-12), `transitionTo` 정리(CTL-6), `EventRecorder` 관례 통일(CTL-9), primitive 프로퍼티(CTL-10).
- 프론트: i18n 잔여 스윕(WEB-16), 상수 호이스트/포맷 통일(WEB-17·WEB-18), dead code 제거(WEB-19), env 모듈(WEB-20), id 카운터(WEB-21), form 전환 가드(WEB-15).

> 인가/인증(SRV-13 및 아키텍처 리뷰 A·B 시리즈)은 기존 일정 결정에 따라 베타 기능 완료 후 횡단 관심사로 일괄 진행한다.
