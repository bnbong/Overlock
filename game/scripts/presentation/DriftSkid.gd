class_name DriftSkid
extends Node2D
## 드리프트 원단 주름 데이터 + 바닥 잔여 흔적 (presentation.md §15). SubViewport 안 월드 공간.
##
## 피벗 드리프트 중 손바닥에 밀린 원단이 드리프트 방향(누르는 손 쪽)으로 모여 솟는 주름의 "데이터
## 소스"다. 주름 한 묶음(패치)의 바닥 위치·진행 방향·밀린 방향·강도·생성 시각을 기록하고, 입체 렌더는
## 화면 공간의 DriftFoldLayer(FabricLayer 안)가 Mode 7과 같은 카메라로 투영해 그린다. 이 노드 자신은
## Mode 7 소스(바닥 텍스처)에 낮은 잔여 흔적(음영 메시)만 칠한다. 그래서 솟은 표면이 바닥 텍스처를
## 다시 샘플해도 피드백이 생기지 않는다(솟은 레이어는 바닥 SubViewport에 합성하지 않는다).
##
## 물리 루프와 무결합: PresentationController가 주행 중(RUNNING)이고 player.is_drifting일 때만
## push(pos, drift_dir, |drift_dir|, 표현 시각, heading)를 호출하고, 드리프트 종료·강제 복귀·순간이동·
## 완주에서 end_stroke를 호출한다. 변형은 이 노드 전용 RNG(고정 시드)만 쓴다(전역 난수열·시뮬 불변).
##
## 패치 모양: 바늘 위치에서 그 순간의 진행 방향 뒤쪽(-FOLD_AHEAD ~ FOLD_LEN)에 곧게 놓인 띠를, 재봉선에서
## FLAT_HALF 떨어진 곳부터 밀린 쪽으로 FOLD_WIDTH만큼 펼친다. 화면에서 노루발 뒤, 재봉선과 누르는 손
## 안쪽 가장자리 사이에서 근경으로 이어지는 자리다. 생성 순간에 그 자리에 놓이고,
## 이후에는 바닥(월드)에 고정되어 원단과 함께 근경으로 흘러가며 완화된다. 이 게임의 피벗 드리프트는
## 반경이 20~30px로 매우 작아서, 지나온 곡선 경로를 따라 휘게 만들면 패치가 회전 중심(누르는 손 바로
## 아래)으로 몰려 화면에서 보이지 않는다(캡처로 확인). 그래서 경로 대신 진행 방향을 쓴다.
##
## 스트로크: 같은 방향으로 이어진 한 번의 드리프트. 방향 부호가 바뀌거나(반전) 샘플 간격이
## STROKE_JUMP를 넘으면(순간이동) 자동으로 끊고 새 스트로크를 시작한다. 패치는 스트로크 시작에 하나,
## 이후 경로 FOLD_SPACING마다 하나씩 생긴다. 서로 다른 스트로크를 잇는 패치는 만들지 않으므로 멀리
## 떨어진 두 드리프트 구간이 능선으로 이어지지 않는다.
##
## 버퍼: 근경 링(_near, MAX_SKIDS)은 잔여 흔적과 입체 패치 후보, 완주용(_full, MAX_FULL_SKIDS)은
## 줌아웃 전체 자국이다. full이 상한을 넘으면 공간 데시메이션(짝수 인덱스만 유지)으로 전체 span을
## 보존하며 밀도만 낮춘다. 두 버퍼는 같은 레코드(Dictionary) 객체를 공유한다.
##
## 레코드 키(get_full_marks 소비자 공통):
##   "pos"(패치 중심 바닥 좌표), "dir"(side×intensity, 부호=밀린 방향), "intensity"(0..1),
##   "tan"(진행 방향 단위벡터), "side"(±1, +1=진행 방향 오른쪽), "c"/"n"(뒤→앞 정점 행별 기준점·밀린
##   방향 법선, DriftFoldShape.NV+1개), "off"/"w"(기준선에서 패치 안쪽 가장자리까지 거리·측방 폭),
##   "len"(접선 길이), "amp"(최대 높이, 월드 단위), "amp_var"(표현 전용 RNG 높이 변형 배율),
##   "born"/"relax"(표현 시각),
##   "stroke"(스트로크 번호), "rv"/"ru"(잔여 흔적 메시 정점·UV, 월드 좌표).

