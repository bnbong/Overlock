extends Node
## 드리프트 주름 회귀 검사 공통 기반(카운터·대기·상수). check_game.gd → check.gd가 상속한다.

const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const RD = preload("res://scripts/systems/RaceDirector.gd")
const DT: float = 1.0 / 60.0
const TRACK: String = "tee_01"
const SCREEN: Vector2 = Vector2(1280.0, 720.0)
const MIN_PASSED: int = 100

var _passed: int = 0
var _failed: int = 0
var _hand_img_cache: Dictionary = {}


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", label)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
