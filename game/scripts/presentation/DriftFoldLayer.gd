class_name DriftFoldLayer
extends Node2D
## 드리프트 원단 주름 2.5D 레이어 (presentation.md §15). FabricLayer 안, 바닥(FabricWarp) 바로 위.
##
## DriftSkid가 기록한 주름 패치를 높이 있는 작은 격자(DriftFoldShape.NU×NV 셀)로 만들어 Mode 7과
## 같은 카메라로 화면에 투영한다. 바닥 셰이더(fabric_mode7.gdshader)의 화면→월드 수식
##   dy = uv.y - horizon;  depth = depth_scale/dy;  lateral = (uv.x-0.5)*depth*spread;
##   world_off = fwd*(depth - cam_back) + rgt*lateral
## 를 역으로 풀면 (d = P - player, forward = d·fwd, lateral = d·rgt, depth = forward + cam_back)
##   uv.x = 0.5 + lateral/(depth*spread),  uv.y = horizon + depth_scale/depth
## 이다(ItemBillboardLayer와 같은 식). 이 식은 높이 CAM_HEIGHT의 핀홀 카메라가 바닥을 보는 것과 같으므로
## 높이 z인 점은
##   uv.y = horizon + depth_scale*(1 - z/CAM_HEIGHT)/depth
## 에 놓인다. z=0이면 바닥 투영과 정확히 같은 위치다. CAM_HEIGHT는 1280×720 캔버스에서 가로·세로
## 픽셀 배율이 같아지는 값(depth_scale*spread*720/1280 ≈ 14.2)이라 높이 1 단위가 같은 깊이의 측방
## 1 단위와 같은 픽셀 길이로 보인다(멀수록 낮고 가까울수록 높다).
##
## 렌더 구조: 활성 패치 슬롯 MAX_ACTIVE개를 미리 만든다. 슬롯마다 RenderingServer 캔버스 아이템 두 개
## (접지 그림자, 표면)와 재질 두 개가 있다. 패치가 슬롯에 들어올 때 정점(바닥 월드 좌표 + 높이·기울기·
## 알파)을 한 번만 올리고, 매 프레임은 카메라·높이 진행 uniform만 바꾼다. 투영·명암은 drift_fold.gdshader의
## 정점 셰이더가 계산한다(project()는 그 GDScript 기준 구현으로, 화면 판정과 회귀 검사에 쓴다).
## 표면 색은 바닥 SubViewport 텍스처를 패치 정점의 원래 월드 UV로 샘플하므로 천 무늬·재봉선·잔여
## 흔적이 솟은 표면과 함께 움직인다. 이 레이어는 바닥 SubViewport에 다시 합성되지 않는다(피드백 없음).
##
## 레이어: 바닥 위, 아이템 빌보드(ItemLayer)·손·노루발(ForegroundLayer)·HUD 아래. 그림자를 모두 먼저,
## 표면은 먼 패치부터 그리고, 패치 안의 셀도 카메라에서 먼 쪽부터 그린다(인덱스 순서). 화면에서 실제로
## 솟아 보이는 패치만 MAX_ACTIVE개까지 메시로 그리고, 나머지(원경·완화가 끝난 흔적)는 DriftSkid가 바닥에
## 칠한 음영으로만 남는다. 시간은 PresentationController의 주행 표현 시계를 받는다(일시정지에서 멈춤).