const SKID_SPACING: float = 8.0  # 경로 샘플 이동 게이트(px)
const MAX_SKIDS: int = 120  # 근경 링 상한(패치 레코드 수)
const MAX_FULL_SKIDS: int = 400  # 줌아웃용 full 버퍼 상한(초과 시 공간 데시메이션)

## 이 값보다 작은 |drift_dir|은 방향이 없는 드리프트로 보고 기록하지 않으며, 진행 중인 스트로크를 끊는다.
const DIR_MIN: float = 0.06
## 연속 샘플 간격이 이보다 크면 순간이동으로 보고 스트로크를 끊는다(px).
const STROKE_JUMP: float = 48.0
## 패치 길이: 바늘 뒤로 FOLD_LEN, 앞으로 FOLD_AHEAD(px). 경로 FOLD_SPACING(px)마다 새 패치.
const FOLD_LEN: float = 70.0
const FOLD_AHEAD: float = -20.0
const FOLD_SPACING: float = 26.0
## 회전 앞당김: 패치 방향을 회전 속도 × FOLD_LEAD(초)만큼 미리 돌린다(최대 FOLD_LEAD_MAX rad).
## FOLD_LEAD는 솟음 + 유지의 절반 정도(패치가 가장 높을 때 화면 바늘 뒤에 오도록).
const FOLD_LEAD: float = 0.28
const FOLD_LEAD_MAX: float = 1.0
## 재봉선(바늘이 지나는 진행선)에서 패치 안쪽 가장자리까지의 평평한 구간 반폭(px). 바늘 접촉점과
## 스티치가 주름에 묻히지 않게 한다.
const FLAT_HALF: float = 2.5
## 패치 측방 폭(px, intensity=1).
const FOLD_WIDTH: float = 8.5
## 최대 주름 높이(월드 단위, intensity=1). 1280×720 플레이어 행(depth=CAM_BACK)에서 1 단위가
## 약 10px로 솟는다(DriftFoldLayer.lift_px_per_unit). 컨셉보다 낮게 잡았다.
const FOLD_HEIGHT: float = 3.3
## 강도별 높이 계수: FOLD_HEIGHT × (AMP_BASE + AMP_GAIN × 강도). 보통 드리프트(강도 약 0.6)가 FOLD_HEIGHT,
## 강도 1(강한 드리프트 정점)이 약 3.96이 된다.
const AMP_BASE: float = 0.70
const AMP_GAIN: float = 0.50
## 잔여 흔적 메시 해상도(셀)와 알파. 행 수는 DriftFoldShape.NV의 약수여야 한다.
const RES_U: int = 6
const RES_V: int = 4
const RESIDUE_ALPHA: float = 0.42
const RESIDUE_FADE_IN: float = 0.25
## 표현 전용 RNG 시드(같은 주행이면 같은 주름 변형).
const RNG_SEED: int = 0x0F01D

var _near: Array = []
var _full: Array = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _now: float = 0.0
var _fade_until: float = -1.0
var _stroke_id: int = 0
var _stroke_on: bool = false
var _side: float = 0.0
var _intensity: float = 0.0
var _last: Vector2 = Vector2.ZERO
var _tan: Vector2 = Vector2.RIGHT
var _since: float = 0.0
var _yaw_rate: float = 0.0
var _tan_time: float = 0.0


func _ready() -> void:
	_rng.seed = RNG_SEED
	DriftFoldShape.ensure()


