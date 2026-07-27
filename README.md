<!-- <p align="center">
  <img src=".github/codemaru_logo_text.png" alt="codemaru"/>
</p> -->
<p align="center">
<em><b>Overlock:</b> 재봉틀 레이싱 게임</em>
</p>
<p align="center">
<img src="https://img.shields.io/badge/GODOT-%23FFFFFF?style=flat&logo=godot-engine" alt="Godot Engine"/>
</p>

---

Overlock은 재봉틀 조작을 레이싱 게임의 문법으로 재해석한 싱글 플레이 타임어택 게임입니다.

재봉틀 노루발과 바늘이 레이싱 차체에 대응되며, 자동으로 전진합니다. 플레이어는 속도 단계와 방향만 조작해 원단 위 재봉 경로를 따라가면 됩니다. 고속에서 급조향하면 손가락을 부상당하는 기믹이 있으며, 피니시 라인까지 걸린 시간을 기록해 트랙별 순위를 겨루는 것이 이 게임의 목표입니다.

## 실행 방법

1. [Godot 4.3](https://godotengine.org/download) 이상을 설치.
2. Godot 에디터를 실행하고 `game/project.godot`을 임포트.
3. 에디터에서 실행(F5).

## 조작법

| 입력 | 기능 |
|---|---|
| `←` / `A` | 왼쪽 조향 |
| `→` / `D` | 오른쪽 조향 |
| `↑` / `W` | 속도 단계 상승 |
| `↓` / `S` | 속도 단계 하락 |
| `R` | 재시작 |
| `Esc` | 일시정지 |

## 문서

- [게임 기획서](docs/design/game_design.md)
- [클라이언트 아키텍처](docs/architecture.md)

## 로드맵

1. Phase 1: 조작감 프로토타입 — 아트 없이 자동 전진, 속도 조절, 조향 지연의 재미를 검증한다.
2. Phase 2: 위험도 / 부상 시스템 — 손가락 부상 위험도와 경고 연출을 구현한다.
3. Phase 3: UI / 미니맵 — 스톱워치, 속도 게이지, 부분 미니맵, 결과 화면을 구현한다.
4. Phase 4: 2.5D 화면 연출 — 배경, 손, 원단 스크롤 등 시각 연출을 더한다.
5. Phase 5: 리더보드 — 기록 제출 API와 트랙별 랭킹을 연동한다.

자세한 내용은 [게임 기획서 §18](docs/design/game_design.md#18-개발-로드맵)을 참고.

## 라이선스

[MIT](LICENSE)