## 활성 입체 패치 상한(모바일 기준).
## 긴 드리프트에서 겹친 패치(간격 16)가 근경까지 이어지도록 12에서 16으로 늘렸다.
const MAX_ACTIVE: int = 16
## 근경 링에서 후보로 살펴볼 최근 패치 수. 스트로크가 살아 있는 동안 패치가 완화하지 않으므로 생성 시각만으로
## 끊지 않고 이 개수만큼 살핀다(원경·화면 밖은 컬링, 그 바깥은 바닥 잔여 흔적만 남는다).
const SCAN_MAX: int = 64
## 투영 카메라 높이(월드 단위). 위 설명 참조.
const CAM_HEIGHT: float = (
	PresentationController.DEPTH_SCALE * PresentationController.SPREAD * 720.0 / 1280.0
)
## 카메라 앞 최소 깊이(px). 이보다 가까운 정점은 이 깊이로 눌러 투영이 무한대로 튀지 않게 한다.
## 화면 하단(uv.y=1)의 깊이가 약 48이라 클램프되는 정점은 항상 화면 밖이고, 근경 감쇠(NEAR_FADE_LO)보다
## 가까워 표면 알파·높이가 0이므로 눌린 정점이 만드는 삼각형 왜곡은 보이지 않는다. 긴 드리프트에서 패치가 카메라
## 아래까지 오래 남으므로, 눌린 정점이 화면 바로 아래(y 약 760)에 머물도록 30에서 44로 올렸다.
const NEAR_CLIP: float = 44.0
## 이보다 먼 패치(수평선 쪽)는 메시로 그리지 않는다. 바닥 셰이더의 수평선 페이드 대역보다 가깝다.
const FAR_DEPTH: float = 420.0
## 플레이어에서 패치 중심까지 이보다 멀면 그리지 않는다. 패치 반대각선(약 60)을 더해도 바닥 텍스처
## 범위(coverage/2 = 300) 안이라 UV가 텍스처 밖으로 나가지 않는다.
const MAX_DIST: float = 230.0
## 화면에서 이보다 낮게 솟는 패치는 메시를 생략한다(바닥 음영만 남는다).
const MIN_LIFT_PX: float = 0.4
## 셰이더 기울기 인코딩 범위(drift_fold.gdshader GRAD_RANGE와 같아야 한다).
const GRAD_RANGE: float = 1.5
## 광원(카메라 기준: 오른쪽, 앞쪽(먼 쪽), 위). 화면 왼쪽 위에서 비춘다.
const LIGHT: Vector3 = Vector3(-0.5, 0.45, 0.74)
const LIGHT_GAIN: float = 0.95
const AO_GAIN: float = 0.5
## 능선 꼭대기를 살짝 밝힌다(높이 × 진행도 비례). 솟은 곳이 바닥보다 밝게 읽히게 한다.
const CREST_GAIN: float = 0.3
## 표면 밝기 배율 범위(검게 뭉개지거나 하얗게 날아가지 않게).
const LUM_MIN: float = 0.6
const LUM_MAX: float = 1.32
const SHADOW_ALPHA: float = 0.5
## 화면에서 솟는 최대 픽셀(1280×720 캔버스). 카메라 바로 앞(depth 50 근처는 높이 1 단위가 약 28px)에서
## 주름이 지나치게 높아지지 않게 정점 깊이별로 패치 높이를 비례로 낮춘다(drift_fold.gdshader).
const MAX_LIFT_PX: float = 48.0
## 강도별 화면 솟음 상한: LIFT_CAP_BASE + LIFT_CAP_GAIN × 강도(보통 0.6 → 42.4px, 강도 1 → 48px). 높이 중심
## 깊이에서는 보통·정점 모두 상한에 닿으므로, 상한을 강도에 비례시켜 정점이 분명히 더 높게 보이게 한다.
const LIFT_CAP_BASE: float = 34.0
const LIFT_CAP_GAIN: float = 14.0
## 카메라 바로 앞 감쇠 구간(깊이). 이보다 가까운 정점은 높이·명암이 0으로 줄어 근경 부채꼴 줄무늬를 막는다.
const NEAR_FADE_LO: float = 46.0
const NEAR_FADE_HI: float = 72.0
## 완화가 끝났을 때 측방 퍼짐 배율(완화 진행에 따라 1 → 1+RELAX_SPREAD). 능선이 넓어지며 낮아진다.
const RELAX_SPREAD: float = 0.45
## 그림자가 광원 반대쪽으로 밀리는 길이(높이 배수).
const SHADOW_LEN: float = 0.5
const SHADER_PATH: String = "res://shaders/drift_fold.gdshader"
## 전 슬롯 공통 값을 담는 전역 셰이더 uniform(런타임 등록, project.godot 변경 없음).
const G_PLAYER: StringName = &"fold_player_pos"
const G_HEADING: StringName = &"fold_heading"
const G_NOW: StringName = &"fold_now"

static var _globals_ready: bool = false

