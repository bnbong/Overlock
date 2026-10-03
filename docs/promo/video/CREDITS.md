# 홍보 영상 크레디트

## 음악

영상에 쓴 음악은 Kevin MacLeod의 "Newer Wave"이며, Creative Commons Attribution 4.0 International(CC BY 4.0) 라이선스를 따릅니다. 곡의 45.856초부터 89.492초까지(20마디)를 잘라 썼고, 시작 50ms 페이드 인, 마지막 4박 페이드 아웃, 라우드니스 정규화(약 -1.8dB 게인과 약한 리미팅)를 적용했습니다. CC BY 4.0은 변경 사항을 밝히도록 요구하므로 이 문단에 편집 내용을 적어 두었습니다.

영상 마지막 화면(39.27초부터 43.63초까지, 72박부터 끝까지)의 하단에 아래 표기 문구를 그대로 넣었습니다. 영상을 게시할 때는 설명란에도 같은 문구를 넣어야 합니다.

```
Newer Wave Kevin MacLeod (incompetech.com)
Licensed under Creative Commons: By Attribution 4.0
https://creativecommons.org/licenses/by/4.0/
```

- 곡 페이지: https://incompetech.com/music/royalty-free/index.html?isrc=USUAN2000024
- ISRC: USUAN2000024
- 라이선스 확인 근거와 곡 선정 과정은 `music/LICENSE-music.md`에 있습니다.

## 글꼴

영상의 모든 글자는 Pretendard 1.3.9(Kil Hyung-jin, SIL Open Font License 1.1)로 썼습니다. 사용한 굵기는 Black, ExtraBold, Bold, Medium입니다. 글꼴 파일과 라이선스 전문은 `tools/promo/fonts/`에 있습니다. OFL 1.1은 글꼴을 영상이나 이미지에 사용하는 것을 제한하지 않습니다.

## 게임 화면과 에셋

- 게임 화면은 모두 v2.3.0 빌드를 macOS 데스크톱에서 실제 입력 이벤트로 플레이하며 촬영한 클립 19개에서 가져왔습니다. 모바일 실기기 화면은 없습니다. 19개 가운데 결과 화면 클립(`12_result`)을 뺀 18개를 영상에 사용했습니다. 결과 화면 클립은 포스터와 확인용으로만 남겼습니다.
- 촬영본은 저장소에 넣지 않으며, 촬영과 클립 생성 방법은 `README.md`의 "다시 만드는 방법"에 적었습니다.
- 공유 허브 장면의 게시물 세 개(`하트 한 바퀴 연습`, `느긋한 S자 산책`, `트랙 경기장 한 바퀴`)는 로컬 임시 서버에 올린 촬영용 데모 데이터입니다. 트랙 모양은 `server/tests/fixtures/community_tracks/`의 회귀 검사용 fixture이고, 작성자 이름(`실밥요정`, `솔기장인`, `바늘손`)은 실제 사용자가 아니라 촬영을 위해 지어낸 이름입니다.
- 로고는 `game/assets/gfx/overlock_logo.png`를, 자막의 아이템 아이콘은 `game/assets/gfx/item_moms_chance.png`와 `game/assets/gfx/item_thimble.png`를 썼습니다. 이 이미지들은 Overlock 프로젝트의 에셋입니다(`game/assets/gfx/README.md` 참고).
- 게임 효과음은 넣지 않았습니다. 영상의 소리는 음악 한 곡뿐입니다.

## 모션 그래픽과 제작 도구

바늘, 박음질 선, 패치 카드, 키캡, 링, 별 같은 그래픽은 외부 소재 없이 `tools/promo/video/motion.py`에서 코드로 직접 그렸습니다.

| 도구 | 용도 | 라이선스 |
|---|---|---|
| Godot 4.6.1 Movie Maker | 게임 화면 촬영(1920×1080, 60fps 고정, MJPEG) | MIT |
| skia-python 144 | 프레임 합성과 벡터 그래픽, 글자 렌더링 | BSD-3-Clause |
| NumPy, Pillow, SciPy | 프레임 버퍼 처리, 시트 제작 | BSD 계열, HPND(Pillow) |
| librosa 1.0, soundfile | 박자·온셋 분석, 오디오 입출력 | ISC, BSD-3-Clause |
| FFmpeg(libx264, soxr, AudioToolbox AAC) | 디코딩, 리샘플링, 라우드니스 측정, 인코딩, 먹싱 | LGPL/GPL(빌드 구성에 따름) |
