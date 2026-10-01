extends Control
## 결과 화면. GameState.last_result 렌더 + 등급 시나리오 일러스트 + 리더보드 제출 (기획서 §8.4).
##
## 완주 줌아웃(FinishView)은 트랙 실루엣·등급·최종 시간만 남기고, 등급별 시나리오 일러스트는
## 이 완주 정보 창 안에서 카드 좌측에 크게 건다(등급→파일 매핑은 FinishView.scenario_texture
## 단일 소스). 일러스트가 없으면 프레임째 숨겨 정보 열만 남는 기존 세로 카드로 폴백한다.
##
## 표시는 완주 직후 반드시 알아야 하는 것만 남긴다: 트랙명 / 재봉 평점(등급) / 최종 시간
## (+페널티) / 신기록 / 등급 산출 요소 한 줄(정확도·퍼펙트·부상) / 리더보드 제출. 난이도·
## Finish Time(= Final − Penalty)·Off-Seam·속도 통계는 결과 dict에 그대로 있고 화면에서만 뺐다.
##
## 터치 기기(MenuTouch.active)에서는 제출·재도전·메뉴 버튼을 손가락 크기로, 설명 글자를 읽을 수 있게
## 키우고, 긴 트랙 이름·요약 줄은 줄을 바꿔 정보 열 폭을 지킨다. 데스크톱 배치는 그대로다.
##
## 개인 고스트(v2.3.0): 신기록 줄 아래 고스트 줄(GhostLabel)에 새 고스트 저장 성공·실패와 사유, 개인 최고
## 대비 차이(패널티 포함), 구간별 차이, 트랙이 바뀌어 고스트를 쓸 수 없는 경우의 안내, 연습 기록 여부를
## 보인다(ghost_summary).

const TRACK_NAMES: Dictionary = {"cotton_01": "Cotton Warm-up"}
const ToastScene = preload("res://scenes/Toast.tscn")

# 카드 크기는 런타임 실측으로 정한다(_fit_to_content). 씬의 고정 오프셋은 에디터 미리보기용
# 기본값이고, 일러스트 유무·제출 버튼 노출로 콘텐츠가 달라지므로 고정값만 쓰면 넘치거나
# 빈 카드가 된다(ProfileDialog의 고정 오프셋 오버플로우 전례).
const PANEL_PAD_H: float = 52.0  # PanelBg가 콘텐츠를 감싸는 좌우 여백.
const PANEL_PAD_V: float = 52.0  # 위아래 여백.
const CARD_MARGIN: float = 20.0  # 카드가 화면 가장자리에 남기는 최소 여백.
# 카드 최소 크기. 베이지 9패치 패널의 모서리 장식(실패·깅엄·물방울·바늘꽂이, 각 ~140px)이
# 서로 맞물려 콘텐츠를 덮지 않으려면 이만큼은 필요하다(일러스트 없는 폴백 카드용 하한).
const CARD_MIN: Vector2 = Vector2(540.0, 470.0)
const SCENARIO_MAX_W: float = 560.0  # 일러스트 폭 상한(카드가 과하게 넓어지지 않게).
const SCENARIO_MIN_H: float = 200.0  # 일러스트 높이 하한(정보 열이 짧아도 이만큼은 확보).
const _TOUCH_INFO_W: float = 460.0  # 터치 배치의 정보 열 폭(줄 바꿈 기준).
const _GHOST_W: float = 420.0  # 고스트 줄 줄바꿈 폭.
const GHOST_REASONS_SHORT: Dictionary = {
	"too_many_samples": "샘플 상한 초과",
	"too_large": "파일 크기 초과",
	"write_failed": "파일 쓰기 실패",
}
const GHOST_REASONS: Dictionary = {
	"too_many_samples": "주행이 길어 고스트 샘플 상한(24000개)을 넘었습니다",
	"too_large": "고스트 파일 크기 상한(2MiB)을 넘었습니다",
	"write_failed": "고스트 파일을 쓰지 못했습니다",
	"invalid": "고스트 데이터가 올바르지 않습니다",
	"not_started": "고스트 데이터가 올바르지 않습니다",
}

var _toast: Toast
var _ghost_label: Label