## false면 아무것도 그리지 않는다(연출 OFF 비교·문제 시 끄기).
var enabled: bool = true
## 검증 전용: true면 모든 패치를 높이 0·불투명·그림자 없음으로 그린다. 이때 화면이 바닥과 같아야 한다
## (투영·월드 UV가 Mode 7 바닥과 일치함을 픽셀로 확인하는 캡처 검사용, 게임에서는 쓰지 않는다).
var debug_flat: bool = false
## 검증 전용 높이 비교 모드(같은 장면을 다시 그려 비교할 때만 쓴다). height_profile 참조:
## 0=실제 기록값, 1=v2(2.6), 2=강도 1 정점, 3=보통 강도 0.6(새 기본값), 4=v3(3.3, 상한 36px).
var debug_height_mode: int = 0

var _skid: DriftSkid = null
var _tex: Texture2D = null
var _now: float = 0.0
var _ppos: Vector2 = Vector2.ZERO
var _heading: float = 0.0
## 슬롯: {"surf": RID, "shad": RID, "smat": ShaderMaterial, "hmat": ShaderMaterial, "rec": Dictionary,
## "order": int}. rec가 빈 Dictionary면 빈 슬롯이다.
var _slots: Array = []
var _stats: Dictionary = {"active": 0, "candidates": 0, "uploads": 0, "usec": 0, "params": 0}
var _param_calls: int = 0


## PresentationController가 _ready에서 1회 연결한다(데이터 소스 + 바닥 SubViewport 텍스처).
func setup(skid: DriftSkid, source_tex: Texture2D) -> void:
	_skid = skid
	_tex = source_tex
	DriftFoldShape.ensure()
	_register_globals()
	if _slots.is_empty():
		_create_slots()


