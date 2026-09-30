# 트랙 에디터 UX 진단 자료

2026-09-30의 루트 game/ 사본으로 확인한 자료다. 개선 계획은 [상위 문서](../track-editor-ux-improvement-plan.md)에 있다.

- initial.png: 실제 OpenGL 렌더러의 초기 1280×720 화면.
- imported.png: Harbor Hem 불러오기 직후, 카메라 위치를 바꾸지 않은 화면.
- runtime.log: 자동 상태 주입·콜백 검사 최종 실행 로그. 수동 완주 기록이 아니다.
- Audit.gd / Audit.tscn: 실행에 사용한 진단 하네스. 제품 테스트 프레임워크가 아니며 종료 시 리소스 미해제 경고가 남는다.

재현 시 game/을 임시 디렉터리에 복사하고, 사본 project.godot의 application에 config/use_custom_user_dir=true 및 고유한 config/custom_user_dir_name을 설정한다. 기존 사용자 저장 폴더를 사용하지 않는다. 두 Audit 파일을 사본 프로젝트 루트에 복사한 뒤 Godot 4.6.1에서 import하고 res://Audit.tscn을 headless로 실행한다.

이 진단은 커스텀 트랙 파일을 저장하므로 원본 프로젝트의 일반 사용자 데이터로 실행하지 않는다. 캡처는 별도의 임시 스크립트에서 TrackEditor.tscn 생성 후 frame_post_draw를 기다려 viewport 이미지를 저장한 것이다.
