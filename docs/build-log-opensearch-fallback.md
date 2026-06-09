# 빌드 로그 영구 조회 — OpenSearch fallback (작업 인계 문서)

> 작성일: 2026-06-05
> 상태: **구현 완료** (2026-06-09) — opensearch-java `3.0.0` 핀, `compileJava` 통과, 프론트 안내 문구 포함
> 관련: [volume-build-context.html](volume-build-context.html), 메모리 `project-monitoring-logging-stack`

> ## ✅ 구현 완료 요약 (2026-06-09)
> - **백엔드**(`dockerizer-backend`): `OpenSearchProperties`/`OpenSearchConfiguration`/`OpenSearchBuildLogClient`(신규) + `ImageBuildService.getBuildLogs` 에 `ObjectProvider<OpenSearchBuildLogClient>` fallback. **0건이면 `ResourceNotFoundException`→404** 계약. dev/prod yaml, Helm(values/env-configmap/env-secret), install.sh(시크릿 복제 + `--set`/`--set-json` CA 마운트) 반영. opensearch-java **3.0.0**(httpclient5 5.5.x via Spring Boot 4 BOM). `compileJava` BUILD SUCCESSFUL, `helm template` 정상.
> - **프론트**(`dockerizer-web`): `BuildDetailPage` 로그 박스 3-state(404 → "로그를 확인할 수 없습니다") + `useBuildLogs` 가 404 시 폴링 중단. i18n `build.logUnavailable`(ko/en). `npm run build` 통과.
> - **핵심 계약**: `GET /logs` 는 Pod OR OpenSearch 에 로그 있으면 200(text), 둘 다 없으면(Pod GC + (OS 비활성 OR 0건)) **404 `ProblemDetail`**. 프론트는 이 404 를 react-query `error` 로 탐지(응답 body 파싱 의존 X).
> - **Helm 볼륨 결정**: 기본 values 엔 OpenSearch CA 볼륨 미포함(시크릿 부재 시 Pod 기동 실패 방지). install.sh 가 `OPENSEARCH_ENABLED=true` 일 때만 `--set-json` 으로 `opensearch-certs`→`/opensearch-certs` 마운트 주입.
> - **미반영(차기)**: SSE streamBuildLogs fallback, PIT+search_after 전체 페이지네이션(>maxLines), initContainer 로그(`container_name=kaniko` 필터), 배포 후 E2E 검증.

이 문서는 "빌드 완료 후 로그가 사라지는 문제"를 OpenSearch로 해결하는 작업의 **모든 조사 결과 + 구현 TODO**를 담는다. 다음 세션에서 재조사 없이 바로 구현에 들어갈 수 있도록 작성했다.

---

## 1. 문제 (왜 하는가)

현재 빌드 로그는 **살아있는 k8s 빌드 Pod의 stdout**을 백엔드가 직접 읽어 보여준다. 별도 저장 없음.

- 경로: 프론트 `BuildDetailPage` → (active면 SSE `/logs/stream`, 완료면 폴링 `/logs`) → 백엔드 `ImageBuildService.getBuildLogs/streamBuildLogs` → `findBuildPodName`(라벨 `job-name={crName}-job`로 Pod 검색) → `coreV1Api.readNamespacedPodLog` / `PodLogs.streamNamespacedPodLog`.
- **한계**: Kaniko Job 에 `ttlSecondsAfterFinished(3600)` (`imagebuild-controller/.../KanikoJobFactory.java`) 가 걸려 **빌드 완료 1시간 뒤 Pod 가 GC** → `findBuildPodName` 빈 결과 → **404 "Build pod not found"**. 즉 완료 1시간 지난 빌드는 로그 영구 소실. CR status 에도 로그는 저장 안 함(`phase/message/imageDigest`만).

## 2. 핵심 발견 — 로그는 이미 OpenSearch 에 적재되고 있다

클러스터 로깅 스택 = **Fluent Bit(DaemonSet) → OpenSearch → OpenSearch Dashboards** (ns `aipub-monitoring`). **전 네임스페이스 로그 수집 확인됨.** Kaniko Pod stdout 도 적재됨 → Pod GC 후에도 OpenSearch 에 잔존.

