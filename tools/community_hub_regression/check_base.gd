extends Node
## 공유 허브 회귀 검사 공용 상태·도우미(check.gd 가 상속한다, run.sh 가 사본에만 복사).

const HubScene: PackedScene = preload("res://scenes/CommunityHub.tscn")
const TrackLoaderScript: GDScript = preload("res://scripts/autoload/TrackLoader.gd")

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _results: Array = []
var _args: Dictionary = {}


func _ok(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: " + label)


# --- 공통 ---


func _read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text: String = f.get_as_text()
	f.close()
	return JSON.parse_string(text)


func _fixture(name: String) -> Dictionary:
	var d: Variant = _read_json(_args.get("fixtures", "") + "/" + name + ".json")
	return d if d is Dictionary else {}


func _custom_files() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(TrackLoader.CUSTOM_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(f)
	return out


func _post(
	post_id: String, track: Dictionary, chash: String, title: String = "Hub Track"
) -> Dictionary:
	return {"post_id": post_id, "title": title, "content_hash": chash, "track": track}


func _uuid(n: int) -> String:
	return "00000000-0000-4000-8000-%012d" % n


func _file_text(track_id: String) -> String:
	return TrackLoader.read_custom_track_text(track_id)


# --- fixtures ---


func _hub_track(width: Dictionary = {}, items: Array = []) -> Dictionary:
	var fx: Dictionary = _fixture("accept_sparse_s_curve")
	var t: Dictionary = (fx["track"] as Dictionary).duplicate(true)
	t["width"] = width if not width.is_empty() else {"perfect": 18.0, "safe": 42.0, "fail": 90.0}
	t["items"] = items
	return t


func _wait_result(id: int, timeout_s: float = 20.0) -> Dictionary:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_s * 1000.0):
		for r in _results:
			if int(r["request_id"]) == id:
				return r
		await get_tree().process_frame
	return {}


func _count_kind(kind: String) -> int:
	var n: int = 0
	for r in _results:
		if str(r["kind"]) == kind:
			n += 1
	return n


func _sleep(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _publish_own(title: String, width: Dictionary = {}) -> Dictionary:
	var own: Dictionary = _hub_track(width, [{"s": 900.0, "type": "thimble", "lat": 0.0}])
	own["name"] = title
	own["track_id"] = ""
	var id: String = TrackLoader.save_custom_track(own)
	var built: Dictionary = TrackLoader.build_publish_track(id)
	var req: int = CommunityTrackClient.publish(
		title, "tester", "설명 <b>bold</b> [b]x[/b]", built["track"], id
	)
	var r: Dictionary = await _wait_result(req)
	r["local_id"] = id
	return r