@onready var _panel: HBoxContainer = $Panel
@onready var _panel_bg: Control = $PanelBg
@onready var _scenario_frame: PanelContainer = $Panel/ScenarioFrame
@onready var _scenario_image: TextureRect = $Panel/ScenarioFrame/ScenarioImage
@onready var _info: VBoxContainer = $Panel/Info
@onready var _track_label: Label = $Panel/Info/TrackLabel
@onready var _grade_label: Label = $Panel/Info/GradeRow/GradeBox/GradeLabel
@onready var _time_label: Label = $Panel/Info/GradeRow/TimeBox/TimeLabel
@onready var _penalty_label: Label = $Panel/Info/GradeRow/TimeBox/PenaltyLabel
@onready var _stats_label: Label = $Panel/Info/StatsLabel
@onready var _new_record_label: Label = $Panel/Info/NewRecordLabel
@onready var _submit_button: Button = $Panel/Info/SubmitButton
@onready var _submit_status: Label = $Panel/Info/SubmitStatusLabel
@onready var _retry_button: Button = $Panel/Info/ButtonRow/RetryButton
@onready var _menu_button: Button = $Panel/Info/ButtonRow/MenuButton


func _ready() -> void:
	var result: Dictionary = GameState.last_result
	_track_label.text = _track_name(str(result.get("track_id", "")))
	_apply_grade(result)
	_apply_time(result)
	_stats_label.text = _build_stats(result)
	var is_new_record: bool = bool(result.get("is_new_record", false))
	_new_record_label.visible = is_new_record
	_build_ghost_label(result)
	_apply_scenario(str(result.get("grade", "-")))
	_toast = ToastScene.instantiate()
	add_child(_toast)
	_setup_submit(result)
	_apply_skin()
	_apply_touch_layout()
	_retry_button.pressed.connect(_on_retry_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)
	_retry_button.grab_focus()
	_apply_editor_test()
	# 오디오 훅: 신기록이면 팡파레, 아니면 피니시 징글(가드: 미등록 시 무시).
	_play_result_audio(is_new_record)
	# 스킨·일러스트·제출 버튼이 모두 배선된 뒤 실제 콘텐츠 크기로 카드를 감싼다.
	_fit_to_content()


## 사용자 제공 시트 스킨(있으면): 베이지 카드 패널 + 대형 필 버튼. 없으면 .tscn 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		return
	UiSkin.skin_panel(_panel_bg, "beige")
	for b in [_submit_button, _retry_button, _menu_button]:
		UiSkin.skin_button(b, "large")