→ **새 로그 저장소를 만들 필요 없음.** 백엔드가 "Pod 없으면 OpenSearch 질의" fallback 만 붙이면 됨. **프론트·SSE 변경 불필요** (완료 빌드는 정적 `/logs` 폴링을 타므로 `getBuildLogs` 한 메서드만 고치면 커버됨).

## 3. 확정된 사실 (실측 완료)

| 항목 | 값 |
|---|---|
| OpenSearch 엔드포인트 | `https://opensearch-cluster-master.aipub-monitoring:9200` (svc, ClusterIP, https/self-signed) |
| **OpenSearch 버전** | **3.6.0** → 클라이언트는 `opensearch-java` **3.x** 사용 |
| 인덱스 | 일자별 `kube-log-YYYY.MM.DD` → 패턴 **`kube-log-*`** |
| 로그 텍스트 필드 | **`log`** (ANSI 컬러코드 포함, stdout/stderr 구분은 `stream`) |
| 식별 필드 | `kubernetes.namespace_name`, `kubernetes.pod_name`, `kubernetes.container_name`(=`kaniko`) |
| **필드 매핑** | **전부 `type: text`, `.keyword` 서브필드 없음, 라벨(`kubernetes.labels`) 미색인** |
| 정렬 키 | `@timestamp` (date, UTC) |
| 보존기간(ISM) | **180일** (`delete-180d-policy`, `kube-log-*`/`kube-event-*`, `min_index_age:180d`) — 기존 인덱스엔 미부착(`policy_id` `{}`)이나 신규 인덱스엔 ism_template 자동 부착. 읽기엔 충분. |

### 쿼리 설계 (매핑이 text-only 라서 term/prefix 못 씀)

`.keyword` 가 없으므로 `term`/`prefix` 대신 **`match` + `match_phrase_prefix`** 사용:

```
bool.filter[
  match(kubernetes.namespace_name = <ns>),
  match_phrase_prefix(kubernetes.pod_name = "<crName>-job"),   # 토큰 [imagebuild,<hex>,job] 연속 매칭 → 유일 빌드 선택
  match(kubernetes.container_name = "kaniko")                  # initContainer 로그까지 원하면 제거
]
sort: [{ "@timestamp": "asc" }]
```
- pod 이름은 `{crName}-job-{random}` → `(namespace, crName)` 만으로 도출 가능(Pod 이름 저장 불필요).
- CR id(`imagebuild-<8hex>`)가 전역 유일이라 phrase_prefix 로 정밀 선택됨.

## 4. 시크릿 (모두 ns `aipub-monitoring`, **교차 ns 마운트 불가** → install.sh 가 backend ns 로 복제)

| 시크릿 | 용도 | 키 |
|---|---|---|
| `opensearch-cluster-master-credentials` | basic auth | `username`(=admin), `password` |
| `opensearch-cluster-master-certs` (type tls) | TLS CA | `ca.crt`(+tls.crt/key) — **ca.crt 만 필요** |

> ⚠️ 비밀번호 평문은 이 문서에 적지 않음. install.sh 가 런타임에 위 시크릿에서 읽어 주입.

## 5. 의존성 (확정: B안 = 공식 opensearch-java)

`gradle.properties`:
```
opensearchJavaVersion=3.0.0   # OpenSearch 3.6 호환되는 3.x. Maven Central 최신 3.x 로 핀(빌드 시 확인)
```
`dockerizer-backend-server/build.gradle`:
```gradle
implementation "org.opensearch.client:opensearch-java:$opensearchJavaVersion"
implementation 'org.apache.httpcomponents.client5:httpclient5'   // 버전은 Spring Boot 4 BOM 관리
```
주의: opensearch-java 3.x 의 `ApacheHttpClient5TransportBuilder` + 비동기 HttpClient5 의 **TLS/credentials 와이어링이 까다로움**. 오프라인 컴파일 검증 불가하니, 작성 후 반드시 `./gradlew :dockerizer-backend-server:compileJava` (네트워크 필요) 로 확인할 것.

## 6. 설정 주입 패턴 (기존과 동일하게)

