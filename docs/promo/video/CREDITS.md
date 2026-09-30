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

- 게임 화면은 모두 현재 빌드를 실제 입력으로 플레이하며 촬영한 `footage/`의 클립 13개에서 가져왔습니다. 13개 클립을 모두 한 번 이상 사용했습니다.
- 로고는 `game/assets/gfx/overlock_logo.png`를, 자막의 아이템 아이콘은 `game/assets/gfx/item_moms_chance.png`와 `game/assets/gfx/item_thimble.png`를 썼습니다. 이 이미지들은 Overlock 프로젝트의 에셋입니다(`game/assets/gfx/README.md` 참고).
- 게임 효과음은 넣지 않았습니다. 영상의 소리는 음악 한 곡뿐입니다.

## 모션 그래픽과 제작 도구

바늘, 박음질 선, 패치 카드, 키캡, 링, 별 같은 그래픽은 외부 소재 없이 `tools/promo/video/motion.py`에서 코드로 직접 그렸습니다.

| 도구 | 용도 | 라이선스 |
|---|---|---|
| skia-python 144 | 프레임 합성과 벡터 그래픽, 글자 렌더링 | BSD-3-Clause |
| NumPy, Pillow, SciPy | 프레임 버퍼 처리, 시트 제작 | BSD 계열, HPND(Pillow) |
| librosa 1.0, soundfile | 박자·온셋 분석, 오디오 입출력 | ISC, BSD-3-Clause |
| FFmpeg 7.1.1(libx264, soxr, AudioToolbox AAC) | 디코딩, 리샘플링, 라우드니스 측정, 인코딩, 먹싱 | LGPL/GPL(빌드 구성에 따름) |
