# 발표 아키텍처 이미지 prompt

`PRESENT-VISUAL-01`이 소유한다. 사용자가 chatgpt.com에서 이 prompt로 후보를 생성하면
기술·구도 관점에서 검토해 targeted 수정 prompt를 만들고, 최종 한 장을 승인받는다.

## 이 이미지가 지켜야 하는 제약

| 항목 | 값 | 근거 |
|---|---|---|
| 캔버스 | 16:9 | Q&A 배경(21장)에 전체 화면으로 재사용 |
| 세이프존 | 중앙 높이 **76%** | 8~11장 placeholder가 2.327:1이라 상하 각 11.8%가 잘린다 |
| 팔레트 | black · white · neon green `#15E954` | 발표 템플릿과 같은 색 |
| 서비스명 | 공식 영문 | 한글 설명은 필요한 곳만 |
| 구도 | 온프레미스가 중심, AWS는 대표 워크로드와 착지점 | HR System이 구도를 독점하지 않는다 |
| 금지 | 가짜 UI, 긴 생성 텍스트, 실제 주소·계정·비밀 | |

구조 기준은 [`architecture/platform-architecture.drawio`](../../architecture/platform-architecture.drawio)다.
생성 이미지는 그 그림의 **구도와 경계**를 따르되 도식을 그대로 베끼지 않는다.

## prompt v2 (영문, chatgpt.com 입력용) — 현재 사용본

v1은 대문자 섹션 헤더로 된 사양서 형식이라 이미지 생성이 아니라 자료 검색으로 처리됐다.
v2는 첫 줄에 생성 지시를 두고, 섹션 헤더 없이 흐르는 문장으로 바꾸고, 브랜드 로고를
명시적으로 금지한다.

```text
Create an original 16:9 isometric illustration. This is an illustration request, not a
logo lookup and not a diagram of existing brands — draw everything from scratch.

The scene is a hybrid infrastructure landscape on a deep black background, rendered in
white and light grey line-work with a single neon green accent color (#15E954) used
sparingly.

The left two thirds is an on-premises room. It holds one single isometric server block,
clearly one machine rather than a row of racks, with a firewall appliance at the far left
edge acting as the boundary to the outside, and a few translucent floating planes above
the server suggesting virtual machines and one small compute cluster.

The right one third is a cloud region, lighter and more open, drawn as a few floating
platforms holding a small cluster, a database cylinder, and a storage bucket. Keep this
side visually lighter and smaller in weight than the left.

Between the two sides there is exactly one thin encrypted tunnel line crossing a visible
gap. It is the only connection between them.

Add four thin one-way flow lines in neon green: one entering the firewall from outside,
one moving left to right through several small gates and then crossing into the cloud,
one converging from several points into a single node and visibly stopping at a small
human figure, and one leaving the on-premises storage toward the cloud bucket.

Keep every important element inside the central 76 percent horizontal band of the frame.
The top 12 percent and bottom 12 percent must stay empty background.

Use almost no text: at most a few one-word English labels in a clean sans-serif. Do not
include any company logo, brand mark, product logo, UI screenshot, invented product name,
or any person other than that one small figure.

The style is restrained and engineering-grade, flat isometric with subtle depth, generous
negative space, no glow, no lens flare, no sci-fi neon city aesthetic.
```

### 실행 시 주의

- 새 대화에서 시작한다. 앞선 대화 맥락이 남아 있으면 생성이 아닌 응답으로 흐르기 쉽다.
- prompt 앞에 `아래 설명대로 이미지를 만들어줘.` 한 줄을 붙이면 생성 의도가 확실해진다.
- 결과가 또 로고나 기존 이미지면 prompt 문제가 아니라 생성 기능이 호출되지 않은 것이다.

## prompt v1 (실패 — 기록용)

