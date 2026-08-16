# 증거 화면 캡처 checklist

`PRESENT-EVIDENCE-01`이 소유한다. 발표 16~17장에 넣을 실제 UI 증거를 이 순서대로 캡처하고
마스킹한다. **캡처 전에 이 문서를 먼저 읽고, 캡처 후 아래 판정 표를 채운다.**

## 실행 절차

### 0. 사전 준비

1. **NetBird에 연결한다.** 내부 서비스는 모두 overlay 뒤에 있어 연결 없이는 열리지 않는다.
   ```bash
   netbird status        # Connected 인지 확인
   ```
2. **Dashy 포털을 연다.** 서비스 alias 목록은 [`docs/ip-plan.md`](../../../ip-plan.md)가 소유한다.
   포털에서 Argo CD · Jenkins · SonarQube · Grafana · Wazuh · Shuffle 타일로 이동한다.
3. 각 서비스는 Pomerium을 지나 Keycloak으로 로그인한다. Wazuh와 Shuffle은
   `/platform-privileged` 그룹이 있어야 열린다.
4. **캡처 폴더를 만든다.**
   ```bash
   mkdir -p ~/evidence-capture
   ```

### 캡처 방법 (GNOME 기준)

- `Print` 키 → 영역 선택 → 드래그 → 캡처. 저장 위치는 기본 `~/사진/스크린샷`이다.
- 브라우저는 캡처 직전에 **F11로 전체화면**을 켠다. 주소창과 탭이 사라져 마스킹할 것이 크게 준다.
- 화면이 작아 글자가 작으면 브라우저 확대(`Ctrl` `+`)로 **125~150%**까지 키우고 찍는다.
  발표 화면에서 읽히는 것이 해상도보다 중요하다.

### 순서

아래 순서가 가장 빠르다. 터미널 증거를 먼저 끝내고 브라우저 작업을 몰아서 한다.

1. **17a** 터미널 (`demo.sh attack` → `control` → 캡처 → `reset`)
2. **16a** Argo CD
3. **16b** Jenkins 또는 SonarQube
4. **17b** Wazuh + Shuffle 또는 Grafana

### 끝나면

캡처한 PNG를 `~/evidence-capture/`에 모아 파일명을 `16a-argo.png` 형식으로 바꾼 뒤
대화창에 그대로 첨부하거나 경로를 알려준다. 마스킹 누락·가독성·비율은 이쪽에서 검수한다.
검수를 통과한 파일만 `docs/presentation/assets/evidence/`로 옮긴다.

---

## 공통 규칙

| 항목 | 값 |
|---|---|
| 파일 위치 | `docs/presentation/assets/evidence/` |
| 파일명 | `16a-argo.png` 처럼 `슬라이드번호+슬롯-대상.png` |
| 권장 크기 | 가로 **1800px 이상**, 비율 **약 1.9 : 1** (와이어프레임 placeholder가 11.98 × 6.30in) |
| 형식 | PNG |

크게 찍고 필요한 부분만 잘라내는 편이 낫다. 발표 화면에서 글자가 읽혀야 하므로
브라우저 창 전체보다 **주장이 보이는 영역만** 크게 담는다.

### 프레임에서 반드시 빼는 것

- **브라우저 주소창과 탭 제목** — 내부 URL·호스트명이 그대로 드러난다. 캡처 범위를
  콘텐츠 영역으로 한정하거나 전체화면(F11)에서 찍는다.
- 로그인 사용자 이름 · email · 아바타 · 프로필 메뉴
- token · session · cookie · OTP · webhook URL · Secret 값
- 내부 IP · CIDR · 사설 endpoint · AWS account id · ARN 전문
- 실제 사람의 개인정보. HR 화면은 합성 데이터만 쓴다.

가릴 때는 잘라내기를 우선하고, 잘라낼 수 없으면 **불투명 사각형**으로 덮는다.
블러는 복원 가능성이 있어 쓰지 않는다.

### 하지 않는 것

- 생성 이미지나 목업으로 UI를 흉내내지 않는다. 실제로 찍은 화면만 쓴다.
- 판정이 보이지 않는 장식용 화면을 넣지 않는다.
- 여러 화면을 한 장에 몰아넣지 않는다. 슬라이드 한 칸에 하나씩이다.

---

## 16장 — 배포 · 품질 증거

### 16a · Argo CD `hr-system`

- **어디서**: Argo CD UI → Applications → `hr-system` 상세
- **프레임에 반드시**: Application 이름 `hr-system`, `Synced` 배지, `Healthy` 배지,
  target revision `main`
- **빼는 것**: 주소창, 좌측 사용자 메뉴, cluster endpoint URL, repo URL의 host 부분
- **판정 문구(슬라이드용)**: `선언과 라이브가 같다`