## 전역 uniform을 등록한다(프로세스에서 처음 한 번). 셰이더가 컴파일되기 전에 있어야 하므로 셰이더는
## 이 뒤에 load한다. 등록 여부는 정적 플래그로만 판단한다(global_shader_parameter_get_list/get은 에디터
## 전용이라 런타임에 오류를 남긴다). 전역 uniform은 프로세스 수명 동안 유지되므로 재시작해도 다시 등록하지 않는다.
static func _register_globals() -> void:
	if _globals_ready:
		return
	RenderingServer.global_shader_parameter_add(
		G_PLAYER, RenderingServer.GLOBAL_VAR_TYPE_VEC2, Vector2.ZERO
	)
	RenderingServer.global_shader_parameter_add(G_HEADING, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RenderingServer.global_shader_parameter_add(G_NOW, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	_globals_ready = true


func _create_slots() -> void:
	var parent: RID = get_canvas_item()
	var big: Rect2 = Rect2(-100000.0, -100000.0, 200000.0, 200000.0)
	for i in range(MAX_ACTIVE):
		var slot: Dictionary = {"rec": {}, "order": -1}
		for key in ["shad", "surf"]:
			var item: RID = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(item, parent)
			# 정점은 월드 좌표라 엔진의 사각형 컬링이 틀린다. 컬링을 끄고 화면 판정은 _select가 한다.
			RenderingServer.canvas_item_set_custom_rect(item, true, big)
			RenderingServer.canvas_item_set_visible(item, false)
			var mat: ShaderMaterial = _make_material(key == "shad")
			RenderingServer.canvas_item_set_material(item, mat.get_rid())
			slot[key] = item
			slot["hmat" if key == "shad" else "smat"] = mat
		_slots.append(slot)


func _make_material(shadow: bool) -> ShaderMaterial:
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = load(SHADER_PATH)
	mat.set_shader_parameter("shadow_pass", shadow)
	mat.set_shader_parameter("screen_size", get_viewport_rect().size)
	mat.set_shader_parameter("t_rise", DriftFoldShape.RISE)
	mat.set_shader_parameter("t_relax", DriftFoldShape.RELAX)
	mat.set_shader_parameter("residue", DriftFoldShape.RESIDUE)
	mat.set_shader_parameter("t_residue_fade", DriftFoldShape.RESIDUE_FADE)
	mat.set_shader_parameter("relax_spread_max", RELAX_SPREAD)
	mat.set_shader_parameter("shadow_len", SHADOW_LEN)
	mat.set_shader_parameter("source_tex", _tex)
	mat.set_shader_parameter("horizon", PresentationController.HORIZON)
	mat.set_shader_parameter("depth_scale", PresentationController.DEPTH_SCALE)
	mat.set_shader_parameter("cam_back", PresentationController.CAM_BACK)
	mat.set_shader_parameter("spread", PresentationController.SPREAD)
	mat.set_shader_parameter("coverage", PresentationController.COVERAGE)
	mat.set_shader_parameter("cam_height", CAM_HEIGHT)
	mat.set_shader_parameter("near_clip", NEAR_CLIP)
	mat.set_shader_parameter("light", LIGHT)
	mat.set_shader_parameter("light_gain", LIGHT_GAIN)
	mat.set_shader_parameter("ao_gain", AO_GAIN)
	mat.set_shader_parameter("crest_gain", CREST_GAIN)
	mat.set_shader_parameter("lum_min", LUM_MIN)
	mat.set_shader_parameter("lum_max", LUM_MAX)
	mat.set_shader_parameter("shadow_alpha", SHADOW_ALPHA)
	mat.set_shader_parameter("max_lift_px", MAX_LIFT_PX)
	mat.set_shader_parameter("near_fade_lo", NEAR_FADE_LO)
	mat.set_shader_parameter("near_fade_hi", NEAR_FADE_HI)
	return mat


func _exit_tree() -> void:
	for slot in _slots:
		RenderingServer.free_rid(slot["surf"])
		RenderingServer.free_rid(slot["shad"])
	_slots.clear()


## 매 프레임 표현 시각과 카메라(플레이어 위치·진행각)를 받아 슬롯을 갱신한다.
func update_view(now: float, ppos: Vector2, heading: float) -> void:
	_now = now
	_ppos = ppos
	_heading = heading
	var t0: int = Time.get_ticks_usec()
	_param_calls = 0
	# 전 슬롯 공통 값은 전역 uniform 세 개로 한 번만 바꾼다(높이 진행은 셰이더가 시각으로 계산).
	RenderingServer.global_shader_parameter_set(G_PLAYER, ppos)
	RenderingServer.global_shader_parameter_set(G_HEADING, heading)
	RenderingServer.global_shader_parameter_set(G_NOW, now)
	_param_calls += 3
	var picks: Array = []
	var cand: int = 0
	if enabled and _skid != null and _tex != null and DriftFoldShape.is_ready():
		picks = _select(get_viewport_rect().size, Vector2(cos(heading), sin(heading)))
		cand = int(picks.pop_back())
	var uploads: int = _assign(picks)
	_stats = {
		"active": picks.size(),
		"candidates": cand,
		"uploads": uploads,
		"usec": Time.get_ticks_usec() - t0,
		"params": _param_calls,
	}


## 마지막 프레임 통계: active(그린 패치), candidates(높이>0 후보), uploads(정점을 새로 올린 슬롯 수),
## usec(선택·업로드·uniform 갱신 CPU 시간), params(셰이더 파라미터·전역 uniform 설정 호출 수).
func last_stats() -> Dictionary:
	return _stats


## 지금 슬롯에 들어 있는 패치 레코드.
func active_records() -> Array:
	var out: Array = []
	for slot in _slots:
		if not (slot["rec"] as Dictionary).is_empty():
			out.append(slot["rec"])
	return out


## 1280×720 캔버스, 깊이 depth에서 높이 1 단위가 솟는 픽셀 수.
static func lift_px_per_unit(depth: float, screen: Vector2) -> float:
	var dsc: float = PresentationController.DEPTH_SCALE
	return dsc * screen.y / (CAM_HEIGHT * maxf(depth, NEAR_CLIP))


## 월드 점(높이 z)을 화면 좌표로 투영한다. 반환 (x, y, depth). depth는 클램프 전 값이다.
## drift_fold.gdshader vertex()와 같은 식이다(회귀 검사가 바닥 셰이더 역식과 비교한다).
static func project(
	world: Vector2, z: float, ppos: Vector2, heading: float, screen: Vector2
) -> Vector3:
	var fwd: Vector2 = Vector2(cos(heading), sin(heading))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	var d: Vector2 = world - ppos
	var depth: float = d.dot(fwd) + PresentationController.CAM_BACK
	var inv: float = 1.0 / maxf(depth, NEAR_CLIP)
	var x: float = (0.5 + d.dot(rgt) * inv / PresentationController.SPREAD) * screen.x
	var y: float = (
		(
			PresentationController.HORIZON
			+ PresentationController.DEPTH_SCALE * (1.0 - z / CAM_HEIGHT) * inv
		)
		* screen.y
	)
	return Vector3(x, y, depth)


## 화면 점(캔버스 좌표)을 바닥 월드 좌표로 역투영한다(project의 z=0 역식 = Mode 7 바닥 셰이더 식).
## 수평선 위·바로 아래처럼 깊이가 무한히 커지는 점은 depth_max로 자른다.
static func screen_to_world(
	sp: Vector2, ppos: Vector2, heading: float, screen: Vector2, depth_max: float = 600.0
) -> Vector2:
	var fwd: Vector2 = Vector2(cos(heading), sin(heading))
	var rgt: Vector2 = Vector2(-fwd.y, fwd.x)
	var dy: float = sp.y / screen.y - PresentationController.HORIZON
	var depth: float = depth_max
	if dy > PresentationController.DEPTH_SCALE / depth_max:
		depth = PresentationController.DEPTH_SCALE / dy
	var lateral: float = (sp.x / screen.x - 0.5) * depth * PresentationController.SPREAD
	return ppos + fwd * (depth - PresentationController.CAM_BACK) + rgt * lateral


## 패치의 지금 표면 정점 화면 좌표(셰이더와 같은 계산, 회귀 검사·클리핑 확인용).
func debug_project_patch(rec: Dictionary, screen: Vector2) -> PackedVector2Array:
	var a01: float = DriftFoldShape.amp01(float(rec["born"]), float(rec["relax"]), _now)
	var amp: float = float(rec["amp"]) * a01
	var world: PackedVector2Array = patch_world_grid(rec)
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(world.size())
	var spread: float = relax_spread(rec, _now)
	var mid_k: int = (rec["c"] as PackedVector2Array).size() / 2
	var base: Vector2 = (rec["c"] as PackedVector2Array)[mid_k]
	var nrm: Vector2 = (rec["n"] as PackedVector2Array)[mid_k]
	var mid: float = float(rec["off"]) + float(rec["w"]) * 0.5
	for k in range(world.size()):
		var lat: float = (world[k] - base).dot(nrm)
		var wp: Vector2 = world[k] + nrm * ((lat - mid) * (spread - 1.0))
		var z: float = capped_amp(amp, wp, _ppos, _heading, lift_cap(rec)) * DriftFoldShape.grid_h[k]
		var pr: Vector3 = project(wp, z, _ppos, _heading, screen)
		out[k] = Vector2(pr.x, pr.y)
	return out


## 완화 진행에 따른 측방 퍼짐 배율(1 → 1+RELAX_SPREAD, 셰이더 relax_spread_k uniform).
static func relax_spread(rec: Dictionary, now: float) -> float:
	var since: float = now - float(rec["relax"])
	return 1.0 + RELAX_SPREAD * smoothstep(0.0, DriftFoldShape.RELAX, since)


## 정점 깊이에서 화면 솟음이 MAX_LIFT_PX를 넘지 않도록 낮춘 패치 높이(셰이더 a_eff와 같은 식).
static func capped_amp(
	amp: float, world: Vector2, ppos: Vector2, heading: float, cap_px: float = MAX_LIFT_PX
) -> float:
	var fwd: Vector2 = Vector2(cos(heading), sin(heading))
	var depth: float = (world - ppos).dot(fwd) + PresentationController.CAM_BACK
	var near_k: float = smoothstep(NEAR_FADE_LO, NEAR_FADE_HI, depth)
	return minf(amp, cap_px / lift_px_per_unit(depth, Vector2(1280.0, 720.0))) * near_k


## 패치의 화면 솟음 상한(px, 강도별).
static func lift_cap(rec: Dictionary) -> float:
	return (
		LIFT_CAP_BASE
		+ LIFT_CAP_GAIN * clampf(float(rec["intensity"]), 0.0, 1.0)
		+ float(rec.get("lift_bonus", 0.0))
	)


## 패치 격자 정점의 바닥 월드 좌표((NU+1)×(NV+1), 행 = 뒤→앞).
static func patch_world_grid(rec: Dictionary) -> PackedVector2Array:
	var cs: PackedVector2Array = rec["c"]
	var ns: PackedVector2Array = rec["n"]
	var off: float = float(rec["off"])
	var w: float = float(rec["w"])
	var nu: int = DriftFoldShape.NU
	var out: PackedVector2Array = PackedVector2Array()
	out.resize((nu + 1) * cs.size())
	for j in range(cs.size()):
		for i in range(nu + 1):
			out[j * (nu + 1) + i] = cs[j] + ns[j] * (off + w * float(i) / float(nu))
	return out


## 높이가 남아 있는 최근 패치 중 화면에서 보이는 것을 골라 MAX_ACTIVE개까지, 먼 것부터 정렬한다.
## 반환 원소 {"rec","a01","depth","lift"}, 배열의 마지막 원소는 후보 수(int)다.
func _select(screen: Vector2, fwd: Vector2) -> Array:
	var near: Array = _skid.get_near_folds()
	var cands: Array = []
	var count: int = 0
	var scan: Array = []
	var live: Dictionary = _skid.get_live_fold()
	if not live.is_empty():
		scan.append(live)
	for i in range(near.size() - 1, maxi(near.size() - 1 - SCAN_MAX, -1), -1):
		scan.append(near[i])
	for rec in scan:
		var born: float = float(rec["born"])
		var a01: float = DriftFoldShape.amp01(born, float(rec["relax"]), _now)
		if a01 <= 0.0:
			continue
		count += 1
		var d: Vector2 = Vector2(rec["pos"]) - _ppos
		if d.length() > MAX_DIST:
			continue
		var depth: float = d.dot(fwd) + PresentationController.CAM_BACK
		if depth > FAR_DEPTH:
			continue
		var lift: float = minf(
			float(rec["amp"]) * a01 * lift_px_per_unit(maxf(depth, 48.0), screen), lift_cap(rec)
		)
		if lift < MIN_LIFT_PX or not _on_screen(rec, screen, lift):
			continue
		cands.append({"rec": rec, "a01": a01, "depth": depth, "lift": lift})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["lift"] > b["lift"])
	if cands.size() > MAX_ACTIVE:
		cands.resize(MAX_ACTIVE)
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] > b["depth"])
	cands.append(count)
	return cands


