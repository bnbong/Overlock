class_name UiSkin
extends RefCounted
## 사용자 제공 재봉 UI 시트(assets/gfx/ui/*.png) 로더 + 위젯 스킨 팩토리.
##
## 절차적 폴백(SewingSkin.gd)은 그대로 보존한다. 여기서는 시트에서 분해한 개별
## 텍스처(대형/소형/정사각 버튼, 베이지·다크 패널, 태그 라벨, 쉐브론, 진행 홈,
## 바늘 마커, 하단 아이콘 8종)를 9패치 StyleBoxTexture / NinePatchRect / TextureRect로
## 배선한다. 텍스처 로드 실패 시 모든 팩토리는 조용히 폴백(호출부가 절차적 스킨 유지)한다.
##
## 기능·레이아웃·게임 값에는 관여하지 않는다(순수 표현). 잉크 팔레트는 SewingSkin과 통일.

const DIR: String = "res://assets/gfx/ui/"

# HUD 위젯별 시트 스킨 토글. 시트 추출 품질이 위젯에 따라 갈릴 수 있어(예: 태그 라벨은
# 텍스처가 깨끗한 반면 속도 게이지 쉐브론은 틴트가 탁해지는 경우) 위젯 단위로 절차적
# SewingSkin 렌더링으로 원복할 수 있게 한다. false면 has_skin()과 무관하게 해당 위젯은
# 절차 폴백을 그대로 쓴다(다른 UI의 시트 스킨에는 영향 없음).
const SKIN_TIME_TAG: bool = true  # HUD TIME 태그를 tag_label 텍스처로 (false=절차 패치)
const SKIN_SPEED_CHEVRON: bool = false  # 속도 게이지를 chevron 텍스처로 (false=절차 폴리라인)

# 잉크/포커스 팔레트 (SewingSkin 계승).
const INK: Color = Color(0.278, 0.203, 0.153)
const INK_HOVER: Color = Color(0.2, 0.14, 0.1)
const INK_DISABLED: Color = Color(0.5, 0.44, 0.38)
const FOCUS_RED: Color = Color(0.831, 0.278, 0.263)
const CREAM: Color = Color(0.968, 0.929, 0.847)

# 9패치 마진(실측, 텍스처 픽셀 기준). 모서리 장식/단추/둥근 캡 보존값.
# 3차 재베이크(사용자 신규 시트): 알파 bbox 트림 후 실사용 해상도로 리샘플한 텍스처
# 기준으로 재실측. 9패치 코너는 1:1(텍스처 px == 화면 px)로 그려지므로 마진 = 화면상
# 장식 크기다. 필 버튼 캡(둥근 끝+단추+방사 스티치), 패널 네 모서리 장식(실패·깅엄·
# 물방울·바늘꽂이)이 코너 존에 온전히 들도록 실측했다.
const MARGIN := {
	"large": {"l": 36, "r": 36, "t": 7, "b": 7},  # 텍스처 273x56
	"small": {"l": 34, "r": 34, "t": 7, "b": 7},  # 텍스처 190x48
	"square": {"l": 13, "r": 13, "t": 13, "b": 13},  # 텍스처 98x96
	"panel_beige": {"l": 140, "r": 138, "t": 140, "b": 136},  # 텍스처 573x469
	"panel_dark": {"l": 156, "r": 140, "t": 130, "b": 170},  # 텍스처 757x440
	"groove": {"l": 40, "r": 170, "t": 16, "b": 16},
}
# 스킨된 버튼 최소 높이(텍스처 높이에 맞춰 세로 9패치 왜곡 최소화 — 필 버튼은 세로
# 스트레치≈1:1이라야 양끝 단추가 타원으로 찌그러지지 않는다).
const MIN_H := {"large": 56, "small": 48, "square": 46}
# 버튼 텍스트 좌우 최소 여백(캡의 둥근 단추를 글자가 덮지 않도록 확보하는 하한).
const _TEXT_CLEARANCE := {"large": 26, "small": 25, "square": 8}

static var _cache: Dictionary = {}


## 텍스처를 로드·캐시한다(없으면 null).
static func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var path: String = DIR + name + ".png"
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_cache[name] = t
	return t


static func has_skin() -> bool:
	return tex("btn_large_normal") != null


# --- StyleBoxTexture 빌더 ---


