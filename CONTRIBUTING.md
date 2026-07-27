# Contributing

이슈와 PR 환영.

## 개발 환경

- [Godot 4.3](https://godotengine.org/download) 이상
- `game/project.godot`을 Godot 에디터로 임포트해 실행/테스트한다.

## 트랙 기여

트랙은 이미지가 아니라 JSON 데이터로 정의한다. 새 트랙은 [게임 기획서 §9.2](docs/design/game_design.md#92-트랙-json-예시)의 포맷을 따라 작성해 PR로 제출한다.

## 코드 스타일

- GDScript는 함수 인자와 반환값에 타입 힌트를 명시한다.
- 기존 스크립트의 네이밍과 파일 구조(`docs/architecture.md` §10 참고)를 따른다.