## 패치 가장자리(행별 안쪽·바깥 점)의 바닥 투영(+최대 솟음)이 화면과 겹치는가. 휜 패치도 놓치지 않도록
## 네 모서리만이 아니라 세 행마다 안쪽·바깥 점을 본다.
func _on_screen(rec: Dictionary, screen: Vector2, lift: float) -> bool:
	var cs: PackedVector2Array = rec["c"]
	var ns: PackedVector2Array = rec["n"]
	var off: float = float(rec["off"])
	var w: float = float(rec["w"])
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = Vector2(-INF, -INF)
	var k: int = 0
	while k < cs.size():
		for lat in [off, off + w]:
			var pr: Vector3 = project(cs[k] + ns[k] * lat, 0.0, _ppos, _heading, screen)
			mn = mn.min(Vector2(pr.x, pr.y))
			mx = mx.max(Vector2(pr.x, pr.y))
		k = mini(k + 3, cs.size() - 1) if k < cs.size() - 1 else cs.size()
	var margin: float = lift * 4.0 + 8.0
	return (
		mx.x >= -margin
		and mn.x <= screen.x + margin
		and mx.y >= -margin
		and mn.y <= screen.y + margin
	)


## 고른 패치를 슬롯에 배정한다. 이미 슬롯에 있는 패치는 그대로 두고(셀 순서가 바뀌면 다시 올림),
## 새 패치만 빈 슬롯에 올린다. 그리기 순서·uniform을 갱신하고 남는 슬롯은 숨긴다. 반환: 업로드 수.
func _assign(picks: Array) -> int:
	var fwd: Vector2 = Vector2(cos(_heading), sin(_heading))
	var used: Dictionary = {}
	var slot_of: Array = []
	slot_of.resize(picks.size())
	for p in range(picks.size()):
		var rec: Dictionary = picks[p]["rec"]
		for s in range(_slots.size()):
			if not used.has(s) and is_same(_slots[s]["rec"], rec):
				used[s] = true
				slot_of[p] = s
				break
	for p in range(picks.size()):
		if slot_of[p] != null:
			continue
		for s in range(_slots.size()):
			if not used.has(s):
				used[s] = true
				slot_of[p] = s
				_slots[s]["rec"] = picks[p]["rec"]
				_slots[s]["order"] = -1
				_slots[s]["relax"] = NAN
				break
	for s in range(_slots.size()):
		if used.has(s):
			continue
		if not (_slots[s]["rec"] as Dictionary).is_empty() or bool(_slots[s].get("shown", false)):
			_slots[s]["rec"] = {}
			_slots[s]["shown"] = false
			_slots[s]["draw"] = -1
			RenderingServer.canvas_item_set_visible(_slots[s]["surf"], false)
			RenderingServer.canvas_item_set_visible(_slots[s]["shad"], false)
	var uploads: int = 0
	for p in range(picks.size()):
		var slot: Dictionary = _slots[slot_of[p]]
		var rec: Dictionary = slot["rec"]
		var order: int = _far_first_order(rec, fwd)
		if order != int(slot["order"]):
			_upload(slot, rec, order)
			uploads += 1
		_update_slot(slot, p)
	return uploads