- `applicationYaml.dockerizer.opensearch.*` → `env-configmap.yaml`(비밀 아님) + `env-secret.yaml`(password) 로 매핑 (Spring relaxed binding: `DOCKERIZER_OPENSEARCH_URL` → `dockerizer.opensearch.url`).
- CA: 기존 `custom-ca-certs`→`/certificates` 마운트 선례 존재(values.yaml `volumes`/`volumeMounts`). OpenSearch CA 는 별도 시크릿(`dockerizer-backend-opensearch-certs`)으로 만들어 `/opensearch-certs/ca.crt` 에 마운트.
- 키 설계:
  - configmap: `DOCKERIZER_OPENSEARCH_ENABLED`, `_URL`, `_INDEX_PATTERN`, `_VERIFY_SSL`, `_CA_CERT_PATH`, `_USERNAME`
  - secret: `DOCKERIZER_OPENSEARCH_PASSWORD`

---

## 7. 구현 TODO (파일별 체크리스트)

### 백엔드 코드 (`dockerizer-backend/dockerizer-backend-server`)
- [ ] `gradle.properties` — `opensearchJavaVersion` 추가
- [ ] `build.gradle` — opensearch-java + httpclient5 의존성 추가
- [ ] `common/config/OpenSearchProperties.java` — `@ConfigurationProperties("dockerizer.opensearch")`, `@Component` (K8sProperties 와 동일 방식). 필드: `enabled(기본 false)`, `url`, `username`, `password`, `indexPattern("kube-log-*")`, `verifySsl(true)`, `caCertPath`, `maxLines(10000)`
- [ ] `common/config/OpenSearchConfiguration.java` — `@Bean OpenSearchClient`, `@ConditionalOnProperty("dockerizer.opensearch.enabled", havingValue="true")`. ApacheHttpClient5Transport + BasicCredentialsProvider(user/pass) + SSLContext(caCertPath 의 ca.crt 신뢰; verifySsl=false 면 trust-all) + `JacksonJsonpMapper`. HttpHost("https", host, 9200).
- [ ] `imagebuild/service/OpenSearchBuildLogClient.java` — `String fetchPodLogs(String namespace, String crName)`. §3 쿼리로 `client.search(..., LogDoc.class)`, size=maxLines, `@timestamp asc`, `hits[].source.log` 를 `\n` join. `record LogDoc(String log)`. total>maxLines 면 끝에 "... (truncated, OpenSearch)" 표기 + `// TODO PIT+search_after 로 전체 페이지네이션`.
- [ ] `imagebuild/service/ImageBuildService.java` — `getBuildLogs` 에 fallback:
  ```java
  try {
      String podName = findBuildPodName(ns, name);     // 살아있는 Pod
      return coreV1Api.readNamespacedPodLog(podName, ns).execute();
  } catch (ResourceNotFoundException e) {                // Pod GC됨
      // opensearch 비활성/null 이면 기존 404 그대로 던지기
      return openSearchBuildLogClient.fetchPodLogs(ns, name);
  }
  ```
  - 클라이언트는 비활성일 수 있으니 `ObjectProvider<OpenSearchBuildLogClient>` 로 주입 → 없으면 기존 404 유지.
  - (선택) `streamBuildLogs` 도 Pod 없으면 OpenSearch 결과를 한 번에 흘려보내고 done — 단 완료 빌드는 프론트가 폴링을 타므로 필수는 아님.
- [ ] `application.yaml`(dev) — `dockerizer.opensearch.enabled: false` (로컬은 비활성)
- [ ] `application-prod.yaml` — `dockerizer.opensearch` 블록 env 플레이스홀더(`${DOCKERIZER_OPENSEARCH_...}`)

### Helm (`dockerizer-backend/helm/dockerizer-backend`)
- [ ] `values.yaml` — `applicationYaml.dockerizer.opensearch` 블록(enabled/url/indexPattern/verifySsl/caCertPath/username/password) + `volumes`/`volumeMounts` 에 `dockerizer-backend-opensearch-certs`→`/opensearch-certs` 추가
- [ ] `templates/env-configmap.yaml` — opensearch enabled/url/indexPattern/verifySsl/caCertPath/username 키 추가
- [ ] `templates/env-secret.yaml` — `DOCKERIZER_OPENSEARCH_PASSWORD` 추가
- [ ] (deployment.yaml 은 volumes/volumeMounts 를 values 에서 toYaml 하므로 수정 불필요)

