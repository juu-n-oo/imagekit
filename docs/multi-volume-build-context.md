# 다중 볼륨 빌드 컨텍스트 조립 — 설계 비교 (파싱 자동 도출 vs 명시 선언)

> 작성일: 2026-06-05
> 상태: 설계 검토 (미구현)
> 관련 문서: [volume-build-context.html](volume-build-context.html), [imagekit-backend/docs/enhancement-build-context.md](../imagekit-backend/docs/enhancement-build-context.md)

---

## 1. 배경 — 왜 "조립"이 필요한가

현재 빌드 Job은 **빌드 컨텍스트로 PVC 1개만** 모델링한다.

- `ImageBuildSpec` 에 컨텍스트 필드가 단수로만 존재 — `buildContextPvc`, `buildContextSubPath`.
- 컨트롤러(`KanikoJobFactory`)는 그 PVC 하나를 `/build-context` 에 read-only 마운트하고 Kaniko 에 `--context=dir:///build-context` 하나만 넘긴다.

그래서 `COPY <src>` 는 그 **단일 컨텍스트 루트(= 한 볼륨)** 기준으로만 resolve 되고, 여러 볼륨의 파일을 한 이미지에 넣을 수 없다.

### 핵심 제약은 "PVC 개수"가 아니다

k8s 자체는 한 Pod 에 PVC 여러 개를 마운트하는 것을 막지 않는다(RWO 노드 제약은 별개). 진짜 제약은:

1. 현재 CR 이 컨텍스트를 **단수**로만 표현한다.
2. **Kaniko 의 `--context` 는 디렉터리 하나**다. 모든 COPY src 는 그 단일 루트 아래에서 찾는다.

따라서 다중 볼륨을 지원하려면 "여러 PVC 내용을 **하나의 디렉터리로 합쳐 놓는 단계**" 가 빌드 시작 전에 필요하다.

---

## 2. 해결 형태 — initContainer 조립

여러 PVC 내용을 한 디렉터리로 합치는 작업은 **kaniko 컨테이너가 시작되기 전에, 같은 Pod 안에서** 끝나야 한다. 이는 정확히 **initContainer** 의 역할이다.

```
Pod (Kaniko Job)
├─ initContainer: context-assembler (busybox)
│    Volumes:
│      /mnt/vol-a      ← volume-a PVC        (read-only)
│      /mnt/vol-b      ← volume-b PVC        (read-only)
│      /workspace      ← EmptyDir            (read-write, 조립 결과)
│    Commands:
│      cp -a ... → /workspace/...
│
└─ container: kaniko
     Volumes:
       /workspace      ← EmptyDir (위 initContainer 가 채운 그것)
       /kaniko-config  ← Dockerfile ConfigMap
       /kaniko/.docker ← push secret
     Args:
       --context=dir:///workspace
       --dockerfile=/kaniko-config/Dockerfile
```

- sidecar / 별도 Job 은 Pod 경계·실행 순서 보장이 안 되어 부적합 → **initContainer 가 정답**.
- 조립 결과를 담을 `/workspace` 는 EmptyDir(노드 디스크). 대용량 시 `sizeLimit` 설정 권장.

### `cp -a` 가 파일/디렉토리를 자동 구분한다

조립의 핵심은 **`cp -a`(또는 `cp -r`) 한 줄이 파일이면 파일로, 디렉토리면 디렉토리째 복사**한다는 점이다. 별도 분기 로직이 필요 없다.

```sh
# source 가 파일이든 디렉토리든 동일하게 동작
mkdir -p /workspace/$(dirname "models/weights.pt")
cp -a /mnt/vol-a/trained/weights.pt /workspace/models/weights.pt   # 파일 → 파일

mkdir -p /workspace/data
cp -a /mnt/vol-b/dataset/.          /workspace/data/               # 디렉토리 → 디렉토리째
```

즉 "COPY 가 단일 파일이면 단일 파일만, 디렉토리면 디렉토리째" 가 그대로 가능하다. 통짜 볼륨 복사 없이 **필요한 만큼만** 조립된다.