## 터치 기기: 버튼 높이·글자를 키우고, 트랙 이름(최대 두 줄)과 요약·상태 줄은 줄을 바꾼다.
## 정보 열은 고정 폭(_TOUCH_INFO_W)으로 두어 일러스트와 함께 카드가 화면 안에 들어가게 한다.
func _apply_touch_layout() -> void:
	if not MenuTouch.active():
		return
	MenuTouch.buttons([_submit_button, _retry_button, _menu_button])
	var captions: Array = [$Panel/Info/GradeRow/GradeBox/GradeCaption]
	captions.append($Panel/Info/GradeRow/TimeBox/TimeCaption)
	MenuTouch.texts(captions + [_penalty_label, _stats_label, _submit_status])
	MenuTouch.text(_ghost_label)
	_ghost_label.custom_minimum_size.x = _TOUCH_INFO_W
	_info.custom_minimum_size.x = _TOUCH_INFO_W
	_info.add_theme_constant_override("separation", 6)
	for l in [_track_label, _stats_label, _submit_status]:
		(l as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_track_label.max_lines_visible = 2
	_track_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# 요약 줄은 "Cuts / 2"처럼 항목 안에서 끊기지 않게, 항목 안 공백만 줄바꿈 없는 공백으로 바꾼다
	# (줄 바꿈은 항목 구분점 자리에서만 일어난다).
	var sep: String = "   ·   "
	var items: PackedStringArray = _stats_label.text.split(sep)
	for i in range(items.size()):
		items[i] = items[i].replace(" ", "\u00a0")
	_stats_label.text = sep.join(items)


## 에디터 테스트 플레이 결과: 주 버튼은 "편집으로 돌아가기"(앞·포커스), 보조는 "다시 테스트".
## 기록을 저장하지 않는다는 안내를 제출 상태 줄에 띄운다(일반 플레이는 변경 없음).
func _apply_editor_test() -> void:
	if not GameState.is_editor_test():
		return
	_menu_button.text = "편집으로 돌아가기"
	_retry_button.text = "다시 테스트"
	# 한글 라벨이 기본 "Retry/Menu"보다 길어 필 버튼 양끝 단추 장식에 가리지 않게 폭을 확보한다.
	_menu_button.custom_minimum_size.x = maxf(_menu_button.custom_minimum_size.x, 280.0)
	_retry_button.custom_minimum_size.x = maxf(_retry_button.custom_minimum_size.x, 210.0)
	_menu_button.get_parent().move_child(_menu_button, 0)
	_menu_button.grab_focus()
	_new_record_label.visible = false
	_ghost_label.visible = false
	_submit_status.visible = true
	_submit_status.text = "테스트 플레이는 기록을 저장하지 않습니다"


## 신기록 줄 아래에 고스트 저장 상태 줄을 붙인다(문구가 없으면 숨김).
func _build_ghost_label(result: Dictionary) -> void:
	_ghost_label = Label.new()
	_ghost_label.name = "GhostLabel"
	_ghost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ghost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ghost_label.custom_minimum_size.x = _GHOST_W
	_ghost_label.add_theme_font_size_override("font_size", 14)
	_ghost_label.add_theme_color_override("font_color", Color(0.32, 0.24, 0.19, 1))
	# 터치 배치는 글자가 커서 구간 10개를 다 쓰면 카드가 화면을 넘을 수 있어 구간 차이를 개수 요약으로 줄인다.
	_ghost_label.text = ghost_summary(result, MenuTouch.active())
	_ghost_label.visible = not _ghost_label.text.is_empty()
	_info.add_child(_ghost_label)
	_info.move_child(_ghost_label, _new_record_label.get_index() + 1)


## 결과 dict의 고스트·기록 메타(RaceDirector._submit_record)를 사람이 읽는 줄들로 만든다.
## compact=true(터치 배치)면 구간별 차이를 빠름·느림·비교 불가 개수 한 줄로 줄인다.
static func ghost_summary(result: Dictionary, compact: bool = false) -> String:
	if bool(result.get("editor_test", false)) or not result.has("ghost_status"):
		return ""
	if compact:
		return _ghost_summary_compact(result)
	var lines: PackedStringArray = PackedStringArray()
	var prev: int = int(result.get("prev_best_ms", -1))
	var final_ms: int = int(result.get("final_time_ms", 0))
	var reason: String = str(result.get("ghost_reason", ""))
	match str(result.get("ghost_status", "")):
		"saved":
			lines.append("새 개인 최고 고스트를 저장했습니다")
		"failed":
			var why: String = str(GHOST_REASONS.get(reason, "고스트를 만들지 못했습니다"))
			lines.append("최고 기록은 저장했지만 고스트는 없습니다: " + why)
		"unchanged":
			if reason == "record_save_failed":
				lines.append("기록을 저장하지 못해 이전 최고 기록과 고스트를 유지합니다")
			elif prev >= 0:
				var slow: float = float(final_ms - prev) / 1000.0
				var tail: String = "%.2f초 느림" % slow if final_ms > prev else "같은 시간"
				lines.append("개인 최고보다 %s (패널티 포함) · 고스트는 그대로입니다" % tail)
	if bool(result.get("is_new_record", false)) and prev >= 0:
		lines.append("개인 최고를 %.2f초 줄였습니다 (패널티 포함)" % (float(prev - final_ms) / 1000.0))
	var splits: String = _split_summary(result.get("split_deltas", []))
	if not splits.is_empty():
		lines.append(splits)
	if _track_changed_hint(result):
		lines.append("트랙이 바뀌어 이전 고스트를 쓸 수 없습니다 · 개인 최고를 갱신하면 새 고스트가 생깁니다")
	if bool(result.get("practice", false)):
		lines.append("개발용 튜닝이 적용된 연습 기록입니다")
	return "\n".join(lines)


## 터치 배치용 짧은 요약. 글자가 커도 카드가 화면(여백 CARD_MARGIN) 안에 들도록 문구를 줄이고, 신기록 단축
## 시간 줄은 빼며(NEW RECORD 표시가 대신함) 구간 차이는 빠름·느림·비교 불가 개수로 줄인다.
static func _ghost_summary_compact(result: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()
	var prev: int = int(result.get("prev_best_ms", -1))
	var final_ms: int = int(result.get("final_time_ms", 0))
	var reason: String = str(result.get("ghost_reason", ""))
	match str(result.get("ghost_status", "")):
		"saved":
			lines.append("새 고스트 저장")
		"failed":
			lines.append("고스트 없음: " + str(GHOST_REASONS_SHORT.get(reason, "생성 실패")))
		"unchanged":
			if reason == "record_save_failed":
				lines.append("기록 저장 실패: 이전 최고·고스트 유지")
			elif prev >= 0:
				var slow: float = float(final_ms - prev) / 1000.0
				lines.append("개인 최고보다 %.2f초 느림 (패널티 포함)" % slow)
	var splits: String = _split_summary(result.get("split_deltas", []), true)
	if not splits.is_empty():
		lines.append(splits)
	if _track_changed_hint(result):
		lines.append("트랙 변경: 최고 갱신 시 새 고스트")
	if bool(result.get("practice", false)):
		lines.append("연습 기록 (개발용 튜닝)")
	return "\n".join(lines)


## 기록 당시와 트랙이 달라 이전 고스트를 쓸 수 없는데 이번 완주로 최고를 갱신하지 못했는가.
static func _track_changed_hint(result: Dictionary) -> bool:
	var changed: bool = bool(result.get("ghost_track_changed", false))
	return changed and not bool(result.get("is_new_record", false))


## 구간별 개인 최고 대비 차이(초, 패널티 포함). 비교할 수 없는 구간은 "--". 비교 구간이 없으면 빈 문자열.
static func _split_summary(deltas: Variant, compact: bool = false) -> String:
	if not (deltas is Array) or (deltas as Array).is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	var counts: Array[int] = [0, 0, 0]  # 빠름(같음 포함), 느림, 비교 불가
	for d in deltas:
		if d == null:
			parts.append("--")
			counts[2] += 1
		else:
			parts.append("%+.2f" % (float(d) / 1000.0))
			counts[0 if float(d) <= 0.0 else 1] += 1
	if counts[0] + counts[1] == 0:
		return ""
	if compact:
		return "구간(패널티 포함): 빠름 %d · 느림 %d · 비교 불가 %d" % counts
	return "구간별 차이(패널티 포함): " + " ".join(parts)


## 재봉 평점(등급)을 큰 문자로 눈에 띄게 표시. 하위 호환: grade 없으면 "-".
func _apply_grade(result: Dictionary) -> void:
	var grade: String = str(result.get("grade", "-"))
	_grade_label.text = grade
	_grade_label.add_theme_color_override("font_color", FinishView.grade_color(grade))


## 최종 시간(강조) + 페널티 짧은 표기. 페널티가 없으면 줄째로 숨긴다(정보 다이어트).
## finish_ms는 final − penalty로 자명해 따로 보여주지 않는다.
func _apply_time(result: Dictionary) -> void:
	_time_label.text = _format_ms(int(result.get("final_time_ms", 0)))
	var penalty_ms: int = int(result.get("penalty_ms", 0))
	_penalty_label.visible = penalty_ms > 0
	if penalty_ms > 0:
		_penalty_label.text = "penalty +%.1fs" % (float(penalty_ms) / 1000.0)


## 등급 시나리오 일러스트를 카드 좌측에 건다. 등급→파일 매핑은 FinishView.scenario_texture가
## 단일 소스이며, 매핑 불가("-")·파일 부재면 프레임을 숨겨 정보 열만 남긴다(하위 호환).
func _apply_scenario(grade: String) -> void:
	var tex: Texture2D = FinishView.scenario_texture(grade)
	_scenario_frame.visible = tex != null
	if tex != null:
		_scenario_image.texture = tex


## 콘텐츠 실측으로 카드(Panel/PanelBg) 크기를 정한다. 일러스트는 정보 열 높이에 맞춰 키우되
## 폭 상한과 화면 여유로 클램프하고, 일러스트가 없으면 정보 열 폭 그대로 좁은 카드가 된다.
func _fit_to_content() -> void:
	await get_tree().process_frame  # 자식 라벨·버튼의 최소 크기 확정 대기.
	var vp: Vector2 = get_viewport_rect().size
	if _scenario_frame.visible:
		_size_scenario(vp)
		await get_tree().process_frame  # 일러스트 최소 크기가 컨테이너에 반영될 때까지.
	var pad: Vector2 = Vector2(PANEL_PAD_H, PANEL_PAD_V) * 2.0
	var card: Vector2 = (_panel.get_combined_minimum_size() + pad).max(CARD_MIN)
	_set_box(_panel, card - pad)  # 콘텐츠는 컨테이너 정렬(center/shrink)로 카드 중앙에 남는다.
	_set_box(_panel_bg, card)


## 일러스트 크기: 정보 열 높이에 맞춰(카드 좌우 균형) 잡되 원본 비율을 유지하고, 폭 상한과
## 카드가 화면에 들어갈 가로·세로 여유로 클램프한다.
func _size_scenario(vp: Vector2) -> void:
	var tex: Texture2D = _scenario_image.texture
	if tex == null:
		return
	var tex_size: Vector2 = tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var aspect: float = tex_size.x / tex_size.y
	var info: Vector2 = _info.get_combined_minimum_size()
	var frame_pad: Vector2 = _frame_padding()
	var gap: float = float(_panel.get_theme_constant("separation"))
	var max_w: float = minf(
		SCENARIO_MAX_W, vp.x - CARD_MARGIN * 2.0 - PANEL_PAD_H * 2.0 - gap - info.x - frame_pad.x
	)
	var max_h: float = vp.y - CARD_MARGIN * 2.0 - PANEL_PAD_V * 2.0 - frame_pad.y
	var h: float = clampf(maxf(info.y, SCENARIO_MIN_H), SCENARIO_MIN_H, max_h)
	var w: float = minf(h * aspect, max_w)
	_scenario_image.custom_minimum_size = Vector2(w, minf(w / aspect, max_h))


## 일러스트 프레임(PanelContainer)의 테두리·여백이 먹는 크기.
func _frame_padding() -> Vector2:
	var sb: StyleBox = _scenario_frame.get_theme_stylebox("panel")
	return sb.get_minimum_size() if sb != null else Vector2.ZERO


## 중앙 앵커(preset 8) Control의 오프셋을 주어진 크기로 맞춘다(중앙 정렬 유지).
static func _set_box(node: Control, box: Vector2) -> void:
	node.offset_left = -box.x * 0.5
	node.offset_right = box.x * 0.5
	node.offset_top = -box.y * 0.5
	node.offset_bottom = box.y * 0.5


## 등급 산출 요소(정확도·퍼펙트 비율·부상)만 한 줄로 압축한다. 등급이 어디서 나왔는지
## 설명하는 최소 정보라 남긴다.
func _build_stats(result: Dictionary) -> String:
	if result.is_empty():
		return "No result data."
	return (
		"Accuracy %.1f%%   ·   Perfect %.1f%%   ·   Cuts %d"
		% [
			float(result.get("accuracy", 0.0)),
			float(result.get("perfect_rate", 0.0)),
			int(result.get("cuts", 0))
		]
	)


# --- 리더보드 제출(§8.4 Submit to Leaderboard) ---


## 제출 버튼 노출 판정: 공식 트랙 + 온라인 활성 + 닉네임 있음 + 서버 연결됨일 때만 표시한다.
## 커스텀 트랙(is_custom)은 서버 제출 대상이 아니므로 버튼 자체를 숨긴다. 서버 연결이 확인됐고
## 오프라인이면 숨긴다(health_known 전이면 낙관적 허용 — 제출 실패는 조용히 처리·토스트 안내).
## 닉네임은 최초 실행 모달로 항상 존재하므로 사실상 공식+온라인 조건이 관건이다.
func _setup_submit(result: Dictionary) -> void:
	_submit_status.visible = false
	var track_id: String = str(result.get("track_id", ""))
	var is_custom: bool = track_id.begins_with(LeaderboardClient.CUSTOM_PREFIX)
	var offline: bool = LeaderboardClient.health_known and not LeaderboardClient.server_reachable
	# 에디터 테스트 플레이는 서버에 제출하지 않는다(버튼 숨김 + _on_submit_pressed 가드).
	var can_submit: bool = (
		not GameState.is_editor_test()
		and not bool(result.get("editor_test", false))
		and not is_custom
		and LeaderboardClient.is_online_enabled()
		and LeaderboardClient.has_nickname()
		and not offline
	)
	_submit_button.visible = can_submit
	if can_submit:
		_submit_button.pressed.connect(_on_submit_pressed)
	elif is_custom and not CommunityStore.post_for_local(track_id).is_empty():
		# 공유 허브에서 받은 트랙: 기록은 로컬에만 남고 공식 리더보드에는 제출하지 않는다.
		_submit_status.visible = true
		_submit_status.text = "커뮤니티 트랙은 로컬 기록만 저장됩니다 (공식 리더보드 미제출)"


func _on_submit_pressed() -> void:
	if GameState.is_editor_test() or bool(GameState.last_result.get("editor_test", false)):
		return
	# 중복 제출 방지: 누른 즉시 비활성화하고 제출 중 상태를 표시한다.
	_submit_button.disabled = true
	_submit_status.visible = true
	_submit_status.text = "제출 중..."
	LeaderboardClient.submit_completed.connect(_on_submit_completed, CONNECT_ONE_SHOT)
	LeaderboardClient.submit_run(GameState.last_result)


func _on_submit_completed(success: bool, rank: int, status: String, message: String) -> void:
	_submit_status.visible = true
	if success:
		if rank > 0:
			_submit_status.text = "Rank #%d" % rank
		else:
			_submit_status.text = "제출 완료"
		if not status.is_empty():
			_submit_status.text += "  (" + status + ")"
		_submit_button.text = "제출 완료"
		# 성공 시 버튼은 비활성 유지(중복 제출 방지).
		_toast.push("리더보드 제출 완료" + ("  ·  Rank #%d" % rank if rank > 0 else ""))
	else:
		_submit_status.text = message
		_submit_button.disabled = false  # 실패(오프라인·거부)는 재시도 허용.
		_toast.push("제출 실패: " + message)


## 재도전. 실행 출처는 유지한다(에디터 테스트면 "다시 테스트").
func _on_retry_pressed() -> void:
	GameState.retry_run()


## "Menu"는 맵 선택 화면으로 돌아간다(2단 네비게이션 허브). 방금 플레이한 트랙이 마지막
## 선택 트랙으로 복원되므로 최고 기록 갱신을 확인하고 바로 다른 트랙을 고르거나 재도전할 수
## 있다. 완전한 메인 4버튼 화면으로는 맵 선택의 "뒤로"로 이어진다.
## 에디터 테스트 플레이면 이 버튼은 "편집으로 돌아가기"다.
func _on_menu_pressed() -> void:
	if GameState.is_editor_test():
		GameState.return_to_editor()
		return
	get_tree().change_scene_to_file("res://scenes/TrackSelect.tscn")


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _play_result_audio(is_new_record: bool) -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am == null:
		return
	if is_new_record and am.has_method("play_record"):
		am.play_record()
	elif am.has_method("play_finish"):
		am.play_finish()


## 표시용 트랙명: 내장 표기 → 트랙 파일의 name(공식·커스텀 공용, TrackLoader 캐시) → id 순.
func _track_name(track_id: String) -> String:
	if TRACK_NAMES.has(track_id):
		return str(TRACK_NAMES[track_id])
	if track_id.is_empty():
		return ""  # 결과 dict가 비어 있는 경우(직접 씬 실행 등) — 로더를 부르지 않는다.
	var track: TrackData = TrackLoader.load_track(track_id)
	if track != null and not track.track_name.is_empty():
		return track.track_name
	return track_id


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