## PresentationController가 드리프트 중 매 프레임 호출. dir=drift_dir(-1..1, 부호=밀린 방향),
## intensity=|drift_dir|, now=주행 표현 시각(초, 일시정지에서 멈춤. 음수면 마지막 시각),
## heading=진행각(rad, NAN이면 샘플 이동 방향). SKID_SPACING 이상 이동했을 때만 샘플을 남긴다.
func push(
	pos: Vector2, dir: float, intensity: float, now: float = -1.0, heading: float = NAN
) -> void:
	if now >= 0.0:
		_now = now
	if absf(dir) < DIR_MIN:
		# 드리프트를 유지한 채 조향을 중립으로 돌리면 누름이 끝난 것으로 보고 스트로크를 끊는다.
		# 다시 조향하면 새 스트로크로 시작하고, 중립 구간 이동은 패치 간격에 합산하지 않는다.
		if _stroke_on:
			end_stroke()
		return
	var s: float = signf(dir)
	var gap: float = 0.0
	if _stroke_on:
		gap = _last.distance_to(pos)
		if s != _side or gap > STROKE_JUMP:
			end_stroke()
		elif gap < SKID_SPACING:
			return
	_intensity = clampf(intensity, 0.0, 1.0)
	var prev_tan: Vector2 = _tan
	if not is_nan(heading):
		_tan = Vector2(cos(heading), sin(heading))
	elif gap > 0.0001:
		_tan = (pos - _last) / gap
	# 회전 속도(rad/s, +는 오른쪽 회전). 스트로크 안에서만 샘플 간 진행 방향 변화로 추정한다.
	if _stroke_on and _now > _tan_time + 0.0001:
		var w_now: float = prev_tan.angle_to(_tan) / (_now - _tan_time)
		_yaw_rate = lerpf(_yaw_rate, w_now, 0.5)
	_tan_time = _now
	if not _stroke_on:
		_begin_stroke(pos, s)
		_emit()
		return
	_last = pos
	_since += gap
	if _since >= FOLD_SPACING:
		# 남는 거리를 이월해 샘플 간격(SKID_SPACING)과 무관하게 평균 FOLD_SPACING마다 생기게 한다.
		_since -= FOLD_SPACING
		_emit()


## 현재 스트로크를 끝낸다(드리프트 종료·조향 중립·강제 복귀·순간이동·완주). 이 스트로크의 패치는 지금부터
## 완화하고(솟는 중이었다면 지금 높이에서 멈춰 낮아진다), 다음 push는 새 스트로크로 시작한다. 종료 시점에
## 새 패치를 만들지 않는다(만들어도 솟지 않으므로 의미가 없다).
func end_stroke(now: float = -1.0) -> void:
	if now >= 0.0:
		_now = now
	if not _stroke_on:
		return
	_since = 0.0
	for i in range(_near.size() - 1, -1, -1):
		var rec: Dictionary = _near[i]
		if int(rec["stroke"]) != _stroke_id:
			break
		rec["relax"] = minf(float(rec["relax"]), _now)
	_stroke_on = false


## 매 프레임 표현 시각을 전달한다. 잔여 흔적이 서서히 나타나는 동안만 다시 그린다.
func tick(now: float) -> void:
	_now = now
	if _fade_until >= 0.0:
		queue_redraw()
		if _now >= _fade_until:
			_fade_until = -1.0


## 완주 줌아웃 연출(FinishView)이 읽는 전체 자국(위 레코드 키 참조).
func get_full_marks() -> Array:
	return _full


## 입체 주름 후보(근경 링, 오래된 것부터). DriftFoldLayer가 최근 것부터 거꾸로 읽는다.
func get_near_folds() -> Array:
	return _near


func current_time() -> float:
	return _now


func stroke_id() -> int:
	return _stroke_id


func is_stroke_active() -> bool:
	return _stroke_on


## 자국과 스트로크 상태를 모두 비운다. 재시작은 씬 재로드(_ready 재실행)로 자동 초기화되지만,
## 재로드 없이 비워야 하는 경로를 위해 명시 API로도 노출한다.
func clear() -> void:
	_near.clear()
	_full.clear()
	_stroke_on = false
	_since = 0.0
	_fade_until = -1.0
	queue_redraw()


func _begin_stroke(pos: Vector2, s: float) -> void:
	_stroke_id += 1
	_stroke_on = true
	_side = s
	_last = pos
	_since = 0.0
	_yaw_rate = 0.0


