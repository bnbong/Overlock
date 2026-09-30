class_name EditorTrimTool
extends RefCounted
## 끝부분 자르기 도구(TrackEditor.gd 분리). 누른 점부터 끝까지 잘릴 구간을 미리 강조하고 함께 지워질
## 아이템 수를 알린 뒤, 뗄 때 TrackEditor._cut_to로 한 번에 자른다(undo 한 단위). 취소하면 자르지 않는다.

var hit: int = -1  # 드래그 중 가장 앞쪽 판정 점

var _ed: Control


func _init(editor: Control) -> void:
	_ed = editor


func bind() -> void:
	var cv: DrawCanvas = _ed._canvas
	cv.trim_begin.connect(begin)
	cv.trim_dragged.connect(dragged)
	cv.trim_end.connect(end)
	cv.trim_hover.connect(hover)
	cv.trim_hover_exit.connect(hover_exit)


## 브러시(화면 기준 반경)가 처음 닿는 점 index(-1이면 없음). 이 점부터 끝까지 잘린다.
func hit_index(world_pos: Vector2) -> int:
	var path: PackedVector2Array = _ed._doc["path"]
	if path.size() < 2:
		return -1
	var radius: float = _ed._canvas.world_radius(_ed.TRIM_PX, _ed.TRIM_RADIUS)
	for i in range(path.size()):
		if path[i].distance_to(world_pos) <= radius:
			return i
	return -1


func hover(world_pos: Vector2) -> void:
	var h: int = hit_index(world_pos)
	_ed._canvas.set_trim_preview(h)
	if h >= 0:
		_announce(h, "누르면")
	else:
		clear_hint()


func hover_exit() -> void:
	hit = -1
	_ed._canvas.set_trim_preview(-1)
	clear_hint()


func begin(world_pos: Vector2) -> void:
	hit = hit_index(world_pos)
	_ed._canvas.set_trim_preview(hit)
	if hit >= 0:
		_announce(hit, "놓으면")


func dragged(world_pos: Vector2) -> void:
	var h: int = hit_index(world_pos)
	if h >= 0 and (hit < 0 or h < hit):
		hit = h
		_ed._canvas.set_trim_preview(h)
		_announce(h, "놓으면")


func end() -> void:
	var h: int = hit
	hit = -1
	_ed._canvas.set_trim_preview(-1)
	clear_hint()
	if h >= 0:
		_ed._cut_to(h)


## 잘릴 구간(빨간색)과 함께 제거될 아이템 수를 미리 알린다. 안내 전 문구는 기억해 두고 되돌린다.
func _announce(keep_count: int, verb: String) -> void:
	var path: PackedVector2Array = _ed._doc["path"]
	var new_len: float = EditorDoc.length_to(path, keep_count - 1)
	var removed: int = int(EditorDoc.items_within(_ed._doc["items"], new_len)["removed"])
	var extra: String = "  (아이템 %d개 함께 제거)" % removed if removed > 0 else ""
	var restore: Array = _ed._hint_restore
	if restore.is_empty():
		restore = [_ed._status_label.text, _ed._status_color()]
	_ed._set_status("%s 빨간 구간을 잘라 냅니다%s" % [verb, extra], _ed.WARN_COLOR)
	_ed._hint_restore = restore


func clear_hint() -> void:
	var restore: Array = _ed._hint_restore
	if restore.is_empty():
		return
	_ed._set_status(str(restore[0]), restore[1])
	_ed._hint_restore = []
