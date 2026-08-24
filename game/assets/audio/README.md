# 오디오 에셋 (플레이스홀더)

이 폴더의 WAV 파일은 모두 `tools/audio_placeholder/gen_audio.py` 스크립트로 합성한
**임시 사운드**다. 실제 게임에 쓸 사운드가 준비되면 언제든 교체할 수 있도록, 최소한의
분위기만 담아 순수 파이썬으로 만들었다. 저작권 문제 없이 자유롭게 커밋·배포할 수 있으며,
이 프로젝트의 라이선스(MIT, 루트 `LICENSE` 참고)를 그대로 따른다.

## 파일 목록

| 파일명 | 용도 | 길이 | 피크 레벨 |
|---|---|---|---|
| `Sewed.mp3` | 메인 타이틀·메뉴 BGM (사용자 제작 음원, 루프) | 210.8초 (루프) | 0.98 |
| `Locking_In.mp3` | 인게임 BGM (사용자 제작 음원, 루프) | 159.1초 (루프) | 0.98 |
| `sfx_tick.wav` | 재봉틀 바늘 틱음. 주행 속도에 비례해 반복 재생하는 용도 | 0.08초 | 0.85 |
| `sfx_countdown.wav` | 카운트다운 비프(낮은 음) | 0.15초 | 0.85 |
| `sfx_go.wav` | 출발 신호(높은 음, 상승 톤) | 0.30초 | 0.85 |
| `sfx_cut.wav` | 손가락 부상 효과음 — 노이즈 버스트 + 하강음 | 0.40초 | 0.90 |
| `sfx_offseam.wav` | 재봉선 이탈 경고 버저 | 0.20초 | 0.85 |
| `sfx_speed_up.wav` | 속도 단계 상승 — 상승 톤 | 0.12초 | 0.85 |
| `sfx_speed_down.wav` | 속도 단계 하락 — 하강 톤 | 0.12초 | 0.85 |
| `sfx_finish.wav` | 피니시 징글 — 3음 상승 아르페지오 | 0.80초 | 0.90 |
| `sfx_record.wav` | 신기록 팡파레 — 4음 밝은 징글 | 1.20초 | 0.90 |

효과음(SFX)은 모두 44.1kHz / 16-bit / mono WAV이며, 0dBFS(피크 1.0)를 넘지 않도록 정규화했고
시작·끝 지점을 0으로 페이드해 클릭 노이즈가 없다. BGM 두 곡(`Sewed.mp3` / `Locking_In.mp3`)은
사용자가 제작해 제공한 실제 음원(MP3)으로, 피크는 약 -0.14dBFS라 클리핑 없이 재생된다.

## 교체 방법

1. **가장 간단한 방법** — 같은 파일명으로 실제 사운드 파일을 덮어쓴다. 예를 들어
   `sfx_cut.wav`를 실제 효과음으로 바꾸고 싶다면 새 파일을 같은 이름(`sfx_cut.wav`)으로
   저장해 이 폴더에 덮어쓰면 된다. 코드에서 파일 경로를 참조하는 방식이라면 별도 수정 없이
   바로 반영된다.
2. **경로 자체를 바꾸고 싶다면** — 현재 이 프로젝트에는 사운드 재생을 담당하는
   `AudioManager`(오토로드)가 아직 없다. 이는 후속 작업으로 별도 구현될 예정이며,
   `AudioManager`가 추가되면 그 안에서 각 사운드 키와 파일 경로를 매핑하게 될 것이다.
   그때는 이 폴더의 파일명 규칙(`bgm_*`, `sfx_*`)을 유지하거나, `AudioManager`의 매핑
   테이블만 수정해서 다른 경로/파일명을 가리키도록 바꾸면 된다.
3. 새 파일을 넣을 때는 이 폴더에 정리된 포맷(44.1kHz, 16-bit, mono 또는 스테레오 WAV/OGG)을
   맞추면 Godot 임포트 시 별다른 설정 없이 바로 사용할 수 있다.

## 루프 BGM(`Sewed.mp3` / `Locking_In.mp3`) 주의점

BGM 두 곡은 `AudioStreamMP3`로 임포트되며, `AudioStreamPlayer`에서 끊김 없이 반복 재생하려면
루프가 켜져 있어야 한다.

