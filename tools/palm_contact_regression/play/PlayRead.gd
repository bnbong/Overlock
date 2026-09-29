extends RefCounted
## PlayDriver 읽기 전용 보조 함수(게임 상태를 읽기만 한다. 어떤 값도 대입하지 않는다).
## RaceDirector·BackgroundFace·HandView·PresentationController 필드를 get()/call()로 읽는다.


## 재봉선까지의 오차(px). RaceDirector._tick_running()과 같은 query 결과를 읽기만 한다.
static func err(gp: Node) -> float:
	if gp == null:
		return -1.0
	var tr: Object = gp.get("_track")
	var p: Node2D = gp.get("_player")
	if tr == null or p == null:
		return -1.0
	return float(tr.query(p.position, int(gp.get("_hint")))["error"])


## 노루발 heading과 가장 가까운 트랙 접선 사이 각도(도, 부호: +=우). 읽기 전용.
static func heading_err_deg(gp: Node) -> float:
	if gp == null:
		return NAN
	var tr: Object = gp.get("_track")
	var p: Node2D = gp.get("_player")
	if tr == null or p == null:
		return NAN
	var s: float = float(tr.query(p.position, int(gp.get("_hint")))["s"])
	var t: Vector2 = tr.tangent_at_s(s)
	return rad_to_deg(wrapf(p.heading - t.angle(), -PI, PI))


## 강제 복귀 임계(px) = max(300, fail*3.5). RaceDirector 상수를 읽기만 한다.
static func reset_threshold(gp: Node) -> float:
	if gp == null:
		return INF
	var tr: Object = gp.get("_track")
	var consts: Dictionary = gp.get_script().get_script_constant_map()
	return maxf(float(consts["RESET_ABS"]), float(tr.fail) * float(consts["RESET_FAIL_MULT"]))


static func cut_stage(gp: Node) -> int:
	if gp == null:
		return -1
	var pres: Node = gp.get_node_or_null("Presenter")
	return int(pres.get("_cut_stage")) if pres != null else -1


static func load_cut_points(tex_path: String) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	var img: Image = Image.load_from_file(ProjectSettings.globalize_path(tex_path))
	if img == null or img.is_empty():
		return pts
	var w: int = img.get_width()
	var bottoms: PackedInt32Array = PackedInt32Array()
	var lowest: int = -1
	for u in range(w):
		var b: int = -1
		for v in range(img.get_height() - 1, -1, -1):
			if img.get_pixel(u, v).a > 0.5:
				b = v
				break
		bottoms.append(b)
		lowest = maxi(lowest, b)
	var start: int = 0
	for u in range(1, w + 1):
		if u < w and bottoms[u] == bottoms[start]:
			continue
		var v0: int = bottoms[start]
		if u - start >= 16 and v0 >= 0 and v0 >= lowest - 16:
			for c in range(start, u):
				pts.append(Vector2(c + 0.5, v0 + 1.0))
		start = u
	return pts


## BackgroundFace._draw()의 변환(읽은 _steer 기준)으로 절단면 최소 화면 y를 계산한다.
static func face_cut_min_y(face: Control, cut_pts: PackedVector2Array) -> float:
	if face == null or cut_pts.is_empty():
		return INF
	var sz: Vector2 = face.size
	var sc: float = float(face.get("face_draw_scale"))
	var dw: float = sz.x * sc
	var dh: float = sz.y * sc
	var rect: Rect2 = Rect2((sz.x - dw) * 0.5, float(face.get("face_offset_y")), dw, dh)
	var pivot: Vector2 = Vector2(
		rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.60
	)
	var steer: float = float(face.get("_steer"))
	var angle: float = steer * 0.11
	var lean: Vector2 = Vector2(steer * 24.0, 0.0)
	# 꿀밤 바운스(세로 이동)도 BackgroundFace._draw()와 같은 변환에 더한다.
	var bob: Vector2 = Vector2(0.0, float(face.call("bonk_offset_y")))
	var xf: Transform2D = Transform2D(angle, lean + bob + pivot - pivot.rotated(angle))
	var worst: float = INF
	for b in cut_pts:
		var local: Vector2 = rect.position + Vector2(b.x / 1280.0, b.y / 720.0) * rect.size
		worst = minf(worst, (xf * local).y)
	return worst


static func tex_name(h: Node) -> String:
	if h == null:
		return ""
	var parts: Array = []
	for prop in ["_base_texture", "_cut_texture", "_thimble_variant"]:
		var t: Variant = h.get(prop)
		parts.append((t as Texture2D).resource_path.get_file().get_basename() if t != null else "-")
	parts.append("T" if h.get("_thimble_on") == true else "t")
	return "|".join(parts)


static func find_script_node(root: Node, script_file: String) -> Node:
	if root == null:
		return null
	var sc: Script = root.get_script()
	if sc != null and sc.resource_path.ends_with(script_file):
		return root
	for c in root.get_children():
		var r: Node = find_script_node(c, script_file)
		if r != null:
			return r
	return null


static func f(o: Object, prop: String) -> float:
	if o == null:
		return NAN
	var v: Variant = o.get(prop)
	return float(v) if (v is float or v is int) else NAN
