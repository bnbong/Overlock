extends RefCounted
## PromoDriver 읽기 전용 보조 함수(게임 상태를 읽기만 한다. 어떤 값도 대입하지 않는다).
## tools/palm_contact_regression/play/PlayRead.gd 에서 촬영에 필요한 부분만 가져왔다.


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


## 부호 있는 곡률(rad/px, +=우회전). s±half px 접선 각차의 유한차분.
static func signed_curvature(tr: Object, s: float, half: float = 6.0) -> float:
	var t0: Vector2 = tr.tangent_at_s(s - half)
	var t1: Vector2 = tr.tangent_at_s(s + half)
	return t0.angle_to(t1) / (2.0 * half)


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
