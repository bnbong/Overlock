class_name EditorLengthDialog
extends ConfirmationDialog
## "트랙 길이 조절…" 대화상자 (track-editor-ux 3단계).
##
## 현재 길이, 목표 길이(기본값 = 현재 길이), 배율, 적용 후 예상 길이, 예상 검증 결과를 보여 준다.
## 목표를 바꾸면 경로 중심 기준 균일 스케일 + 재샘플 결과를 미리 계산해 preview_changed로 캔버스에
## 보여 주기만 하고, "적용"을 눌러야 TrackEditor가 result로 문서를 바꾼다(취소하면 아무것도 안 바뀐다).
## 긴 트랙을 자동으로 줄이지 않는다. 짧은 트랙에는 권장 최소 길이로 늘리는 버튼만 제안한다.

signal preview_changed(path: PackedVector2Array)

const TARGET_MIN: float = 300.0
const TARGET_MAX: float = 10000.0
const SAME_EPS: float = 0.5  # 이보다 작게 바뀌면 "변경 없음"(적용 버튼 비활성)

# 적용할 결과. 목표가 현재 길이와 같으면 빈 dict.
# {path, pre_close, center, length, factor, validation}
var result: Dictionary = {}

var _proc: StrokeProcessor = StrokeProcessor.new()
var _validator: TrackValidator = TrackValidator.new()
var _src_path: PackedVector2Array = PackedVector2Array()
var _src_pre: PackedVector2Array = PackedVector2Array()
var _fail: float = 90.0
var _cur_len: float = 0.0

var _cur_label: Label
var _target: SpinBox
var _factor_label: Label
var _expect_label: Label
var _check_label: Label
var _suggest_button: Button


func _init() -> void:
	title = "트랙 길이 조절"
	ok_button_text = "적용"
	cancel_button_text = "취소"
	var box: VBoxContainer = VBoxContainer.new()
	box.custom_minimum_size = Vector2(500, 0)
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_cur_label = _label(box)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var tl: Label = Label.new()
	tl.text = "목표 트랙 길이"
	row.add_child(tl)
	_target = SpinBox.new()
	_target.min_value = TARGET_MIN
	_target.max_value = TARGET_MAX
	_target.step = 1.0
	_target.custom_minimum_size = Vector2(140, 0)
	_target.value_changed.connect(func(_v: float) -> void: _update())
	row.add_child(_target)
	_suggest_button = Button.new()
	_suggest_button.text = "권장 최소 %d로 늘리기" % int(TrackValidator.LEN_MIN)
	_suggest_button.pressed.connect(set_target.bind(TrackValidator.LEN_MIN))
	row.add_child(_suggest_button)
	var range_label: Label = _label(box)
	range_label.text = (
		"권장 %d~%d · 허용 %d~%d (6000처럼 권장 범위 밖이어도 허용 범위 안이면 저장할 수 있습니다)"
		% [
			int(TrackValidator.LEN_MIN),
			int(TrackValidator.LEN_MAX),
			int(TrackValidator.LEN_HARD_MIN),
			int(TrackValidator.LEN_HARD_MAX)
		]
	)
	range_label.add_theme_font_size_override("font_size", 13)
	_factor_label = _label(box)
	_expect_label = _label(box)
	_check_label = _label(box)


func _label(parent: Control) -> Label:
	var l: Label = Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(500, 0)
	parent.add_child(l)
	return l


## 현재 문서 경로로 연다. 목표 기본값은 현재 길이(그대로 두면 적용할 것이 없다).
func open_for(path: PackedVector2Array, pre_close: PackedVector2Array, fail: float) -> void:
	_src_path = path
	_src_pre = pre_close
	_fail = fail
	_cur_len = EditorDoc.path_length(path)
	_cur_label.text = "현재 트랙 길이 %d" % roundi(_cur_len)
	_suggest_button.visible = _cur_len < TrackValidator.LEN_MIN
	_target.set_value_no_signal(roundf(_cur_len))
	_update()
	popup_centered()


func set_target(value: float) -> void:
	_target.value = value  # value_changed → _update


func target() -> float:
	return _target.value


## 목표 길이로 미리보기를 다시 계산한다(문서는 바꾸지 않는다).
func _update() -> void:
	var t: float = _target.value
	if absf(t - _cur_len) < SAME_EPS or _src_path.size() < 2:
		result = {}
		get_ok_button().disabled = true
		_factor_label.text = "배율 ×1.000"
		_expect_label.text = "목표 길이를 바꾸면 적용 후 모습을 미리 보여 줍니다."
		_check_label.text = ""
		preview_changed.emit(PackedVector2Array())
		return
	var r: Dictionary = _proc.scale_to_length(_src_path, t, _src_pre)
	var v: Dictionary = _validator.validate(r["path"], _fail)
	r["validation"] = v
	result = r
	get_ok_button().disabled = false
	_factor_label.text = "배율 ×%.3f (경로 중심 기준, 원단·판정 폭은 그대로)" % float(r["factor"])
	_expect_label.text = (
		"적용 후 예상 트랙 길이 %d (현재 %d)" % [roundi(float(r["length"])), roundi(_cur_len)]
	)
	_check_label.text = describe(v)
	_check_label.add_theme_color_override(
		"font_color", Color(0.45, 0.92, 0.55) if bool(v["ok"]) else Color(0.95, 0.45, 0.42)
	)
	preview_changed.emit(r["path"])


## 예상 검증 결과 한두 줄(통과·경고·실패 사유).
static func describe(v: Dictionary) -> String:
	var msgs: Array = v.get("messages", [])
	var joined: String = "  ·  ".join(PackedStringArray(msgs))
	if bool(v["ok"]):
		if int(v["soft"]) > 0:
			return "예상 검증: 통과 (경고 %d)  %s" % [int(v["soft"]), joined]
		return "예상 검증: 통과"
	return "예상 검증: 실패 — %s\n적용은 할 수 있지만 저장·테스트 전에 고쳐야 합니다." % joined
