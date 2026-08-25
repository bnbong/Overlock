class_name DriftSkid
extends Node2D
## 드리프트 스키드 마크 (presentation.md §14, v1.0.1). SubViewport 안 월드 공간.
##
## 피벗 드리프트 중 원단이 옆으로 밀려 뭉친 융기 자국. StitchTrail과 형제라 같은
## Mode 7 워프 전 계층에 있고, 원근·미니맵·줌아웃이 자동 반영된다. 물리 루프와
## 무결합: PresentationController가 player.is_drifting일 때 push(pos, dir, intensity)만
## 호출한다(시뮬 결정론 불변, 표현 전용 randf만 사용).
##
## 근경은 링버퍼(_marks, MAX_SKIDS 상한 + 나이 알파 페이드)로 그리고, 완주 줌아웃
## 연출(§13)은 전체 자국이 필요하므로 상한 있는 full 버퍼(_full, MAX_FULL_SKIDS)에
## 같은 샘플을 쌓는다. full 버퍼가 상한을 넘으면 공간 데시메이션(격 간 씩 유지)으로
## 전체 span을 보존하며 밀도만 낮춘다(트랙 전체 자국 유실 방지).

const SKID_SPACING: float = 8.0  # 이동 게이트(px). StitchTrail(10px)보다 촘촘히 뭉침을 남긴다.
const MAX_SKIDS: int = 120  # 근경 링버퍼 상한
const MAX_FULL_SKIDS: int = 400  # 줌아웃용 full 버퍼 상한(초과 시 공간 데시메이션)

# 접선 기준 측방 오프셋(원단이 밀린 방향). intensity로 스케일.
const OFFSET_MAX: float = 14.0  # intensity=1에서 측방 오프셋(px)
const LEN_BASE: float = 6.0  # 융기 스트로크 반길이 기본(px)
const LEN_SCALE: float = 8.0  # intensity 비례 추가 반길이(px)
const RIDGE_SEP: float = 3.0  # 그림자↔하이라이트 능선 간격(px, 융기 입체감)
const SKID_WIDTH: float = 4.5
const JITTER: float = 2.0  # 표현 전용 지터(±px). push 시점에 baked(프레임 간 깜빡임 방지).
const MIN_ALPHA: float = 0.32  # 가장 오래된 근경 자국의 잔여 알파(나이 페이드 하한)

# 원단 base색 기준 2톤(그림자=명도↓ 크레아제 + 하이라이트=명도↑ 융기 능선). 설계 스펙의
# −25%/+15%는 워프·텍스처가 얹힌 실제 화면에서 원단색에 묻혀 식별이 안 돼(스크린샷 실측),
# 스티치와 "확실히 구별" 요건을 지키도록 델타를 키웠다(그림자 −52% / 하이라이트 +42%).
# 여전히 원단색에서 유도한 톤이라 스티치(빨강)와는 계열이 확연히 다르다.
const SHADOW_DARKEN: float = 0.52
const HIGHLIGHT_LIGHTEN: float = 0.42

var _marks: Array = []  # 근경 링버퍼. 각 원소 {"pos","dir","intensity","jit"}.
var _full: Array = []  # 줌아웃용 전체 자국(상한 있음). 각 원소 {"pos","dir","intensity"}.
var _last: Vector2 = Vector2.ZERO
var _has_last: bool = false

@onready var _fabric: FabricSurface = get_node_or_null("../FabricSurface")


## PresentationController가 드리프트 중 매 이동분 호출. dir=drift_dir(-1..1, 부호=밀린 방향),
## intensity=absf(drift_dir)(0..1, 길이/오프셋 스케일). SKID_SPACING 이상 이동 시에만 기록.
func push(pos: Vector2, dir: float, intensity: float) -> void:
	if _has_last and _last.distance_to(pos) < SKID_SPACING:
		return
	var jit: Vector2 = Vector2(randf_range(-JITTER, JITTER), randf_range(-JITTER, JITTER))
	var near: Dictionary = {"pos": pos, "dir": dir, "intensity": intensity, "jit": jit}
	_marks.append(near)
	if _marks.size() > MAX_SKIDS:
		_marks.remove_at(0)
	# full 버퍼는 자체 사본을 보존(줌아웃에서 near 링버퍼가 유실한 초반 자국도 남김).
	_full.append({"pos": pos, "dir": dir, "intensity": intensity})
	if _full.size() > MAX_FULL_SKIDS:
		_decimate_full()
	_last = pos
	_has_last = true
	queue_redraw()


