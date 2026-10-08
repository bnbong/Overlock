extends Node
## 씬 전환 + 세션/결과 데이터 버스 오토로드 (아키텍처 §3).
##
## 씬 간 상태는 노드 트리가 아니라 이 오토로드가 전달한다.
##
## 에디터 테스트 플레이(track-editor-ux 1단계): run_source가 SOURCE_EDITOR_TEST면 이번 런은 에디터의
## "테스트 플레이"에서 시작한 것이다. editor_session은 테스트 출발 직전 에디터가 맡긴 편집 문서·화면
## 스냅샷(메모리 전용, 앱 재실행·새로고침 복구 아님)이며 편집 복귀 시 에디터가 꺼내 쓰고 비운다.
## 일반 트랙 선택·허브에서 start_run으로 시작하면 출처와 스냅샷을 정리한다.
##
## 조향 감도 체험(데모): run_source가 SOURCE_CALIBRATION이면 이번 런은 감도 체험 트랙
## (CALIBRATION_TRACK_ID)이다. 메인 첫 Start(최초 닉네임 직후 1회) 또는 종류 선택의 "감도 다시 맞추기"가
## start_calibration으로 들어오며, RaceDirector는 기록·고스트·리더보드·결과 화면을 건너뛴다. 코스는 닫힌
## 순환이고 결승에 닿으면 랩을 되감아 끝없이 달린다(완주 없음). 패널의 "나가기"나 일시정지 메뉴의 M으로만
## exit_calibration을 거쳐 종류 선택 화면에 돌아온다. 재시작(retry_run·씬 리로드)은 출처를 유지하고,
## start_run·open_editor(clear_editor_test 경유)는 출처를 일반으로 되돌린다.

const GAMEPLAY_SCENE: String = "res://scenes/Gameplay.tscn"
const EDITOR_SCENE: String = "res://scenes/TrackEditor.tscn"
const SOURCE_NORMAL: String = ""
const SOURCE_EDITOR_TEST: String = "editor_test"
const SOURCE_CALIBRATION: String = "calibration"
# 감도 체험 트랙 id. TrackLoader.CALIBRATION_TRACK_ID와 같은 값이어야 한다(로더가 데모 경로로 분기).
const CALIBRATION_TRACK_ID: String = "steer_calibration"
const KIND_SELECT_SCENE: String = "res://scenes/TrackKindSelect.tscn"

var track_id: String = "cotton_01"
var difficulty: String = "normal"
var mode: String = "time_attack"
var last_result: Dictionary = {}
var run_source: String = SOURCE_NORMAL
var editor_session: Dictionary = {}
# 에디터를 열 때 편집할 트랙 id(빈 문자열이면 새 트랙). 에디터가 _ready에서 읽고 비운다.
# 공식 트랙·허브에서 받고 편집하지 않은 트랙은 원본을 두고 로컬 사본으로 연다.
var editor_open_id: String = ""
# 감도 체험 입장 직후 튜토리얼을 띄울 차례인지. start_calibration이 세우고 RaceDirector가 한 번 소비한다
# (다시 달리기·R 재시작의 씬 리로드에서는 튜토리얼을 다시 띄우지 않는다).
var _calibration_tutorial_pending: bool = false


## 일반 플레이 시작(트랙 선택·허브). 에디터 테스트·감도 체험 출처와 스냅샷을 정리한다.
func start_run(id: String, diff: String) -> void:
	clear_editor_test()
	_go_gameplay(id, diff)


## 같은 트랙·난이도로 다시 시작한다(결과 화면 재도전). 실행 출처(에디터 테스트·감도 체험)는 유지한다.
func retry_run() -> void:
	_go_gameplay(track_id, difficulty)


## 에디터 테스트 플레이 시작. session은 에디터가 만든 편집 세션 스냅샷이다.
func start_editor_test(id: String, diff: String, session: Dictionary) -> void:
	run_source = SOURCE_EDITOR_TEST
	editor_session = session
	_go_gameplay(id, diff)


func is_editor_test() -> bool:
	return run_source == SOURCE_EDITOR_TEST


## 테스트 플레이에서 에디터로 돌아간다. 스냅샷은 에디터가 복원한 뒤 비운다.
func return_to_editor() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(EDITOR_SCENE)


## 에디터가 복원할 테스트 세션이 있으면 true.
func has_editor_session() -> bool:
	return is_editor_test() and not editor_session.is_empty()


## 테스트 출처와 스냅샷을 정리한다(에디터 복원 완료·에디터 나가기·일반 플레이 시작).
## run_source를 일반으로 되돌리므로 감도 체험 출처도 함께 정리된다(start_run·open_editor 경유).
func clear_editor_test() -> void:
	run_source = SOURCE_NORMAL
	editor_session = {}


## 조향 감도 체험 트랙으로 들어간다(메인 첫 Start·종류 선택의 감도 다시 맞추기). 에디터 스냅샷은 비운다.
func start_calibration() -> void:
	run_source = SOURCE_CALIBRATION
	editor_session = {}
	_calibration_tutorial_pending = true
	_go_gameplay(CALIBRATION_TRACK_ID, "beginner")


func is_calibration() -> bool:
	return run_source == SOURCE_CALIBRATION


## 감도 체험 입장 튜토리얼 차례면 true를 돌려주고 소비한다(감도 체험이 아니면 항상 false).
func take_calibration_tutorial() -> bool:
	var pending: bool = _calibration_tutorial_pending and is_calibration()
	_calibration_tutorial_pending = false
	return pending


## 감도 체험을 끝내고 트랙 종류 선택 화면으로 돌아간다(패널의 나가기·일시정지 메뉴 M).
func exit_calibration() -> void:
	get_tree().paused = false
	run_source = SOURCE_NORMAL
	_calibration_tutorial_pending = false
	# 데모 뒤에는 last_mode와 무관하게 공식 트랙 카드에 기본 포커스를 둔다(계획 문서 요구).
	# MainMenu가 LeaderboardScreenScript의 static을 세팅하는 관례와 같이 스크립트 static으로 전달한다.
	preload("res://scripts/ui/TrackKindSelectScreen.gd").focus_official_once = true
	get_tree().change_scene_to_file(KIND_SELECT_SCENE)


## 트랙 에디터를 연다. id가 비어 있으면 새 트랙, 있으면 그 트랙을 편집한다(공식·미편집 허브
## 다운로드는 로컬 사본). 기존처럼 에디터 씬으로 바로 전환해도 새 트랙으로 열린다.
func open_editor(id: String = "") -> void:
	clear_editor_test()
	editor_open_id = id
	get_tree().change_scene_to_file(EDITOR_SCENE)


func to_result(result: Dictionary) -> void:
	last_result = result
	get_tree().change_scene_to_file("res://scenes/Result.tscn")


func _go_gameplay(id: String, diff: String) -> void:
	track_id = id
	difficulty = diff
	get_tree().change_scene_to_file(GAMEPLAY_SCENE)