## 패치 정점(바닥 월드 좌표 + 형태 데이터)을 슬롯의 두 아이템에 올린다. 정점 배열은 레코드에 한 번
## 만들어 두고(셀 순서만 바뀌면 인덱스만 바꿔 다시 올린다) 재사용한다.
func _upload(slot: Dictionary, rec: Dictionary, order: int) -> void:
	if not rec.has("gpu"):
		rec["gpu"] = _vertex_data(rec)
	var data: Array = rec["gpu"]
	var idx: PackedInt32Array = DriftFoldShape.grid_indices(
		DriftFoldShape.NU, DriftFoldShape.NV, order
	)
	for key in ["shad", "surf"]:
		var item: RID = slot[key]
		RenderingServer.canvas_item_clear(item)
		RenderingServer.canvas_item_add_triangle_array(item, idx, data[0], data[1], data[2])
	slot["order"] = order


## 정점 데이터 [월드 좌표, 색(기울기 x·y, 알파, 그림자), UV(높이, 차폐)].
func _vertex_data(rec: Dictionary) -> Array:
	var nu: int = DriftFoldShape.NU
	var nv: int = DriftFoldShape.NV
	var pts: PackedVector2Array = patch_world_grid(rec)
	var n: int = pts.size()
	var uvs: PackedVector2Array = PackedVector2Array()
	var cols: PackedColorArray = PackedColorArray()
	uvs.resize(n)
	cols.resize(n)
	var ns: PackedVector2Array = rec["n"]
	var cs: PackedVector2Array = rec["c"]
	var w: float = maxf(float(rec["w"]), 0.001)
	var length: float = maxf(float(rec["len"]), 1.0)
	var gh: PackedFloat32Array = DriftFoldShape.grid_h
	var ghu: PackedFloat32Array = DriftFoldShape.grid_hu
	var ghv: PackedFloat32Array = DriftFoldShape.grid_hv
	var gao: PackedFloat32Array = DriftFoldShape.grid_ao
	var gsh: PackedFloat32Array = DriftFoldShape.grid_sh
	var ga: PackedFloat32Array = DriftFoldShape.grid_a
	var inv_range: float = 0.5 / GRAD_RANGE
	for j in range(nv + 1):
		var nn: Vector2 = ns[j]
		var t: Vector2 = (cs[mini(j + 1, nv)] - cs[maxi(j - 1, 0)]).normalized()
		for i in range(nu + 1):
			var k: int = j * (nu + 1) + i
			# 높이 1 단위당 월드 기울기(밀린 방향 성분 + 진행 방향 성분).
			var g: Vector2 = nn * (ghu[k] / w) + t * (ghv[k] / length)
			uvs[k] = Vector2(gh[k], gao[k])
			cols[k] = Color(
				clampf(0.5 + g.x * inv_range, 0.0, 1.0),
				clampf(0.5 + g.y * inv_range, 0.0, 1.0),
				ga[k],
				gsh[k]
			)
	return [pts, cols, uvs]