---

## 3. 두 가지 방식

조립 대상(어떤 볼륨의 어떤 경로를 가져올지)을 **어떻게 결정하느냐**가 갈림길이다.

공통 시나리오: 볼륨 `data-storage` 의 `trained/weights.pt`(단일 파일)와 볼륨 `raw-data` 의 `dataset/`(디렉토리째)를 이미지에 넣는다.

### 방식 A — 파싱을 통한 자동 도출

Dockerfile 의 COPY `<src>` 에 **볼륨을 가리키는 규약**을 넣고, 서버가 이를 파싱해 조립 대상을 도출한다. 별도 선언 입력이 없다.

```dockerfile
FROM pytorch/pytorch:2.1.0

# COPY src 에 "볼륨명:/경로" 규약 사용 → 파서가 (볼륨, 경로) 추출
COPY data-storage:/trained/weights.pt  /app/weights.pt
COPY raw-data:/dataset/                /app/data/

RUN pip install -r /app/requirements.txt
CMD ["python", "/app/main.py"]
```

서버가 파싱해 자동 생성 (사용자는 작성하지 않음):

```yaml
# ImageBuild CR — 파서가 도출
contextSources:
  - pvcName: data-storage-43d77785
    volumeSourcePath: trained/weights.pt   # 파일
    targetPath: trained/weights.pt
  - pvcName: raw-data-9f2c1a08
    volumeSourcePath: dataset              # 디렉토리
    targetPath: dataset
```

```sh
# initContainer 가 도출해 실행
mkdir -p /workspace/trained && cp -a /mnt/data-storage/trained/weights.pt /workspace/trained/weights.pt
mkdir -p /workspace/dataset && cp -a /mnt/raw-data/dataset/. /workspace/dataset/
```

빌드 시 kaniko 에 넘기는 Dockerfile 은 COPY src 를 **조립된 경로로 치환**해야 한다 (`data-storage:/trained/weights.pt` → `trained/weights.pt`).

- 👍 사용자는 Dockerfile 한 곳만 작성. 입력 단계 없음.
- 👎 표준 Dockerfile 문법이 아님(`볼륨명:/` 는 전용 규약). 빌드 시 COPY 경로 치환 로직 필요. glob / 멀티 src / `--from` 등 엣지케이스 파싱 부담을 파서가 전부 떠안음.

### 방식 B — 명시 선언

Dockerfile 은 **완전 표준 문법** 그대로 두고, "어떤 파일을 어디서 가져올지" 는 별도 선언(파일 브라우저 UI)으로 입력한다. COPY 는 선언된 `targetPath` 만 참조한다.

```dockerfile
FROM pytorch/pytorch:2.1.0

# 표준 Dockerfile — src 는 빌드 컨텍스트(/workspace) 기준 경로일 뿐
COPY weights.pt   /app/weights.pt
COPY data/        /app/data/

RUN pip install -r /app/requirements.txt
CMD ["python", "/app/main.py"]
```

사용자가 UI 에서 별도로 선언 (볼륨 브라우저로 선택):

```yaml
# 선언 → ImageBuild CR 에 그대로 반영
contextSources:
  - pvcName: data-storage-43d77785
    volumeSourcePath: trained/weights.pt   # 어디서
    targetPath: weights.pt                 # 컨텍스트 어디에 (= COPY src)
  - pvcName: raw-data-9f2c1a08
    volumeSourcePath: dataset
    targetPath: data
```

```sh
# initContainer
mkdir -p /workspace            && cp -a /mnt/data-storage/trained/weights.pt /workspace/weights.pt
mkdir -p /workspace/data       && cp -a /mnt/raw-data/dataset/.              /workspace/data/
```

- 👍 표준 Dockerfile 100%. kaniko 경로 치환 불필요(`--context=dir:///workspace` 그대로). 볼륨/경로가 명확.
- 👎 입력이 두 군데(Dockerfile + 선언). 선언한 `targetPath` 와 Dockerfile COPY `src` 가 일치하는지 **정합성 검증** 필요.