- **임포트에서 설정(1차 소스)**: 두 MP3의 `.import` `[params]`에 `loop=true`를 둔다. 에디터
  FileSystem 도크에서 파일을 선택하고 Import 탭의 `Loop`를 켠 뒤 `Reimport` 해도 같다. 이러면
  임포트된 리소스의 `stream.loop == true`가 되어 파일 전체가 루프 구간이 된다.
- **코드에서 방어(2차)**: `AudioManager._load_streams`가 로드 직후 `AudioStreamMP3`면
  `stream.loop = true`를 다시 켠다. 임포트 설정이 유실돼도 끊김 없이 반복되게 하는 안전장치다
  (WAV와 달리 MP3는 `loop_begin`/`loop_end`를 따로 지정할 필요가 없다).
- 곡 선택은 `AudioManager.play_bgm(loop_id)`가 맡는다. 메뉴 계열은 `Sewed.mp3`, 인게임은
  `Locking_In.mp3`이며, 같은 곡이 이미 재생 중이면 재시작하지 않는다(메뉴 화면 간 이동에서 곡 끊김 방지).
- 실제 음원으로 교체할 때도 루프 지점에서 파형 위상/음량이 급격히 끊기지 않는 소스를
  고르거나, 오디오 편집기(Audacity 등)로 루프 크로스페이드를 걸어두는 것이 좋다.

## 추천 무료 음원 소스

아래 링크는 모두 접속을 확인했다(2026-07 기준). 실제 다운로드할 때는 개별 에셋 페이지의
라이선스 표기를 다시 한번 확인할 것.

| 소스 | URL | 라이선스 주의사항 |
|---|---|---|
| Kenney | https://kenney.nl/assets?q=audio | 대부분 CC0(퍼블릭 도메인)로 배포된다. 개별 팩 페이지에서도 라이선스가 CC0로 명시되어 있는지 확인할 것(예: [Interface Sounds](https://kenney.nl/assets/interface-sounds)). 출처 표기 없이 자유롭게 사용 가능. |
| OpenGameArt | https://opengameart.org/art-search-advanced?field_art_type_tid%5B%5D=13 | 오디오 검색 페이지. 항목별로 CC0, CC-BY, CC-BY-SA, GPL 등 라이선스가 제각각이므로 **반드시 검색 결과 필터에서 CC0 또는 CC-BY로 좁혀서** 받고, CC-BY 계열은 크레딧 표기가 필요하다. |
| Freesound | https://freesound.org/search/?q=&f=license:%22Creative+Commons+0%22 | 위 링크는 CC0 라이선스로 필터링된 검색 결과다(약 37만 개 이상). CC0가 아닌 일반 검색 결과에는 CC-BY, CC-BY-NC 등 출처 표기/비영리 조건이 붙은 음원이 섞여 있으니 다운로드 전 라이선스 배지를 꼭 확인할 것. 계정 가입이 필요하다. |
| Incompetech (Kevin MacLeod) | https://incompetech.com/music/royalty-free/music.html | 무료(Creative Commons) 라이선스는 **크레딧 표기가 필수**다("music by Kevin MacLeod, incompetech.com" 형태). 표기 없이 쓰려면 유료 Standard License가 필요하다. 자세한 조건은 [라이선스 페이지](https://incompetech.com/music/royalty-free/licenses/) 참고. BGM류를 구할 때 특히 유용. |

## 재생성 방법

플레이스홀더를 다시 만들거나 파라미터(음높이, 길이, 코드 진행 등)를 바꾸고 싶다면
`tools/audio_placeholder/gen_audio.py`를 수정한 뒤 다시 실행하면 이 폴더의 파일이
모두 덮어써진다.

```bash
python3 tools/audio_placeholder/gen_audio.py
```

외부 라이브러리 없이 파이썬 표준 라이브러리(`wave`, `math`, `struct`, `random`)만 사용하므로
별도 설치 없이 바로 실행된다. 실행하면 각 파일의 길이·피크·RMS·루프 경계값을 콘솔에 출력해
클리핑이나 루프 이음새 문제를 눈으로 바로 확인할 수 있다.
