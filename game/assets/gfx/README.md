# Overlock 그래픽 에셋 (장면/월드 아트)

## 출처와 제작 방식

현재 `*.png`(2차 아트)는 **사용자가 GPT Image 2로 생성해 제공한 단일 스프라이트
시트**(`src/graphics_sheet_v1.png`)를 알파 채널 기반 연결 성분/바운딩 박스로 정밀
분해하고, 각 용도의 규격(캔버스 크기·정렬·타일 seamless)에 맞춰 가공한 것이다.
얼굴·손·노루발·바늘·원단 4종·주야 재봉실 배경·타이틀 플라크가 한 장에 담겨 있었다.

상태별 얼굴 텍스처(`face_normal`/`face_focus`/`face_injured`)는 사용자가 별도로 생성한
**표정 시트**(`src/expressions_sheet_v1.png`, 평상·집중·부상 3변형)를 알파 바운딩 박스로
분해하고, 눈 좌표를 `face_base` 규격에 정규화한 뒤 `face_base` 위에 합성해 만들었다
(아래 "상태별 얼굴 텍스처" 절).

'용과 같이' 등 외부 게임·작품의 에셋·UI·캐릭터를 모사하거나 트레이싱하지 않았다
(docs/design/game_design.md §15.2 IP 주의). 스타일은 따뜻한 수공예/재봉실 무드다.

1차 아트(코드로 저작한 오리지널 SVG)는 롤백 대비로 `src/*.svg`에 보존한다.
`src/`에는 `.gdignore`가 있어 Godot 임포트에서 제외된다(소스 전용).

## 라이선스

프로젝트 코드·통합 작업은 루트 `LICENSE`(MIT)를 따른다. 장면/월드 이미지는 위와
같이 GPT Image 2 생성물을 사용자가 제공한 것으로, 원본 시트는 `src/`에 함께 둔다.

## 가공 요약

- **분해**: 알파 임계 + dilation 라벨링으로 각 성분을 분리하고, 인접 성분(손↔노루발↔
  바늘)이 겹친 사각 크롭은 라벨 마스크로 정리했다.
- **원단 128² seamless**: AI 텍스처는 이음매가 없지 않고 저주파 명암(특히 새틴 광택)이
  타일 반복 시 얼룩으로 드러난다. 저주파 명암을 평탄화한 뒤 대치 경계를 페더 블렌딩해
  실제 seamless 타일로 만들었다. `texture_repeat=ENABLED` 유지(대칭 MIRROR은 능직·니트
  방향성 텍스처에서 다이아몬드/모래시계 이음매를 만들어 배제).
- **손 방향**: 시트의 손(손목 우상단·손끝 좌하단)을 **회전 없이** 그대로 써서 화면
  우측 손(`mirror=false` 기준: 손목이 위·바깥, 손끝이 아래·안쪽)으로 삼는다. 좌측 손은
  노드 `mirror=true`로 좌우 반전한다. 이전 가공에서 이 손을 ~150° 돌려 손끝이 위를 향해
  1인칭처럼 뒤집혀 보이던 문제를 잡았다(`HandView`의 `mirror`·누름 부호도 새 방향에 맞춰
  조정 — 우측 손=우조향에서 누름, 안쪽 이동은 `-flip`).
- **바늘/노루발**: `NeedleView`의 정렬 상수(FOOT_TOP/NEEDLE_TOP_OFFSET)에 맞춰
  바늘이 노루발 슬롯 사이로 오르내리도록 규격화했다.
- **배경**: 재봉실 원화를 Lanczos로 1280×720에 커버 업스케일(약간의 소프트 허용).

## 파일 목록

| 파일 | 용도 | 적용 위치 |
|---|---|---|
| `face_base.png` | 얼굴 베이스(앞머리가 눈을 덮는 구도). 스왑 슬롯이 비면 레거시 폴백 | `BackgroundFace` (`FaceView.texture`) |
| `face_normal.png` | 평상 표정(차분히 뜬 눈). base 위에 표정 시트 눈·앞머리 합성 | `BackgroundFace` (`FaceView.face_normal`) |
| `face_focus.png` | 집중 표정(결의 눈매+땀). base 위에 합성 | `BackgroundFace` (`FaceView.face_focus`) |
| `face_injured.png` | 부상 표정(질끈 감은 `><` 눈+홍조+땀). base 위에 합성 | `BackgroundFace` (`FaceView.face_injured`) |
| `backdrop_room.png` | 얼굴 뒤 야간 재봉실 배경(상단 ~40%만 노출) | `BackdropLayer/BackdropArt` |
| `hand.png` | 원단을 누르는 손(화면 우측 손 기준, 좌측은 노드 `mirror=true`) | `LeftHand`/`RightHand` (`HandView.texture`) |
| `presser_foot.png` | 금속 노루발(정적) | `NeedleView.foot_texture` |
| `needle.png` | 바늘(왕복 파츠, `_bob`으로 상하 왕복) | `NeedleView.needle_texture` |
| `fabric_cotton.png` | cotton 원단 타일(황록 평직) | `FabricSurface.set_fabric("cotton")` |
| `fabric_denim.png` | denim 원단 타일(인디고 능직) | `FabricSurface.set_fabric("denim")` |
| `fabric_silk.png` | silk 원단 타일(라벤더 새틴) | `FabricSurface.set_fabric("silk")` |
| `fabric_knit.png` | knit 원단 타일(웜톤 니트) | `FabricSurface.set_fabric("knit")` |
| `menu_bg.png` | 메인 메뉴 재봉실 무드 배경(주간) | `Main/BackgroundArt` |
| `title_plaque.png` | 타이틀 자수 패치 플라크(글자 없음, `OVERLOCK` 텍스트를 위에 겹침) | `Main/Menu/TitlePlaque` |