## 지금 바늘 위치(_last)에서 곧은 패치 하나를 만든다. 방향은 지금 진행 방향을 회전 속도 × FOLD_LEAD만큼
## 앞당긴 값이다. 피벗 드리프트에서는 화면이 빠르게 돌아 바닥에 고정된 패치가 솟기도 전에 누르는 손
## 아래로 돌아 들어가므로, 솟아 있는 동안 화면에서 바늘 뒤(손과 재봉선 사이)에 오도록 미리 돌려 둔다.
## 패치는 생성 뒤 바닥에 고정되므로 천 무늬가 미끄러지지 않는다.
func _emit() -> void:
	var nv: int = DriftFoldShape.NV
	var lead: float = clampf(_yaw_rate * FOLD_LEAD, -FOLD_LEAD_MAX, FOLD_LEAD_MAX)
	var axis: Vector2 = _tan.rotated(lead)
	var nrm: Vector2 = Vector2(-axis.y, axis.x) * _side
	var back: Vector2 = _last - axis * FOLD_LEN
	var front: Vector2 = _last + axis * FOLD_AHEAD
	var cs: PackedVector2Array = PackedVector2Array()
	var ns: PackedVector2Array = PackedVector2Array()
	cs.resize(nv + 1)
	ns.resize(nv + 1)
	for k in range(nv + 1):
		cs[k] = back.lerp(front, float(k) / float(nv))
		ns[k] = nrm
	var w: float = FOLD_WIDTH * (0.8 + 0.2 * _intensity)
	var var_k: float = _rng.randf_range(0.9, 1.1)
	var mid: int = nv / 2
	var rec: Dictionary = {
		"pos": cs[mid] + nrm * (FLAT_HALF + w * 0.5),
		"dir": _side * _intensity,
		"intensity": _intensity,
		"tan": axis,
		"side": _side,
		"c": cs,
		"n": ns,
		"off": FLAT_HALF,
		"w": w,
		"len": FOLD_LEN + FOLD_AHEAD,
		"amp": FOLD_HEIGHT * (AMP_BASE + AMP_GAIN * _intensity) * var_k,
		"amp_var": var_k,
		"born": _now,
		"relax": _now + DriftFoldShape.HOLD,
		"stroke": _stroke_id,
	}
	_build_residue(rec)
	_near.append(rec)
	if _near.size() > MAX_SKIDS:
		_near.remove_at(0)
	_full.append(rec)
	if _full.size() > MAX_FULL_SKIDS:
		_decimate_full()
	_fade_until = _now + RESIDUE_FADE_IN
	queue_redraw()


## 잔여 흔적 메시(RES_U×RES_V 셀, 월드 좌표)와 텍스처 UV를 미리 만들어 둔다.
func _build_residue(rec: Dictionary) -> void:
	var cs: PackedVector2Array = rec["c"]
	var ns: PackedVector2Array = rec["n"]
	var off: float = float(rec["off"])
	var w: float = float(rec["w"])
	var step: int = DriftFoldShape.NV / RES_V
	var pts: PackedVector2Array = PackedVector2Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	for jj in range(RES_V + 1):
		var j: int = jj * step
		var v: float = float(jj) / float(RES_V)
		for ii in range(RES_U + 1):
			var u: float = float(ii) / float(RES_U)
			pts.append(cs[j] + ns[j] * (off + u * w))
			uvs.append(Vector2(u, v))
	rec["rv"] = pts
	rec["ru"] = uvs


## full 버퍼가 상한을 넘으면 짝수 인덱스만 유지해 밀도를 절반으로(전체 span 보존).
func _decimate_full() -> void:
	var kept: Array = []
	for i in range(_full.size()):
		if i % 2 == 0:
			kept.append(_full[i])
	_full = kept


## 잔여 흔적 알파: 생성 직후 RESIDUE_FADE_IN 동안 0에서 올라온다(갑자기 나타나지 않게).
func residue_alpha(rec: Dictionary) -> float:
	var age: float = _now - float(rec["born"])
	var k: float = smoothstep(0.0, RESIDUE_FADE_IN, age)
	return RESIDUE_ALPHA * (0.55 + 0.45 * float(rec["intensity"])) * k


func _draw() -> void:
	if _near.is_empty() or DriftFoldShape.residue_tex == null:
		return
	var ci: RID = get_canvas_item()
	var tex: RID = DriftFoldShape.residue_tex.get_rid()
	var idx: PackedInt32Array = DriftFoldShape.grid_indices(RES_U, RES_V, 0)
	for rec in _near:
		var a: float = residue_alpha(rec)
		if a <= 0.001:
			continue
		var col: PackedColorArray = PackedColorArray([Color(1.0, 1.0, 1.0, a)])
		RenderingServer.canvas_item_add_triangle_array(
			ci, idx, rec["rv"], col, rec["ru"], PackedInt32Array(), PackedFloat32Array(), tex
		)
