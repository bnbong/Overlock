# Overlock 그래픽 에셋 (장면/월드 아트)

이 폴더의 모든 이미지는 Overlock 프로젝트를 위해 **직접 저작한 오리지널 아트**다.
외부 게임·작품의 에셋·캐릭터·UI를 모사하거나 트레이싱하지 않았다
(docs/design/game_design.md §15.2 IP 주의 준수). 스타일은 따뜻한 수공예/재봉실
무드의 플랫 벡터 일러스트(라인 최소, 부드러운 음영 1~2단)이며, 팔레트는 원단
웜톤(황록·베이지)에 실 보라/빨강 포인트를 더했다.

## 라이선스

프로젝트와 동일한 **MIT License** (루트 `LICENSE` 참조). 자체 제작 에셋.

## 제작 방식

- `src/*.svg` — 코드로 저작한 소스 SVG. `scratchpad/gen_assets.py`(세션 도구)가
  파라미터로 생성한다. `src/`에는 `.gdignore`가 있어 Godot 임포트 대상에서 제외된다
  (소스 전용).
- `*.png` — 소스 SVG를 cairosvg로 래스터라이즈한 최종 임포트 파일. Godot 4가
  네이티브로 임포트한다(`*.png.import`).

## 파일 목록

| 파일 | 용도 | 적용 위치 |
|---|---|---|
| `face_base.png` | 캐릭터 얼굴 베이스(머리·피부·머리카락·코·헤어밴드). 눈썹·눈·X자 눈 표정은 절차적으로 위에 그려짐 | `BackgroundFace` (`FaceView.texture`) |
| `backdrop_room.png` | 얼굴 뒤 재봉실 배경(창·선반·실패 실루엣, 상단 ~40%만 노출) | `BackdropLayer/BackdropArt` |
| `hand.png` | 원단을 누르는 손(우측 지향, 엔진에서 좌측은 mirror) | `LeftHand`/`RightHand` (`HandView.texture`) |
| `presser_foot.png` | 금속 노루발(정적) | `NeedleView.foot_texture` |
| `needle.png` | 바늘(왕복 파츠, `_bob`으로 상하 왕복) | `NeedleView.needle_texture` |
| `fabric_cotton.png` | cotton 원단 타일(황록 평직) | `FabricSurface.set_fabric("cotton")` |
| `fabric_denim.png` | denim 원단 타일(인디고 능직) | `FabricSurface.set_fabric("denim")` |
| `fabric_silk.png` | silk 원단 타일(라벤더 새틴 광택) | `FabricSurface.set_fabric("silk")` |
| `fabric_knit.png` | knit 원단 타일(웜톤 니트 V자) | `FabricSurface.set_fabric("knit")` |
| `menu_bg.png` | 메인 메뉴 재봉실 무드 배경 | `Main/BackgroundArt` |

원단 타일은 트랙 JSON의 `fabric` 필드로 런타임 결정된다
(`PresentationController._setup_fabric` → `FabricSurface.set_fabric`). 128×128
seamless로 저작해 Mode 7 워프 아래 반복 타일링 시 이음매가 없다.
