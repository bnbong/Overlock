extends Node
## 씬 전환 + 세션/결과 데이터 버스 오토로드 (아키텍처 §3).
##
## 씬 간 상태는 노드 트리가 아니라 이 오토로드가 전달한다.
##
## 에디터 테스트 플레이(track-editor-ux 1단계): run_source가 SOURCE_EDITOR_TEST면 이번 런은 에디터의
## "테스트 플레이"에서 시작한 것이다. editor_session은 테스트 출발 직전 에디터가 맡긴 편집 문서·화면
## 스냅샷(메모리 전용, 앱 재실행·새로고침 복구 아님)이며 편집 복귀 시 에디터가 꺼내 쓰고 비운다.
## 일반 트랙 선택·허브에서 start_run으로 시작하면 출처와 스냅샷을 정리한다.

const GAMEPLAY_SCENE: String = "res://scenes/Gameplay.tscn"
const EDITOR_SCENE: String = "res://scenes/TrackEditor.tscn"
const SOURCE_NORMAL: String = ""
const SOURCE_EDITOR_TEST: String = "editor_test"

var track_id: String = "cotton_01"
var difficulty: String = "normal"
var mode: String = "time_attack"
var last_result: Dictionary = {}
var run_source: String = SOURCE_NORMAL
var editor_session: Dictionary = {}
# 에디터를 열 때 편집할 트랙 id(빈 문자열이면 새 트랙). 에디터가 _ready에서 읽고 비운다.
# 공식 트랙·허브에서 받고 편집하지 않은 트랙은 원본을 두고 로컬 사본으로 연다.
var editor_open_id: String = ""


## 일반 플레이 시작(트랙 선택·허브). 에디터 테스트 출처와 스냅샷을 정리한다.
func start_run(id: String, diff: String) -> void:
	clear_editor_test()
	_go_gameplay(id, diff)


## 같은 트랙·난이도로 다시 시작한다(결과 화면 재도전). 실행 출처(에디터 테스트 여부)는 유지한다.
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
func clear_editor_test() -> void:
	run_source = SOURCE_NORMAL
	editor_session = {}


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
