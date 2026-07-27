extends Node
## 씬 전환 + 세션/결과 데이터 버스 오토로드 (아키텍처 §3).
##
## 씬 간 상태는 노드 트리가 아니라 이 오토로드가 전달한다.

var track_id: String = "cotton_01"
var difficulty: String = "normal"
var mode: String = "time_attack"
var last_result: Dictionary = {}


func start_run(id: String, diff: String) -> void:
	track_id = id
	difficulty = diff
	get_tree().change_scene_to_file("res://scenes/Gameplay.tscn")


func to_result(result: Dictionary) -> void:
	last_result = result
	get_tree().change_scene_to_file("res://scenes/Result.tscn")