### install.sh (`dockerizer-backend/scripts/install.sh`)
- [ ] "Retrieving secrets" 단계에 추가:
  - `OPENSEARCH_USERNAME`/`OPENSEARCH_PASSWORD` = `kubectl get secret -n aipub-monitoring opensearch-cluster-master-credentials` 에서 디코드
  - `opensearch-cluster-master-certs` 의 `ca.crt` 디코드 → backend ns 에 `dockerizer-backend-opensearch-certs` 시크릿 생성:
    ```bash
    kubectl get secret -n aipub-monitoring opensearch-cluster-master-certs \
      -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/os-ca.crt
    kubectl create secret generic dockerizer-backend-opensearch-certs -n ${NAMESPACE} \
      --from-file=ca.crt=/tmp/os-ca.crt --dry-run=client -o yaml | kubectl apply -f -
    ```
  - (모니터링 ns/시크릿 이름은 config.json 으로 빼는 것도 고려)
- [ ] `deploy_helm_chart "dockerizer-backend"` 의 `--set` 에 추가:
  ```
  --set applicationYaml.dockerizer.opensearch.enabled=true
  --set applicationYaml.dockerizer.opensearch.url=https://opensearch-cluster-master.aipub-monitoring:9200
  --set applicationYaml.dockerizer.opensearch.username="${OPENSEARCH_USERNAME}"
  --set applicationYaml.dockerizer.opensearch.password="${OPENSEARCH_PASSWORD}"
  --set applicationYaml.dockerizer.opensearch.caCertPath=/opensearch-certs/ca.crt
  ```

### 검증
- [ ] `./gradlew :dockerizer-backend-server:compileJava` (opensearch-java/httpclient5 다운로드 위해 네트워크 필요) — **transport/TLS 와이어링 컴파일 확인 필수**
- [ ] 배포 후: 1시간 지나 Pod GC 된 빌드의 `/builds/{ns}/{name}/logs` 가 OpenSearch 에서 로그를 반환하는지 E2E 확인
- [ ] 권한: 다른 프로젝트 빌드 로그가 새지 않는지(백엔드 권한 체크가 namespace 기준으로 동작하는지) 확인

---

## 8. 남은 판단 포인트 / 주의

- **opensearch-java 3.x 정확 버전**: Maven Central 에서 OpenSearch 3.6 과 맞는 최신 3.x 확인 후 핀. (3.0.0 가정)
- **TLS**: CA 신뢰 방식(권장) vs trust-all(`verifySsl=false`). CA 시크릿이 있으니 CA 신뢰로 가는 게 맞음.
- **10,000줄 상한**: v1 은 단순 `_search` size=10000. 긴 로그는 PIT+`search_after`(`["@timestamp","_shard_doc"]`) 로 확장 (B안 선택 이유). truncation 표기 잊지 말 것.
- **ANSI 코드**: 살아있는 Pod 로그도 ANSI 포함·프론트 미가공 → fallback 도 그대로 두어 일관성 유지.
- **다중 볼륨(initContainer) 작업과의 관계**: 추후 initContainer 조립([multi-volume-build-context.md](multi-volume-build-context.md)) 도입 시, `container_name=kaniko` 필터 때문에 initContainer 로그가 안 보일 수 있음 → 그때 필터 조정 고려.
- **권한 격리**: 반드시 백엔드 경유(프론트 직접 OpenSearch 질의 금지). Fluent Bit 이 전 ns 로그를 담고 있어 직접 노출 시 타 프로젝트/시크릿 로그 유출 위험.

## 9. 참고 코드 위치

- `dockerizer-backend-server/.../imagebuild/service/ImageBuildService.java` — `getBuildLogs`(143~), `streamBuildLogs`(156~), `findBuildPodName`(265~)
- `dockerizer-backend-server/.../common/config/KubernetesConfiguration.java` / `K8sProperties.java` — `@ConfigurationProperties`/`@Bean` 패턴 참고
- `imagebuild-controller/.../reconciler/KanikoJobFactory.java` — Job `ttlSecondsAfterFinished(3600)`, 라벨
- `helm/dockerizer-backend/{values.yaml, templates/env-configmap.yaml, env-secret.yaml, deployment.yaml}`
- `scripts/install.sh` — "Retrieving secrets" / `deploy_helm_chart "dockerizer-backend"`