## 슬롯 그리기 순서(그림자 먼저, 표면은 먼 것부터)와 패치 상수를 바뀐 것만 갱신한다. 패치 상수는 슬롯에
## 올릴 때 한 번, relax(완화 시작 시각)가 당겨졌을 때와 검증용 평면 모드가 바뀌었을 때만 다시 설정한다.
func _update_slot(slot: Dictionary, draw_pos: int) -> void:
	var rec: Dictionary = slot["rec"]
	if int(slot.get("draw", -1)) != draw_pos:
		RenderingServer.canvas_item_set_draw_index(slot["shad"], draw_pos)
		RenderingServer.canvas_item_set_draw_index(slot["surf"], MAX_ACTIVE + draw_pos)
		slot["draw"] = draw_pos
	var relax: float = float(rec["relax"])
	var fresh: bool = is_nan(float(slot.get("relax", NAN)))
	if fresh:
		var mid: float = float(rec["off"]) + float(rec["w"]) * 0.5
		# 완화 퍼짐의 측방 기준: 패치 가운데 행(휜 패치에서도 가운데 부근이 정확하다).
		var mk: int = (rec["c"] as PackedVector2Array).size() / 2
		for key in ["hmat", "smat"]:
			_set_param(slot[key], "patch_base", (rec["c"] as PackedVector2Array)[mk])
			_set_param(slot[key], "patch_n", (rec["n"] as PackedVector2Array)[mk])
			_set_param(slot[key], "patch_mid", mid)
			_set_param(slot[key], "patch_born", float(rec["born"]))
	if fresh or float(slot["relax"]) != relax:
		for key in ["hmat", "smat"]:
			_set_param(slot[key], "patch_relax", relax)
		slot["relax"] = relax
	if fresh or int(slot.get("hmode", -1)) != debug_height_mode:
		var prof: Array = height_profile(rec, debug_height_mode)
		for key in ["hmat", "smat"]:
			_set_param(slot[key], "patch_amp", prof[0])
			_set_param(slot[key], "max_lift_px", prof[1])
			_set_param(slot[key], "light_gain", prof[2])
			_set_param(slot[key], "ao_gain", prof[3])
		slot["hmode"] = debug_height_mode
	if bool(slot.get("flat", false)) != debug_flat or fresh:
		for key in ["hmat", "smat"]:
			_set_param(slot[key], "force_flat", debug_flat)
		slot["flat"] = debug_flat
	if not bool(slot.get("shown", false)):
		RenderingServer.canvas_item_set_visible(slot["shad"], true)
		RenderingServer.canvas_item_set_visible(slot["surf"], true)
		slot["shown"] = true