static func _sb(name: String, m: Dictionary, tint: Color = Color.WHITE) -> StyleBoxTexture:
	var t: Texture2D = tex(name)
	if t == null:
		return null
	var sb: StyleBoxTexture = StyleBoxTexture.new()
	sb.texture = t
	sb.set_texture_margin(SIDE_LEFT, m["l"])
	sb.set_texture_margin(SIDE_RIGHT, m["r"])
	sb.set_texture_margin(SIDE_TOP, m["t"])
	sb.set_texture_margin(SIDE_BOTTOM, m["b"])
	# 가로로 늘어나는 필 버튼의 상·하 러닝 스티치가 뭉개지지 않게 타일링(TILE_FIT).
	# 세로는 텍스처 높이=버튼 높이라 1:1 스트레치로 충분(단추 왜곡 방지).
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.modulate_color = tint
	return sb


## 포커스 표시용: 투명 배경 + 빨간 러닝 스티치풍 테두리(기존 focus 유지).
static func _focus_box(radius: int) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = FOCUS_RED
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(radius)
	return sb


## 버튼에 시트 스킨을 적용한다. kind: "large" | "small" | "square".
## 텍스처가 없으면 false 반환(호출부가 폴백 유지).
static func skin_button(
	btn: Button, kind: String = "large", font_size: int = -1, pad_h: int = -1
) -> bool:
	if not has_skin():
		return false
	var normal_name: String
	var pressed_sb: StyleBoxTexture
	var m: Dictionary = MARGIN[kind]
	match kind:
		"large":
			normal_name = "btn_large_normal"
			pressed_sb = _sb("btn_large_pressed", m)
		"small":
			normal_name = "btn_small_normal"
			pressed_sb = _sb("btn_small_normal", m, Color(0.86, 0.84, 0.82))
		"square":
			normal_name = "btn_square_blank"
			pressed_sb = _sb("btn_square_blank", m, Color(0.86, 0.84, 0.82))
		_:
			return false
	var normal_sb: StyleBoxTexture = _sb(normal_name, m)
	if normal_sb == null or pressed_sb == null:
		return false
	var hover_sb: StyleBoxTexture = _sb(normal_name, m, Color(1.07, 1.05, 1.02))
	# 텍스트 여백(캡의 둥근 단추를 글자가 덮지 않도록 좌우 패딩 확보). 호출부가 준 값이
	# 하한(_TEXT_CLEARANCE)보다 작으면 하한으로 올려 새 캡 폭에 맞춘다.
	var ph: int = pad_h if pad_h >= 0 else _TEXT_CLEARANCE[kind]
	if ph < _TEXT_CLEARANCE[kind]:
		ph = _TEXT_CLEARANCE[kind]
	for sb in [normal_sb, pressed_sb, hover_sb]:
		sb.set_content_margin(SIDE_LEFT, ph)
		sb.set_content_margin(SIDE_RIGHT, ph)
		sb.set_content_margin(SIDE_TOP, 6)
		sb.set_content_margin(SIDE_BOTTOM, 6)
	btn.add_theme_stylebox_override("normal", normal_sb)
	btn.add_theme_stylebox_override("hover", hover_sb)
	btn.add_theme_stylebox_override("pressed", pressed_sb)
	btn.add_theme_stylebox_override("focus", _focus_box(24 if kind != "square" else 14))
	# 눌림/토글 상태도 pressed 룩으로.
	btn.add_theme_stylebox_override("hover_pressed", pressed_sb)
	var dis: StyleBoxTexture = _sb(normal_name, m, Color(0.72, 0.7, 0.66, 0.7))
	if dis != null:
		btn.add_theme_stylebox_override("disabled", dis)
	# 폰트 색.
	btn.add_theme_color_override("font_color", INK)
	btn.add_theme_color_override("font_hover_color", INK_HOVER)
	btn.add_theme_color_override("font_pressed_color", INK_HOVER)
	btn.add_theme_color_override("font_focus_color", INK_HOVER)
	btn.add_theme_color_override("font_disabled_color", INK_DISABLED)
	if font_size > 0:
		btn.add_theme_font_size_override("font_size", font_size)
	if btn.custom_minimum_size.y < MIN_H[kind]:
		btn.custom_minimum_size.y = MIN_H[kind]
	return true