대안으로 HR 포털 정상 화면을 써도 된다. 그 경우 목록에 합성 데이터만 있는지 먼저 확인한다.

### 16b · Jenkins 빌드 또는 SonarQube quality gate

**Jenkins를 쓸 때**

- **어디서**: `hr-system` 파이프라인의 성공한 빌드 상세
- **프레임에 반드시**: job 이름, 빌드 번호, 성공 표시, test 결과 수(JUnit) 또는 stage 통과 뷰
- **빼는 것**: 주소창, credential ID, 내부 agent 호스트명, 사용자 메뉴

**SonarQube를 쓸 때**

- **어디서**: `hr-system` 프로젝트 대시보드
- **프레임에 반드시**: `Passed` quality gate 배지, coverage 수치, 프로젝트 이름
- **빼는 것**: 주소창, 토큰 설정 영역, 사용자 메뉴

- **판정 문구**: `gate를 통과한 빌드만 승격된다`

---

## 17장 — 운영 · 보안 증거

### 17a · EKS Kyverno `DENIED` / `ALLOWED`

이 화면만 UI가 아니라 **터미널 출력**이다. `DEMO-AWS-HR-01`의 촬영 인터페이스를 쓴다.

```bash
gitops/tools/demo-aws-hr-01/demo.sh attack     # 미서명 tag-only → DENIED
gitops/tools/demo-aws-hr-01/demo.sh control    # 서명된 exact digest → ALLOWED
```

- **프레임에 반드시**: 두 판정이 **한 화면에 함께** 보여야 한다. `DENIED` 줄과 `ALLOWED` 줄,
  그리고 그것이 admission 판정임을 알 수 있는 policy 이름
- **빼는 것**: AWS account id, ARN 전문, cluster endpoint, image digest는 앞 12자 정도만 남기고
  나머지는 잘라낸다
- **가독성**: 터미널 글꼴을 평소보다 크게 키우고(최소 16pt) 창을 넓혀 줄바꿈을 없앤다.
  배경은 밝은 쪽이 슬라이드에서 읽기 좋다.
- **판정 문구**: `미서명은 거부, 서명된 digest만 허용`

`demo.sh`는 server-side dry-run만 하므로 실제 배포·pull·Deployment 변경이 없다.
캡처 뒤 `demo.sh reset`을 실행한다(원격 삭제 없는 no-op).

### 17b · Wazuh 탐지 또는 Grafana 운영 상태

**Wazuh + Shuffle을 쓸 때** (사람 승인 서사에 더 맞다)

- **어디서**: Wazuh Dashboard의 경보 목록/상세, Shuffle의 승인 대기 workflow
- **프레임에 반드시**: 경보의 rule 이름과 심각도, 그리고 그 경보가 **사람 승인 단계에서
  멈춰 있다**는 것이 보이는 부분
- **빼는 것**: 주소창, agent 호스트명·IP, 사용자 메뉴, webhook URL

**Grafana를 쓸 때**

- **어디서**: 플랫폼 운영 대시보드
- **프레임에 반드시**: 대시보드 제목과 정상 범위의 지표 패널
- **빼는 것**: 주소창, 내부 host 라벨, 사용자 메뉴

- **판정 문구**: `탐지가 사람 승인으로 이어진다`

---

## 캡처 후 기록

캡처가 끝나면 아래 표를 채우고 같은 내용을 [`../SOURCES.md`](../SOURCES.md)에도 남긴다.

| 슬롯 | 파일 | 대상 화면 | 캡처 시점 | 마스킹한 항목 | 판정 문구 |
|---|---|---|---|---|---|
| 16a | `16a-argo.png` | Argo CD `hr-system` 요약 바 + 서비스 3종 트리 | 2026-08-16 | 커밋 Author email 2곳 불투명 사각형 | 선언과 라이브가 같다 |
| 16b | `16b-jenkins-pass.png` | `hr-system-image-build #41` Stages — 11단계 전부 통과 | 2026-08-16 | 없음 | gate를 통과한 빌드만 승격된다 |
| 16b | `16b-jenkins-fail.png` | 같은 job `#42` — test gate에서 중단, 이후 단계 미실행 | 2026-08-16 | 없음 | 실패하면 이미지가 만들어지지 않는다 |
| 17a | `17a-kyverno.png` | `demo.sh prove` 터미널 출력 5줄 | 2026-08-16 | 없음 — 계정·email·IP·token·ARN·account id 미노출 | 미서명은 거부, 서명된 digest만 허용 |
| 17b | `17b-wazuh.png` | Wazuh Threat Hunting — 24시간 218,300건, agent 5종 | 2026-08-16 | Wazuh API id 1건 | 실제 인프라에서 이벤트를 받고 있다 |
| 17b | `17b-shuffle.png` | Shuffle 승인 대기 — `자동 대응은 수행하지 않습니다` | 2026-08-16 | 없음 | 탐지가 사람 승인으로 이어진다 |