## 높이 비교 모드별 [패치 최대 높이, 화면 솟음 상한 px, LIGHT_GAIN, AO_GAIN].
## 0=실제 기록값, 1=v2(2.6×(0.6+0.4i), 26px), 2=강도 1 정점, 3=보통 강도 0.6, 4=v3(3.3×(0.7+0.5i), 36px).
static func height_profile(rec: Dictionary, mode: int) -> Array:
	var var_k: float = float(rec.get("amp_var", 1.0))
	var i: float = float(rec["intensity"])
	var h0: float = DriftSkid.FOLD_HEIGHT
	match mode:
		1:
			return [2.6 * (0.6 + 0.4 * i) * var_k, 26.0, 1.1, 0.55]
		2:
			var peak: float = h0 * (DriftSkid.AMP_BASE + DriftSkid.AMP_GAIN) * var_k
			return [peak, LIFT_CAP_BASE + LIFT_CAP_GAIN, LIGHT_GAIN, AO_GAIN]
		3:
			var base: float = h0 * (DriftSkid.AMP_BASE + DriftSkid.AMP_GAIN * 0.6) * var_k
			return [base, LIFT_CAP_BASE + LIFT_CAP_GAIN * 0.6, LIGHT_GAIN, AO_GAIN]
		4:
			return [3.3 * (0.70 + 0.50 * i) * var_k, 36.0, 0.95, 0.5]
	return [float(rec["amp"]), lift_cap(rec), LIGHT_GAIN, AO_GAIN]


func _set_param(mat: ShaderMaterial, param: StringName, value: Variant) -> void:
	mat.set_shader_parameter(param, value)
	_param_calls += 1


## 카메라에서 먼 셀부터 그리는 인덱스 순서(DriftFoldShape.grid_indices의 order 비트).
## 측방(u)·접선(v) 중 깊이 변화가 큰 축을 바깥 루프로, 각 축은 깊이가 큰 쪽에서 시작한다.
static func _far_first_order(rec: Dictionary, fwd: Vector2) -> int:
	var cs: PackedVector2Array = rec["c"]
	var ns: PackedVector2Array = rec["n"]
	var mid: int = cs.size() / 2
	var du: float = (ns[mid] * float(rec["w"])).dot(fwd)
	var dv: float = (cs[cs.size() - 1] - cs[0]).dot(fwd)
	var order: int = 0
	if du > 0.0:
		order |= 1
	if dv > 0.0:
		order |= 2
	if absf(dv) > absf(du):
		order |= 4
	return order
