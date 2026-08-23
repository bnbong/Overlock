# Overlock 폰트 에셋 (UI 한글 폰트)

## 출처와 선정 근거

UI 전역 폰트는 **Pretendard**(길형진, orionCactus) v1.309 를 쓴다. 공식 저장소
(<https://github.com/orioncactus/pretendard>) 의 `Pretendard-Regular.otf` 를 받아 아래
"서브셋"으로 가공한 `Pretendard-Regular.woff2` 만 저장소에 둔다.

Noto Sans KR 과 저울질한 끝에 Pretendard 를 택했다.

- **Latin·Korean 일관성**: 화면에는 Latin UI 문구(`OVERLOCK`·`Start`·`RISK`·`SELECT
  TRACK`·게이지 숫자)와 한글이 섞여 나온다. Pretendard 의 Latin 은 Inter 계열이라
  한글 글자체와 한 벌처럼 붙어, Noto Sans KR(Latin=Noto Sans, 다소 사무적)보다
  섞어 쓸 때 이질감이 적다.
- **따뜻한 톤·소형 가독**: 살짝 둥근 종지와 촘촘한 힌팅이 재봉실 무드의 크림/브라운
  UI 와 어울리고, 버튼·태그 같은 작은 글자에서도 또렷하다.
- **라이선스·용량**: 둘 다 OFL 이지만 Pretendard 원본이 가볍고(1.5MB/weight) 완성형
  11,172 자를 모두 포함해 서브셋 산출물이 작다.

## 라이선스

**SIL Open Font License 1.1**. 전문은 같은 폴더의 `OFL.txt`(원본 저장소 `LICENSE`
그대로). Pretendard 는 Source(Adobe)·Inter·M PLUS 1 계보를 잇는 OFL 폰트다. OFL 은
번들·임베드·서브셋·재배포를 모두 허용하며(예약 폰트명 규정 준수), 게임 코드의 루트
`LICENSE`(MIT)와 별개로 이 폰트에는 OFL 이 적용된다. 서브셋 산출물의 name 테이블에도
원본 저작권·버전(`Version 1.309`)이 그대로 남아 있다.

## 서브셋 (용량 최적화)

닉네임·커스텀 트랙명은 **자유 입력**이라 어떤 음절이든 나올 수 있으므로, KS 완성형
2,350 자 축소판을 쓰면 희귀 음절이 □(tofu)로 재발한다. 그래서 **현대 한글 완성형
11,172 자 전체**를 포함한다. 산출물은 `fonttools`(pyftsubset)로 다음 유니코드 범위만
남겨 woff2(브로틀리)로 뽑았다.

- 현대 한글 완성형 전체 `U+AC00–D7A3` (11,172)
- 한글 호환 자모 `U+3130–318F` (`ㅋㅋ`·`ㅠㅠ` 같은 닉네임 대비)
- Basic Latin + Latin-1 Supplement `U+0020–00FF` (`·`·`×`·`±`·`°`·`§` 포함)
- UI 에 실제 쓰인 기호: 화살표 `←↑→↓↔`, 삼각형 `◀▶`, 원 `●`, 엠대시 `—`,
  줄임표 `…`, 수학기호 `−∞≈≠≤≥` 등(코드 grep 으로 실사용분만 확인)

결과: **12,588 glyph, 681 KB**(woff2). MainMenu 의 연필 아이콘 `✎` 는 `·` 로 교체되어
현재는 폰트에 없는 장식 글리프를 쓰는 곳이 알려져 있지 않다(한글·Latin·나머지 기호는 전부
정상).

재생성:

```bash
pip install "fonttools[woff]" brotli
pyftsubset Pretendard-Regular.otf \
  --unicodes="U+0020-007E,U+00A0-00FF,U+0370-03FF,U+2010-2027,U+2190-21FF,U+2200-22FF,U+25A0-25FF,U+2700-27BF,U+3130-318F,U+AC00-D7A3" \
  --layout-features='*' --name-IDs='*' --flavor=woff2 \
  --output-file=Pretendard-Regular.woff2
```

## 적용 방식

`game/project.godot` 의 `[gui] theme/custom_font` 한 줄로 전역 지정한다.

```ini
[gui]
theme/custom_font="res://assets/fonts/Pretendard-Regular.woff2"
```

이 설정은 엔진 시작 시(기본 테마 생성보다 먼저) 적용돼 **기본 테마의 default_font 와
`ThemeDB.fallback_font` 를 동시에** 이 폰트로 세운다. 덕분에 폰트 오버라이드가 없는 모든
Control(Label·Button 등)뿐 아니라, `draw_string(ThemeDB.fallback_font, …)`(RiskMeter)와
`get_theme_default_font()` 폴백(FinishView)까지 한 번에 커버한다 — 테마 리소스나 씬은
건드리지 않는다.

> 참고: 오토로드에서 런타임에 `ThemeDB.fallback_font` 만 바꾸는 방식은 이미 생성된 기본
> 테마의 `default_font` 를 갈아끼우지 못해 Control 텍스트가 그대로 tofu 로 남는다(엔진의
> `make_default_theme` 가 시작 시점에 폰트를 굳혀서다). 그래서 시작 시점에 반영되는
> `custom_font` 방식을 쓴다.

## 파일 목록

| 파일 | 용도 |
|---|---|
| `Pretendard-Regular.woff2` | UI 전역 폰트(서브셋). `project.godot` 의 `gui/theme/custom_font` 가 참조 |
| `OFL.txt` | SIL Open Font License 1.1 전문(원본 저장소 `LICENSE`) |