## 완주 줌아웃 연출(FinishView)이 읽는 전체 자국. 각 원소 {"pos","dir","intensity"}.
func get_full_marks() -> Array:
	return _full


## 자국을 모두 비운다. 재시작은 씬 재로드(_ready 재실행)로 자동 초기화되지만,
## 재로드 없이 비워야 하는 경로를 위해 명시 API로도 노출한다.
func clear() -> void:
	_marks.clear()
	_full.clear()
	_has_last = false
	queue_redraw()


## full 버퍼가 상한을 넘으면 짝수 인덱스만 유지해 밀도를 절반으로(전체 span 보존).
## 이후 다시 상한까지 차오르고 데시메이션을 반복하므로 크기가 상한 아래로 유계된다.
func _decimate_full() -> void:
	var kept: Array = []
	for i in range(_full.size()):
		if i % 2 == 0:
			kept.append(_full[i])
	_full = kept


func _draw() -> void:
	var count: int = _marks.size()
	if count == 0:
		return
	var base: Color = _base_color()
	var shadow: Color = base.darkened(SHADOW_DARKEN)
	var high: Color = base.lightened(HIGHLIGHT_LIGHTEN)
	for i in range(count):
		var m: Dictionary = _marks[i]
		var tangent: Vector2 = _tangent_at(i, count)
		# 나이 알파 페이드: 최신(i=count-1)=1.0, 가장 오래됨(i=0)=MIN_ALPHA.
		var age: float = 1.0 if count <= 1 else float(i) / float(count - 1)
		var alpha: float = lerpf(MIN_ALPHA, 1.0, age)
		_draw_mark(m, tangent, shadow, high, alpha)


## 한 융기 자국: 접선 방향 짧은 스트로크를 드리프트 방향으로 측방 오프셋. 능선(그림자)과
## 그 옆 하이라이트를 나란히 그려 원단이 밀려 뭉친 입체 자국으로 보이게 한다.
func _draw_mark(m: Dictionary, tangent: Vector2, shadow: Color, high: Color, alpha: float) -> void:
	var dir: float = float(m["dir"])
	var intensity: float = clampf(float(m["intensity"]), 0.0, 1.0)
	var s: float = signf(dir)
	if s == 0.0:
		return  # 드리프트 방향이 없으면(직진 드리프트) 자국을 남기지 않는다.
	var perp: Vector2 = Vector2(-tangent.y, tangent.x) * s  # 밀린 측방(드리프트 방향)
	var center: Vector2 = Vector2(m["pos"]) + perp * (OFFSET_MAX * intensity) + Vector2(m["jit"])
	var half: Vector2 = tangent * (LEN_BASE + LEN_SCALE * intensity)
	var ridge: Vector2 = perp * RIDGE_SEP
	var sc: Color = Color(shadow.r, shadow.g, shadow.b, alpha)
	var hc: Color = Color(high.r, high.g, high.b, alpha)
	# 그림자 능선(밀린 안쪽) + 하이라이트 능선(밀린 바깥쪽) → 융기 단면.
	draw_line(center - half, center + half, sc, SKID_WIDTH)
	draw_line(center - half + ridge, center + half + ridge, hc, SKID_WIDTH * 0.6)


## 인접 자국 방향으로 접선을 추정(끝점은 한쪽 이웃만 사용). StitchTrail과 동일 규약.
func _tangent_at(i: int, count: int) -> Vector2:
	var a: Vector2
	var b: Vector2
	if i == 0:
		a = Vector2(_marks[0]["pos"])
		b = Vector2(_marks[1]["pos"]) if count > 1 else a + Vector2.RIGHT
	elif i == count - 1:
		a = Vector2(_marks[count - 2]["pos"])
		b = Vector2(_marks[count - 1]["pos"])
	else:
		a = Vector2(_marks[i - 1]["pos"])
		b = Vector2(_marks[i + 1]["pos"])
	var d: Vector2 = b - a
	if d.length_squared() < 0.0001:
		return Vector2.RIGHT
	return d.normalized()


## 원단 대표색(2톤 유도 기준). FabricSurface.get_base_color()가 있으면 그 원단색을,
## 없으면 FABRIC_COLOR로 폴백한다. 스티치(빨강)와 확실히 구별되는 원단 계열 톤.
func _base_color() -> Color:
	if _fabric != null:
		return _fabric.get_base_color()
	return FabricSurface.FABRIC_COLOR