## 검수 기준

캡처를 받으면 아래를 확인한다.

1. 위 "프레임에서 반드시 빼는 것"이 하나도 남아 있지 않다.
2. 판정 근거가 **발표 화면 크기에서 읽힌다**. 축소했을 때 글자가 뭉개지면 다시 찍는다.
3. 비율이 약 1.9:1이라 placeholder에 넣었을 때 잘리지 않는다.
4. 캡처 시점과 판정 문구가 서로 맞다. 오래된 화면으로 현재 상태를 주장하지 않는다.
5. 생성 UI·목업·장식용 화면이 0건이다.

## 17a 배치 주의

`17a-kyverno.png`는 1421 × 271 px, 비율 **5.24 : 1**이다. 16~17장 화면 자리(1.9 : 1)보다 훨씬
가로로 길다. `PRESENT-DECK-01`에서 다음 중 하나를 택한다.

- 17장 layout을 바꿔 이 터미널 증거를 **상단 전체 폭**에 두고 UI 증거를 아래에 배치한다.
- 기존 좌우 2분할을 유지하고 상하 여백을 넣어 letterbox로 배치한다.

폭 11.98in 자리에 넣으면 약 118 DPI로 읽을 만하다. 슬라이드 전체 폭(24.67in)까지 늘리면
약 58 DPI로 흐려지므로, 전체 폭 배치를 택할 경우 더 큰 해상도로 다시 캡처한다.

## 16a 해상도 주의

`16a-argo.png`는 928 × 433 px로, 폭 11.98in 자리에 넣으면 약 77 DPI다. `Healthy`,
`Synced to main`, `Sync OK`와 서비스 세 이름은 크게 렌더되어 읽히지만, `Auto sync is enabled`
같은 작은 글자는 뭉갠다. 배치 후 흐리면 브라우저를 125~150%로 확대해 다시 캡처한다.

좌측 하단 줌 컨트롤 바와 좌측 여백은 남겨 두었다. Argo CD UI의 실제 요소이고 잘라내면
상단 요약 바와 트리를 한 프레임에 담을 수 없다.

## 16b 두 장을 쓰는 이유

`#41`은 checkout → test → SonarQube gate → build → Trivy/SBOM → Harbor push → sign & verify →
release handoff까지 **11단계가 전부 통과**한 화면이고, `#42`는 같은 파이프라인이 **test gate에서
끊겨 이후 단계가 그려지지도 않은** 화면이다. 두 장을 나란히 두면 "gate를 통과한 빌드만 승격된다"가
문장이 아니라 그림으로 증명된다.

`#42`의 실패는 결함이 아니라 `QUALITY-05`가 남긴 의도적 음성 fixture다. 백로그 `QUALITY-05` 완료
증거의 `fixture 음성 #42는 JUnit 26/1을 남기고 image build·push·release handoff 0건으로 종료했다`와
같은 사건이다.

`16b-jenkins-pass.png`의 11단계 그래프는 13장(HR 품질·공급망)에도 재사용할 수 있다. native 도형으로
그리는 것보다 실제 파이프라인 화면이 설득력 있다. 배치는 `PRESENT-DECK-01`이 정한다.

`#41` 캡처는 좌측 단계 목록이 중간에서 잘렸다. 상단 그래프에 11단계가 모두 있으므로 증거로 충분하다.

## 17b 두 장과 알려진 결함

`17b-wazuh.png`는 탐지를, `17b-shuffle.png`는 사람 승인을 담당한다. Wazuh 화면의 agent 이름
(`opnsense-01`·`proxmox-01`·`netbird-01`)은 발표 아키텍처에 이미 나오는 별칭이고 IP가 아니므로
가리지 않았다. 실제 인프라에서 수집 중이라는 증거다.

`17b-shuffle.png`에는 알려진 표시 결함이 있다. 승인 문구가
`Wazuh 보강 완료\n\n자동 대응은 수행하지 않습니다`처럼 줄바꿈이 literal `\n`으로 출력된다.
Shuffle workflow 메시지 문자열의 이스케이프 문제이며, 사용자가 그대로 쓰기로 결정했다.
고치려면 라이브 workflow 수정이 필요해 `SOAR-01` 계열 별도 작업이 된다.

`17b-shuffle.png`는 532 × 520 px로 폭 11.98in 자리에서 약 44 DPI다. 다른 증거(101~118 DPI)보다
낮아 나란히 두면 차이가 보인다. 화면 요소가 크고 단순해 읽히기는 하지만, `PRESENT-DECK-01`에서
배치한 뒤 흐리면 브라우저를 150~200%로 확대해 다시 캡처한다.