## 얼굴 표정 오버레이 (레거시 폴백 — 스왑 슬롯이 비었을 때만)

아래는 상태별 얼굴 텍스처 슬롯이 모두 비었을 때의 폴백 동작이다(현재는 3종 텍스처가
배선돼 있어 아래 "상태별 얼굴 텍스처" 절의 스왑 모드가 우선한다). 2차 아트 얼굴은
앞머리가 눈을 덮어, 절차적 눈을 항상 그리면 머리카락 위에 눈이 떠 어색하다. 그래서
`BackgroundFace`는 평상시 표정을 그리지 않고(앞머리에 가려진 콘셉트), 상태일 때만
앞머리 사이로 드러난 피부 창(눈 위치)에 라인 아트를 얹는다. 집중(속도·
리스크)에는 찡그린 눈썹+치켜뜬 결의 눈매+관자놀이 땀방울이 강도에 비례해 나타나고,
부상(스턴)에는 만화적 X자 눈을 크게 그린다. 앵커 좌표는 `expr_eye_dx_frac`/
`expr_eye_y_frac`/`expr_sweat_frac` export로 조정한다.

원단 타일은 트랙 JSON의 `fabric` 필드로 런타임 결정된다
(`PresentationController._setup_fabric` → `FabricSurface.set_fabric`).

## 얼굴 배치(구도 결함 수정 2)

`BackgroundFace`는 `face_base.png`를 화면 전체가 아니라 상단부 `face_rect`에 그린다
(`face_draw_scale=0.72`, `face_offset_y=-24`). 이 배치에서 눈·코가 수평선(0.42) 위에
온전히 보인다. 표정 오버레이 앵커(`expr_eye_*`)와 고개꺾기 피벗이 모두 `face_rect`
기준이라 배치 상수를 바꿔도 정합이 유지된다. 얼굴 이미지의 콘텐츠는 캔버스
1280×720 안에서 대략 x[100..1180], y[0..472](헤어밴드 상단 y≈0, 코 y≈430, 옆머리
가닥 y≈472)에 놓여 있고, 눈(피부 창) 영역 중심은 이미지 좌표로 좌 `(454,248)` /
우 `(826,248)` 부근이다.

## 상태별 얼굴 텍스처 (face_normal / face_focus / face_injured) — 합성·배선·계약

세 텍스처는 사용자 표정 시트(`src/expressions_sheet_v1.png`, 평상·집중·부상 3변형,
서로 다른 크기)를 눈 중심 정렬로 정규화해 `face_base` 위에 합성한 결과다. 각 변형의
두 눈을 눈 중심 좌 `(454,248)`·우 `(826,248)`(눈 사이 372px, 중점 `(640,248)`)에 맞춰
정규화한 뒤, 드러난 눈·눈썹·앞머리 창을 `face_base` 위에 얹고 하단을 페더 블렌딩해
아래 얼굴(코·볼·턱)로 이음매 없이 넘어가게 했다. 결과는 `face_base`와 동일한
1280×720 RGBA다.

세 텍스처는 `FaceView`의 export 슬롯(`face_normal`/`face_focus`/`face_injured`)에
배선되어 있고(`scenes/Gameplay.tscn`), `BackgroundFace`가 부상(stun)→injured,
집중(tension≥0.5)→focus, 그 외→normal으로 상태를 정해 0.2s 크로스페이드로 교체한다.
슬롯을 모두 비우면 위 "얼굴 표정 오버레이" 레거시(단일 base + 절차적 라인아트)로
자동 복귀한다(회귀 금지 경로).

- **캔버스/프레이밍**: `face_base`와 동일한 1280×720 RGBA·동일 구도(머리·헤어밴드·
  앞머리 바깥·코·볼·옆머리 가닥의 위치·스케일이 그대로). 인게임 배치
  (`face_draw_scale=0.72`, `face_offset_y=-24`)에서 세 텍스처 모두 눈·코가 수평선 위에
  온전히 보인다(슬롯별 재조정 불요).
- **차이 영역**: `face_base`와 달라지는 곳은 앞머리 사이로 눈이 드러난 중앙 창(캔버스
  좌표 대략 x[277..1005], y[100..378] — 앞머리 아래쪽 + 피부 창 + 눈·눈썹)이다. 그
  아래(코·볼·턱·옆머리, y>378)와 위(헤어밴드·정수리, y<100)는 `face_base`에서 그대로
  이어받아 세 장이 서로 동일하다.
  - `face_normal`: 차분히 뜬 눈(평상).
  - `face_focus`: 결의에 찬 집중 눈매 + 관자놀이 땀방울("재봉선을 응시").
  - `face_injured`: 질끈 감은 `><` 눈 + 볼 홍조 + 땀(부상).
- **크로스페이드 안정 조건**: 세 텍스처의 **알파 실루엣이 픽셀 단위로 동일**해야 한다
  (검증: 상호 실루엣 XOR=0, 알파 최대 오차 0). `_draw_swap`이 이전 상태를 불투명하게
  깐 뒤 다음 상태만 페이드 알파로 얹으므로, 실루엣이 같으면 전환 내내 얼굴이 불투명하게
  유지되고 바깥 윤곽(머리카락·헤어밴드·볼 외곽)이 떨리지 않는다. 중앙 창만
  크로스디졸브된다.
