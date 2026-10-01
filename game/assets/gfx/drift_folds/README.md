# 드리프트 원단 주름 높이맵

fold_height.png는 image_gen으로 생성한 1254×1254 불투명 PNG다. 검정은 높이 0, 밝을수록 높은 주름을 나타내는 단일 높이 채널 소스다. 세 개의 길쭉한 주름이 이미지 세로 방향으로 놓여 있다.

컬러 스프라이트로 바닥에 붙이는 에셋이 아니다. 원단의 기존 컬러/텍스처와 함께 높이 투영 및 명암 계산에 사용한다. 별도 normal map은 제공하지 않는다. 필요하면 높이의 인접 샘플 차이로 법선을 계산한다.

Godot에서는 손실 압축 없이 데이터로 읽고 source_color 색 보정을 적용하지 않는다. R 채널을 높이값으로 사용한다. 생성 이미지의 흑백/경계값은 정밀 수치 보장이 아니므로 런타임에서 clamp와 가장자리 smoothstep 감쇠로 경계 높이를 0으로 보장한다. alpha는 없다. 투명도는 높이와 패치 경계 마스크로 계산한다.

컨셉: docs/concepts/drift-fabric-folds-v1.png
구현 전달문: docs/concepts/claude-drift-fabric-folds-implementation.txt
생성 프롬프트: docs/concepts/drift-fabric-folds-prompts.json

v2.3.0에서 엔진 import(lossless, `process/size_limit=256`)와 2.5D 메시 적용, 데스크톱 주행 캡처 검증을 마쳤다. 사용 방식은 `docs/presentation.md` §15와 `game/assets/gfx/README.md`의 "드리프트 원단 주름 높이맵" 절에 정리했다.