## 버튼에 아이콘(시트 하단 8종)을 얹는다. name: "play/prev/next/needle/download/
## trash/gear/trophy". max_w로 크기 제한. icon_only=true면 텍스트를 비운다.
static func set_icon(btn: Button, name: String, max_w: int = 26, icon_only: bool = false) -> bool:
	var t: Texture2D = tex("icon_" + name)
	if t == null:
		return false
	btn.icon = t
	btn.add_theme_constant_override("icon_max_width", max_w)
	btn.add_theme_color_override("icon_normal_color", INK)
	btn.add_theme_color_override("icon_hover_color", INK_HOVER)
	btn.add_theme_color_override("icon_pressed_color", INK_HOVER)
	btn.add_theme_color_override("icon_focus_color", INK)
	if icon_only:
		btn.text = ""
		btn.expand_icon = false
	else:
		btn.add_theme_constant_override("h_separation", 8)
	return true


## 아이콘 전용 나브 버튼(맵 선택 ◀▶ 등): 정사각 단추 바탕(btn_square_blank)을 제거하고
## 아이콘만 남긴다. 배경 StyleBox는 전부 투명(StyleBoxEmpty)이라 클릭 히트 영역은
## 노드의 custom_minimum_size로만 유지되고(투명 히트 영역), hover/pressed는 아이콘
## modulate 틴트로만 피드백한다. focus_mode는 씬 설정(순환 제외 등)을 그대로 둔다.
static func skin_icon_nav(btn: Button, name: String, icon_w: int = 24) -> bool:
	if not set_icon(btn, name, icon_w, true):
		return false
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	# hover/pressed 아이콘 틴트(배경이 없으므로 아이콘 색만으로 상태를 알린다).
	btn.add_theme_color_override("icon_normal_color", INK)
	btn.add_theme_color_override("icon_hover_color", FOCUS_RED)
	btn.add_theme_color_override("icon_pressed_color", INK_HOVER)
	btn.add_theme_color_override("icon_disabled_color", INK_DISABLED)
	return true


# --- 패널(9패치) / 텍스처 배경 ---


## control 뒤(첫 자식)에 시트 패널을 9패치로 깐다. kind: "beige" | "dark".
## SewingSkin 절차 배경은 텍스처가 덮으므로, 없으면 그대로 노출된다(폴백).
static func skin_panel(control: Control, kind: String = "beige") -> NinePatchRect:
	var name: String = "panel_beige" if kind == "beige" else "panel_dark"
	var t: Texture2D = tex(name)
	if t == null or control == null:
		return null
	if control.has_node("UiSkinPanel"):
		return control.get_node("UiSkinPanel")
	var np: NinePatchRect = NinePatchRect.new()
	np.name = "UiSkinPanel"
	np.texture = t
	var m: Dictionary = MARGIN[name]
	np.set_patch_margin(SIDE_LEFT, m["l"])
	np.set_patch_margin(SIDE_RIGHT, m["r"])
	np.set_patch_margin(SIDE_TOP, m["t"])
	np.set_patch_margin(SIDE_BOTTOM, m["b"])
	# 엣지(러닝 스티치)·중앙(평탄 원단)을 스트레치 대신 타일링해, 패널이 세로로 길게
	# 늘어나는 화면(Result·Leaderboard)에서도 점선이 늘어져 번지지 않게 한다. 원단
	# 필은 균일(그라디언트 없음)이라 타일 이음매가 보이지 않는다.
	np.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT
	np.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT
	np.set_anchors_preset(Control.PRESET_FULL_RECT)
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(np)
	control.move_child(np, 0)
	return np


## control을 채우는 TextureRect 배경(9패치 아님, 통 스케일). 태그 라벨 등에.
static func skin_texture_bg(
	control: Control, name: String, keep_aspect: bool = false
) -> TextureRect:
	var t: Texture2D = tex(name)
	if t == null or control == null:
		return null
	if control.has_node("UiSkinTexBg"):
		return control.get_node("UiSkinTexBg")
	var tr: TextureRect = TextureRect.new()
	tr.name = "UiSkinTexBg"
	tr.texture = t
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = (
		TextureRect.STRETCH_KEEP_ASPECT_CENTERED if keep_aspect else TextureRect.STRETCH_SCALE
	)
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(tr)
	control.move_child(tr, 0)
	return tr