```text
A wide 16:9 isometric technical illustration of a hybrid security platform.
Editorial infographic style, not a screenshot, not a UI mockup.

PALETTE — strictly three colors:
- Deep black background (#000000)
- White and light grey for structures and lines
- One accent color, neon green (#15E954), used sparingly for highlights and flow lines only

COMPOSITION — one continuous scene, left to right:
- LEFT TWO THIRDS: an on-premises data room. A single physical server rack rendered as one
  isometric block, clearly ONE machine, not a row of servers. Above and around it, floating
  isometric planes represent virtual machines and a small container cluster. A firewall
  appliance sits at the left edge as the boundary to the outside.
- RIGHT ONE THIRD: a cloud region, visually lighter and more open, drawn as floating
  isometric platforms. It holds a small private cluster, a database cylinder, a container
  registry, and an object storage bucket. Keep it clearly smaller in visual weight than the
  on-premises side.
- BETWEEN THEM: a single encrypted tunnel line crossing a visible boundary gap. This is the
  only connection between the two sides.

FLOW LINES — thin, directional, one direction only, no bidirectional arrows:
- One line from outside into the firewall, then into the cluster (user access)
- One line inside the on-premises side moving left to right through several small gates,
  then crossing into the cloud registry (software supply chain)
- One line collecting from several points into a single node, then stopping at a small
  human figure icon (detection leading to human approval — the line must visibly STOP there)
- One line from the on-premises storage out to the cloud object storage (offsite backup)

SAFE ZONE — critical:
Keep every important element inside the central 76% horizontal band of the frame.
The top 12% and bottom 12% must contain only background, empty space, or faint texture.
Nothing meaningful may sit in those margins.

TEXT:
Very few words. Only short English labels, one or two words each, in a clean sans-serif.
No paragraphs, no sentences, no invented product names, no fake console output, no logos.
If a label cannot be rendered cleanly, leave the element unlabeled.

MOOD:
Restrained, precise, engineering-grade. Generous negative space. No glow, no lens flare,
no neon city aesthetic, no floating holograms, no people other than the single small
approval figure. Flat isometric with subtle depth, not photorealistic.
```

## 검토 기준 (후보를 받으면 이 순서로 본다)

1. **세이프존** — 중앙 76% 밖에 핵심 요소가 있으면 8~11장에서 잘린다.
2. **균형** — 온프레미스가 중심인가. 클라우드가 화면을 지배하면 수정한다.
3. **단일 물리 노드** — 서버 랙이 여러 대로 그려지면 SPOF 서사가 깨진다.
4. **연결** — 두 영역 사이 연결선이 하나인가. 여러 줄이면 사설 경로 하나라는 사실과 어긋난다.
5. **사람 승인** — 탐지 흐름이 사람 아이콘에서 멈추는가. 자동 차단으로 보이면 안 된다.
6. **텍스트** — 왜곡된 글자, 지어낸 제품명, 가짜 UI가 있으면 제거 대상이다.
7. **팔레트** — 세 가지 색을 벗어나면 발표 템플릿과 어긋난다.

## 실패 시 전환 경로

생성 모델이 로고나 텍스트를 계속 왜곡하면 **아이콘과 텍스트가 없는 배경 일러스트**로 전환하고,
공식 아이콘은 `assets/icons/`의 원본을 PPT에서 합성한다. 이 경우 prompt의 TEXT 절을
`No text at all. Unlabeled shapes only.`로 바꾼다.

## 후보 기록

승인된 최종 이미지와 그때 쓴 prompt를 아래에 남기고, 파일은 이 디렉터리에 둔다.
출처·생성 도구·생성 시점은 [`../SOURCES.md`](../SOURCES.md)에도 기록한다.

| 회차 | prompt | 결과 | 판정 |
|---|---|---|---|
| v1 | 사양서 형식(대문자 섹션) | 이미지가 아니라 Kubernetes 공식 로고가 반환됨 | 실패 — 생성 지시 부재 |
| v2 | 생성 지시 + 흐르는 문장 + 로고 금지 | (사용자 생성 대기) | — |