---

## 4. 한눈 비교

| 항목 | A. 파싱 자동 도출 | B. 명시 선언 |
|---|---|---|
| Dockerfile 문법 | 전용 규약(`vol:/path`) | **표준 그대로** |
| 사용자 입력 | Dockerfile 1곳 | Dockerfile + 선언 2곳 |
| kaniko 경로 처리 | src 치환 필요 | 불필요 |
| 정합성 검증 | 파서가 책임 | content ↔ 선언 대조 |
| 엣지케이스(glob/멀티 src/`--from`) | 파서가 전부 떠안음 | 사용자가 명시한 것만 |
| 문서 정합 | 신규 설계 | `enhancement-build-context.md` 모델과 일치 |
| 파일/디렉토리 구분 | `cp -a` 자동 | `cp -a` 자동 |

> **잠정 권장: 방식 B(명시 선언).** 표준 Dockerfile 을 깨지 않고, 백엔드 `enhancement-build-context.md` 모델과 이미 정렬되어 있으며, 파서가 모든 책임을 떠안는 위험이 없다. 방식 A 는 UX 는 매끄럽지만 Dockerfile 을 비표준으로 만들고 파싱 엣지케이스 부담이 크다.

---

## 5. 구현 변경 범위 (4개 레이어)

| 레이어 | 현재 | 변경 |
|---|---|---|
| **CRD** `helm/imagebuild-controller/templates/crd.yaml` | `buildContextPvc` / `buildContextSubPath` (단수) | `contextSources` 리스트 추가 (pvcName, volumeSourcePath, targetPath) |
| **컨트롤러** `KanikoJobFactory.java` | PVC 1개 → `/build-context`, `--context=dir:///build-context` | initContainer(busybox) 추가: N개 PVC 마운트 → EmptyDir `/workspace` 로 `cp -a` 조립 → kaniko `--context=dir:///workspace` |
| **CR 모델** `ImageBuildSpec.java` ×2 (controller, backend-server) | 단수 필드 | 리스트 필드 |
| **백엔드** `ImageBuildRequest` DTO + `ImageBuildService` | `buildContextPvc` 단일 | `contextSources` 리스트 수신 + CR 변환 |
| **프론트** 빌드 다이얼로그 | 볼륨 1개 선택 | 볼륨 N개(+경로) 선택 UI (방식 B 는 파일 브라우저 연동) |

> ⚠️ CRD 변경이므로 **클러스터에 새 CRD apply** 가 필요하다 (prod 반영 전 수동 apply). 기존 단수 필드는 하위호환으로 한동안 함께 두는 것을 권장.

---

## 6. 공통 주의점

1. **부모 디렉토리 mkdir** — `cp` 전에 `mkdir -p` 로 targetPath 상위 경로를 만들어야 한다. 컨트롤러가 cp 명령 생성 시 함께 넣는다.
2. **와일드카드(`COPY *.txt`)** — kaniko 는 glob 을 컨텍스트에서 평가한다. "선언/도출된 것만" 조립하면 누락될 수 있다 → glob 은 "조립된 컨텍스트 안에서만 매칭" 으로 동작을 명확히 하거나 금지.
3. **볼륨 내부 실제 경로(subPath)** — 파일 브라우저가 보여주는 `/data/...` 경로 ≠ PVC 루트 기준 실제 경로일 수 있다([volume-build-context.html](volume-build-context.html)의 함정). source 경로를 **PVC 루트 기준으로 정확히 resolve** 해야 cp 가 맞는다.
4. **EmptyDir 용량** — 조립 결과가 노드 디스크에 쌓인다. 대용량 데이터는 빌드 COPY 보다 런타임 볼륨 마운트가 적절할 수 있음(이미지 비대화 경고 UI 권장).
5. **접근 권한 검증** — 빌드 요청에 지정한 볼륨이 사용자 Project namespace 에 존재하는지, ready 상태인지 서버에서 검증.
6. **경로 순회 방지** — `volumeSourcePath` / `targetPath` 에 `..`, 절대경로 포함 시 reject.
