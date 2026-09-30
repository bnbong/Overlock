extends Control
## 공유 허브 화면(계획서 §2). 트랙 선택 화면의 "공유 허브"(목록) 또는 "허브에 게시"(게시 양식)로
## 진입한다. 한 씬 안에서 네 가지 보기를 전환한다.
##
##  - list  : 최신순 목록(20개 단위 "더 보기"), 제목 검색(최대 80자), 상태 표시(로딩·빈 목록·검색
##            결과 없음·통신 실패·429 등)와 "다시 시도".
##  - detail: 제목·작성자 표시명·설명·난이도·재질·길이·등록일 + 경로 미리보기(TrackSelectScreen의
##            draw_track_preview 재사용), "다운로드" / "다운로드 후 플레이", 토큰을 가진 내 게시물에는
##            "게시물 삭제"(확인 단계). 삭제된 게시물(404)은 따로 표시한다.
##  - form  : 게시 양식(제목·작성자 표시명·설명) → 공개 게시 안내 확인 → 업로드.
##  - done  : 게시 완료. 삭제 토큰은 이 기기에만 저장된다는 안내. 토큰 저장에 실패했으면 토큰을
##            화면에 남겨 복사할 수 있게 한다(업로드는 다시 하지 않는다). 같은 보기를 "저장하지 못한
##            토큰" 재표시에도 쓴다: 화면에 들어올 때 CommunityTrackClient.unsaved_tokens 가 남아 있으면
##            먼저 보여 주고, 저장 재시도에 성공하거나 사용자가 보관을 확인하면 원래 진입 보기로 간다.
##
## 업로드가 진행되는 동안에는 취소 버튼과 Esc(화면 이탈)를 막는다(늦은 201 의 토큰을 화면이 받게).
##
## 제목·작성자·설명은 Label/LineEdit 일반 텍스트로만 그린다(BBCode·링크·원격 이미지 없음). 작성자
## 이름은 "작성자 표시명"으로만 표기하고 인증 표시처럼 꾸미지 않는다. 통신은 CommunityTrackClient,
## 저장은 TrackLoader.import_hub_track(검증·정규화 공용 파이프라인)이 맡는다. 화면은 자기가 보낸
## 요청 번호와 같은 결과만 반영하고, 떠날 때 목록·상세 요청을 취소한다.

const TRACK_SELECT_SCENE: String = "res://scenes/TrackSelect.tscn"
const TrackSelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const ToastScene = preload("res://scenes/Toast.tscn")
const W = preload("res://scripts/ui/CommunityHubWidgets.gd")

const PAGE_SIZE: int = 20
const PANEL_HALF: Vector2 = Vector2(580.0, 336.0)
const CONTENT_INSET: Vector2 = Vector2(40.0, 30.0)
const PANEL_FILL: Color = Color(0.20, 0.145, 0.125, 0.97)
const BOTTOM_BTN_W: float = 170.0

const LOCAL_ONLY_NOTICE: String = "커뮤니티 트랙은 로컬 기록만 저장됩니다 (공식 리더보드 미제출)"
const PUBLIC_NOTICE: String = (
	"공개 게시 안내: 게시한 트랙과 제목·작성자 표시명·설명은 누구나 볼 수 있고, 게시한 뒤에는 "
	+ "수정할 수 없습니다. 고친 트랙은 새 게시물로 올리고 이전 게시물은 삭제할 수 있습니다."
)
const TOKEN_NOTICE: String = (
	"삭제 권한(토큰)은 이 기기에만 저장됩니다. 브라우저 데이터나 앱 데이터를 지우면 "
	+ "이 게시물을 삭제할 권한을 잃습니다."
)
const AUTHOR_HINT: String = "작성자 표시명은 게시자가 직접 입력한 이름이며 신원 확인을 거치지 않습니다."

const _CREAM: Color = Color(0.968, 0.929, 0.847)
const _SOFT: Color = Color(0.80, 0.74, 0.64)
const _WARN: Color = Color(1.0, 0.70, 0.55)
const _GOOD: Color = Color(0.70, 0.92, 0.62)
const _NOTICE: Color = Color(1.0, 0.86, 0.55)
const _INK: Color = Color(0.278, 0.203, 0.153)

var _view: String = ""
var _toast: Toast

# 목록 상태
var _query: String = ""
var _items: Array = []
var _total: int = 0
var _list_req: int = 0
var _list_append: bool = false
var _list_loaded: bool = false
# 서버 목록에서 소비한 offset(응답 항목 수만큼 전진). 화면 항목 수(_items.size())와 다를 수 있다.
var _server_offset: int = 0
var _list_offset_req: int = 0
var _has_more: bool = false

# 상세 상태
var _detail: Dictionary = {}
var _detail_id: String = ""
var _detail_req: int = 0
var _detail_points: PackedVector2Array = PackedVector2Array()

# 게시·삭제 상태
var _publish_track_id: String = ""
var _publish_req: int = 0
var _form_points: PackedVector2Array = PackedVector2Array()
var _created: Dictionary = {}
var _delete_req: int = 0
var _overlay_action: Callable = Callable()
# 토큰 상자에 보이는 토큰의 게시물 id, 저장하지 못한 토큰을 재표시하는 중인지, 그 뒤 열 게시 양식.
var _token_post_id: String = ""
var _recovery: bool = false
var _resume_publish: String = ""

# 노드(코드로 구성)
var _title_label: Label
var _views: Dictionary = {}
var _search_edit: LineEdit
var _search_btn: Button
var _clear_btn: Button
var _list_status: Label
var _retry_btn: Button
var _rows: VBoxContainer
var _list_back_btn: Button
var _more_btn: Button
var _detail_preview: Control
var _detail_title: Label
var _detail_author: Label
var _detail_meta: Label
var _detail_desc: Label
var _detail_note: Label
var _detail_status: Label
var _detail_back_btn: Button
var _detail_retry_btn: Button
var _download_btn: Button
var _play_btn: Button
var _delete_btn: Button
var _form_preview: Control
var _form_track_label: Label
var _title_edit: LineEdit
var _author_edit: LineEdit
var _desc_edit: TextEdit
var _desc_count: Label
var _form_status: Label
var _form_cancel: Button
var _form_submit: Button
var _done_info: Label
var _token_box: VBoxContainer
var _token_edit: LineEdit
var _copy_btn: Button
var _token_retry_btn: Button
var _token_ack_btn: Button
var _done_back: Button
var _done_view_btn: Button
var _overlay: Control
var _overlay_label: Label
var _overlay_no: Button
var _overlay_yes: Button


func _ready() -> void:
	_build_ui()
	_toast = ToastScene.instantiate()
	add_child(_toast)
	CommunityTrackClient.completed.connect(_on_completed)
	_resume_publish = CommunityTrackClient.pending_publish_track_id
	CommunityTrackClient.pending_publish_track_id = ""
	_enter_default()


## 저장하지 못한 토큰이 있으면 먼저 보여 주고, 없으면 게시 양식(트랙 선택에서 온 경우) 또는 목록.
func _enter_default() -> void:
	var unsaved: Dictionary = CommunityTrackClient.first_unsaved_token()
	if not unsaved.is_empty():
		_show_unsaved_token(unsaved)
		return
	if not _resume_publish.is_empty():
		var pending: String = _resume_publish
		_resume_publish = ""
		_open_form(pending)
		return
	_show_view("list")
	_request_list(false)


func _exit_tree() -> void:
	# 화면을 떠나면 목록·상세 요청을 취소한다(게시·삭제는 오토로드가 끝까지 처리해 토큰을 지킨다).
	CommunityTrackClient.cancel_reads()


## Esc(ui_cancel, 게임패드 B 포함): 확인 창 닫기 → 상세에서 목록 → 그 밖에는 트랙 선택으로.
func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	if _publish_req != 0:
		_set_form_status("업로드하는 중입니다. 끝날 때까지 이 화면을 떠날 수 없습니다.", _NOTICE)
	elif _overlay.visible:
		_close_overlay()
	elif _view == "detail":
		_back_to_list()
	else:
		_go_back()


# --- 보기 전환 ---


func _show_view(view_name: String) -> void:
	_view = view_name
	for key in _views:
		(_views[key] as Control).visible = key == view_name
	match view_name:
		"list":
			_title_label.text = "공유 허브"
		"detail":
			_title_label.text = "공유 허브 · 상세"
		"form":
			_title_label.text = "공유 허브에 게시"
		"done":
			_title_label.text = "게시 완료"


func _go_back() -> void:
	if _publish_req != 0:
		return  # 업로드 중에는 화면을 떠나지 않는다(취소 버튼도 비활성).
	CommunityTrackClient.cancel_reads()
	get_tree().change_scene_to_file(TRACK_SELECT_SCENE)


func _back_to_list() -> void:
	CommunityTrackClient.cancel("detail")
	_detail_req = 0
	_show_view("list")
	if not _list_loaded and _list_req == 0:
		_request_list(false)
		return
	_focus_row(_detail_id)


# --- 목록 ---


func _request_list(append: bool) -> void:
	_list_append = append
	if not append:
		_items.clear()
		_total = 0
		_server_offset = 0
		_has_more = false
		_list_loaded = false
		_clear_rows()
	_list_offset_req = _server_offset
	_set_list_status("불러오는 중...", _SOFT)
	_retry_btn.visible = false
	_more_btn.disabled = true
	_list_req = CommunityTrackClient.list(_query, _list_offset_req, PAGE_SIZE)


func _on_search() -> void:
	_query = _search_edit.text.strip_edges()
	_request_list(false)


func _on_clear_search() -> void:
	_search_edit.text = ""
	_query = ""
	_request_list(false)


func _on_list_done(r: Dictionary) -> void:
	_more_btn.disabled = false
	if not bool(r["ok"]):
		_set_list_status(W.status_text(r), _WARN)
		_retry_btn.visible = true
		_more_btn.visible = false
		return
	var data: Dictionary = r["data"]
	var count: int = int(data.get("count", (data["items"] as Array).size()))
	_server_offset = _list_offset_req + count
	var known: Dictionary = {}
	for it in _items:
		known[str(it["id"])] = true
	var added: Array = []
	for it in data["items"]:
		var post_id: String = str(it["id"])
		if not known.has(post_id):
			known[post_id] = true  # 한 응답 안의 중복 id 도 한 번만 넣는다.
			_items.append(it)
			added.append(it)
	_total = int(data["total"])
	# 응답이 비었으면(count 0) 더 받을 것이 없다. 중복만 온 경우에도 offset 은 전진했으므로 고착되지 않는다.
	_has_more = count > 0 and _server_offset < _total
	_list_loaded = true
	for it in added:
		_rows.add_child(_make_row(it))
	_update_list_status()
	if not _list_append and not added.is_empty() and not _search_edit.has_focus():
		(_rows.get_child(0) as Control).grab_focus()
	elif _list_append and not added.is_empty():
		(_rows.get_child(_rows.get_child_count() - added.size()) as Control).grab_focus()


func _update_list_status() -> void:
	_more_btn.visible = _has_more
	if _items.is_empty():
		if _query.is_empty():
			_set_list_status("아직 게시된 트랙이 없습니다.", _SOFT)
		else:
			_set_list_status("'%s' 검색 결과가 없습니다." % _query, _SOFT)
		return
	var head: String = "'%s' 검색 결과 " % _query if not _query.is_empty() else "최신순 "
	_set_list_status("%s%d개 중 %d개 표시" % [head, _total, _items.size()], _SOFT)


func _set_list_status(text: String, color: Color) -> void:
	_list_status.text = text
	_list_status.add_theme_color_override("font_color", color)


func _clear_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()


func _remove_item(post_id: String) -> void:
	for i in range(_items.size() - 1, -1, -1):
		if str(_items[i]["id"]) == post_id:
			_items.remove_at(i)
			_total = maxi(_total - 1, 0)
			# 서버 목록도 한 칸 당겨지므로 다음 "더 보기"가 항목을 건너뛰지 않게 offset 을 되돌린다.
			_server_offset = maxi(_server_offset - 1, 0)
			_has_more = _has_more and _server_offset < _total
	for child in _rows.get_children():
		if str(child.get_meta("post_id", "")) == post_id:
			_rows.remove_child(child)
			child.queue_free()
	if _list_loaded:
		_update_list_status()


func _focus_row(post_id: String) -> void:
	for child in _rows.get_children():
		if str(child.get_meta("post_id", "")) == post_id:
			(child as Control).grab_focus()
			return
	if _rows.get_child_count() > 0:
		(_rows.get_child(0) as Control).grab_focus()
	else:
		_search_edit.grab_focus()


## 목록 행. 작성자 표시명과 메타 정보는 서로 다른 Label 에 그린다(CommunityHubWidgets.post_row).
func _make_row(item: Dictionary) -> Button:
	var meta_parts: PackedStringArray = PackedStringArray(
		[
			str(item["difficulty"]).to_upper(),
			_fabric_text(str(item["fabric"])),
			"%d px" % int(item["length"]),
			W.fmt_date(str(item["created_at"])),
		]
	)
	if not CommunityStore.token_for(str(item["id"])).is_empty():
		meta_parts.append("내가 올린 게시물")
	var b: Button = W.post_row(item, "   ·   ".join(meta_parts))
	b.pressed.connect(_open_detail.bind(str(item["id"])))
	return b


# --- 상세 ---


func _open_detail(post_id: String) -> void:
	_detail_id = post_id
	_detail = {}
	_detail_points = PackedVector2Array()
	_show_view("detail")
	_detail_title.text = "불러오는 중..."
	_detail_author.text = ""
	_detail_meta.text = ""
	_detail_desc.text = ""
	_set_detail_status("", _SOFT)
	_set_detail_actions(false, false)
	_detail_retry_btn.visible = false
	_detail_preview.queue_redraw()
	_detail_back_btn.grab_focus()
	_detail_req = CommunityTrackClient.detail(post_id)


func _on_detail_done(r: Dictionary) -> void:
	if bool(r["ok"]):
		_render_detail(r["data"])
		return
	_detail_points = PackedVector2Array()
	_detail_preview.queue_redraw()
	_detail_author.text = ""
	_detail_meta.text = ""
	_detail_desc.text = ""
	_set_detail_actions(false, false)
	if str(r["status"]) == "not_found":
		_detail_title.text = "삭제된 게시물"
		_set_detail_status("삭제되었거나 없는 게시물입니다. 목록에서도 사라집니다.", _WARN)
		# 상세 조회 404 로는 삭제 토큰을 지우지 않는다(삭제 요청의 204·404 에서만 지운다).
		_remove_item(_detail_id)
	else:
		_detail_title.text = "게시물을 불러오지 못했습니다"
		_set_detail_status(W.status_text(r), _WARN)
		_detail_retry_btn.visible = true
	_detail_back_btn.grab_focus()


func _render_detail(data: Dictionary) -> void:
	_detail = data
	_detail_id = str(data["id"])
	_show_view("detail")
	_detail_retry_btn.visible = false
	_detail_title.text = str(data["title"])
	_detail_author.text = "작성자 표시명: " + str(data["author_name"])
	_detail_meta.text = "   ·   ".join(
		PackedStringArray(
			[
				str(data["difficulty"]).to_upper(),
				_fabric_text(str(data["fabric"])),
				"%d px" % int(data["length"]),
				"등록 " + W.fmt_date(str(data["created_at"])),
			]
		)
	)
	var desc: String = str(data.get("description", ""))
	_detail_desc.text = desc if not desc.is_empty() else "(설명 없음)"
	_detail_points = TrackLoader.hub_preview_points(data["track"])
	_detail_preview.queue_redraw()
	var mine: bool = not CommunityStore.token_for(_detail_id).is_empty()
	_set_detail_actions(true, mine)
	if _already_downloaded(_detail_id):
		_set_detail_status("이미 받은 트랙입니다. 트랙 선택 화면의 커스텀 트랙에서도 플레이할 수 있습니다.", _SOFT)
	else:
		_set_detail_status("", _SOFT)
	_download_btn.grab_focus()


func _set_detail_actions(loaded: bool, mine: bool) -> void:
	_download_btn.disabled = not loaded
	_play_btn.disabled = not loaded
	_download_btn.visible = loaded
	_play_btn.visible = loaded
	_delete_btn.visible = loaded and mine
	_delete_btn.disabled = _delete_req != 0


func _set_detail_status(text: String, color: Color) -> void:
	_detail_status.text = text
	_detail_status.add_theme_color_override("font_color", color)


func _already_downloaded(post_id: String) -> bool:
	var entry: Dictionary = CommunityStore.download_entry(post_id)
	return not entry.is_empty() and TrackLoader.is_unmodified_hub_download(str(entry["track_id"]))


## 상세 데이터를 TrackLoader 공용 파이프라인으로 저장한다. 저장에 실패하면 플레이하지 않는다.
func _download(play: bool) -> void:
	if _detail.is_empty():
		return
	var res: Dictionary = TrackLoader.import_hub_track(
		{
			"post_id": str(_detail["id"]),
			"title": str(_detail["title"]),
			"content_hash": str(_detail["content_hash"]),
			"track": _detail["track"],
		}
	)
	if not bool(res["ok"]):
		# 결과는 상태 줄에만 표시한다(하단 토스트가 상세 화면 버튼 줄을 가리지 않게).
		_set_detail_status("다운로드 실패: " + str(res["message"]), _WARN)
		return
	var id: String = str(res["track_id"])
	LeaderboardClient.remember_last_track(id)
	if play:
		var track: TrackData = TrackLoader.load_track(id)
		if track == null:
			_set_detail_status("받은 트랙을 불러오지 못했습니다.", _WARN)
			return
		CommunityTrackClient.cancel_reads()
		GameState.start_run(id, track.difficulty if not track.difficulty.is_empty() else "normal")
		return
	var text: String
	if str(res["status"]) == "duplicate":
		text = "이미 받은 트랙입니다: %s" % str(res["name"])
	else:
		text = "내 트랙에 저장했습니다: %s" % str(res["name"])
	_set_detail_status(text + " (트랙 선택 화면에서 플레이할 수 있습니다)", _GOOD)


func _on_delete_pressed() -> void:
	if _detail.is_empty() or _delete_req != 0:
		return
	_ask(
		"'%s' 게시물을 삭제할까요?\n삭제하면 목록과 상세에서 사라지며 되돌릴 수 없습니다. "
		% str(_detail["title"])
		+ "이미 받은 사람의 로컬 사본은 남습니다.",
		_do_delete,
		"삭제"
	)


func _do_delete() -> void:
	var req: int = CommunityTrackClient.delete_post(_detail_id)
	if req == 0:
		return
	_delete_req = req
	_delete_btn.disabled = true
	_set_detail_status("삭제하는 중...", _SOFT)


func _on_delete_done(r: Dictionary) -> void:
	_delete_req = 0
	var post_id: String = str(r["data"].get("post_id", _detail_id))
	if bool(r["ok"]) or str(r["status"]) == "not_found":
		var msg: String = "게시물을 삭제했습니다" if bool(r["ok"]) else "이미 삭제된 게시물입니다"
		_toast.push(msg)
		_remove_item(post_id)
		if _view == "detail" and _detail_id == post_id:
			_show_view("list")
			_request_list(false)
		return
	_delete_btn.disabled = false
	if _view == "detail":
		_set_detail_status("삭제 실패: " + W.status_text(r), _WARN)
	else:
		_toast.push("삭제 실패: " + W.status_text(r))


# --- 게시 ---


func _open_form(track_id: String) -> void:
	_publish_track_id = track_id
	_show_view("form")
	var built: Dictionary = TrackLoader.build_publish_track(track_id)
	var track: TrackData = TrackLoader.load_track(track_id)
	_form_points = track.points if track != null else PackedVector2Array()
	_form_preview.queue_redraw()
	var tname: String = str(built.get("name", ""))
	if tname.is_empty() and track != null:
		tname = track.track_name
	_form_track_label.text = "게시할 트랙: " + (tname if not tname.is_empty() else track_id)
	_title_edit.text = tname.substr(0, CommunityTrackClient.TITLE_MAX)
	_author_edit.text = LeaderboardClient.nickname.strip_edges().substr(
		0, CommunityTrackClient.AUTHOR_MAX
	)
	_desc_edit.text = ""
	_update_desc_count()
	_form_submit.disabled = not bool(built["ok"]) or TrackLoader.is_unmodified_hub_download(track_id)
	if not bool(built["ok"]):
		_set_form_status(str(built["message"]), _WARN)
	elif TrackLoader.is_unmodified_hub_download(track_id):
		_set_form_status("허브에서 받은 트랙은 그대로 다시 게시할 수 없습니다.", _WARN)
	else:
		_set_form_status("", _SOFT)
	_title_edit.grab_focus()


func _set_form_status(text: String, color: Color) -> void:
	_form_status.text = text
	_form_status.add_theme_color_override("font_color", color)


func _on_desc_changed() -> void:
	var text: String = _desc_edit.text
	if text.length() > CommunityTrackClient.DESCRIPTION_MAX:
		_desc_edit.text = text.substr(0, CommunityTrackClient.DESCRIPTION_MAX)
		_desc_edit.set_caret_line(_desc_edit.get_line_count() - 1)
		_desc_edit.set_caret_column(_desc_edit.get_line(_desc_edit.get_line_count() - 1).length())
	_update_desc_count()


func _update_desc_count() -> void:
	_desc_count.text = "%d / %d자" % [_desc_edit.text.length(), CommunityTrackClient.DESCRIPTION_MAX]


func _on_form_submit() -> void:
	if _publish_req != 0 or CommunityTrackClient.is_busy("publish"):
		return
	var title: String = _title_edit.text.strip_edges()
	var author: String = _author_edit.text.strip_edges()
	if title.is_empty():
		_set_form_status("제목을 입력하세요.", _WARN)
		_title_edit.grab_focus()
		return
	if author.is_empty():
		_set_form_status("작성자 표시명을 입력하세요.", _WARN)
		_author_edit.grab_focus()
		return
	_ask(PUBLIC_NOTICE + "\n\n'%s' 트랙을 공유 허브에 게시할까요?" % title, _do_publish, "게시하기")


func _do_publish() -> void:
	if _publish_req != 0:
		return
	var built: Dictionary = TrackLoader.build_publish_track(_publish_track_id)
	if not bool(built["ok"]):
		_set_form_status(str(built["message"]), _WARN)
		return
	var req: int = CommunityTrackClient.publish(
		_title_edit.text, _author_edit.text, _desc_edit.text, built["track"], _publish_track_id
	)
	if req == 0:
		return
	_publish_req = req
	_form_submit.disabled = true
	_form_cancel.disabled = true
	_set_form_status("업로드하는 중입니다... 끝날 때까지 이 화면을 떠날 수 없습니다.", _SOFT)


func _on_publish_done(r: Dictionary) -> void:
	_publish_req = 0
	_form_cancel.disabled = false
	if not bool(r["ok"]):
		if bool(r.get("maybe_published", false)):
			# 게시가 됐을 수 있으므로 다시 올리지 못하게 제출 버튼을 끈 채로 둔다.
			_set_form_status(str(r["message"]), _WARN)
			_form_cancel.grab_focus()
			return
		_form_submit.disabled = false
		var msg: String = W.status_text(r)
		if str(r["status"]) == "timeout" or str(r["status"]) == "network_error":
			msg += "\n업로드가 서버에 도착했는지 확인하지 못했습니다. 목록에서 게시 여부를 확인한 뒤 다시 시도하세요."
		_set_form_status(msg, _WARN)
		return
	_created = r["data"]
	_recovery = false
	_show_view("done")
	var saved: bool = bool(r.get("token_saved", false))
	_done_info.text = "'%s' 트랙을 공유 허브에 게시했습니다." % str(_created["title"])
	_set_token_box(str(_created["id"]), "" if saved else str(_created.get("delete_token", "")))
	# 토큰 원문은 화면 표시용으로만 두고, 이후 상세 보기 데이터에는 싣지 않는다.
	_created.erase("delete_token")
	if saved:
		_done_view_btn.grab_focus()
	else:
		_copy_btn.grab_focus()


## 이전에 저장하지 못한 토큰을 다시 보여 준다(오토로드가 메모리에 보관한 것).
func _show_unsaved_token(entry: Dictionary) -> void:
	_recovery = true
	_created = {"id": str(entry["post_id"]), "title": str(entry["title"]), "partial": true}
	_form_points = PackedVector2Array()
	_show_view("done")
	_title_label.text = "저장하지 못한 삭제 토큰"
	_done_info.text = "'%s' 게시물의 삭제 토큰을 아직 이 기기에 저장하지 못했습니다." % str(entry["title"])
	_set_token_box(str(entry["post_id"]), str(entry["delete_token"]))
	_copy_btn.grab_focus()


func _set_token_box(post_id: String, token: String) -> void:
	_token_post_id = post_id
	_token_box.visible = not token.is_empty()
	_token_edit.text = token


func _on_copy_token() -> void:
	if _token_edit.text.is_empty():
		return
	DisplayServer.clipboard_set(_token_edit.text)
	_toast.push("삭제 토큰을 클립보드에 복사했습니다")


func _on_token_retry() -> void:
	if CommunityTrackClient.retry_unsaved_token(_token_post_id):
		_toast.push("삭제 토큰을 이 기기에 저장했습니다")
		_token_resolved()
	else:
		_toast.push("아직 저장하지 못했습니다. 토큰을 복사해 따로 보관하세요")


func _on_token_ack() -> void:
	CommunityTrackClient.dismiss_unsaved_token(_token_post_id)
	_token_resolved()


func _token_resolved() -> void:
	_set_token_box("", "")
	if _recovery:
		_recovery = false
		_enter_default()
	else:
		_done_view_btn.grab_focus()


func _on_done_view() -> void:
	if _created.is_empty():
		return
	if bool(_created.get("partial", false)):
		_open_detail(str(_created["id"]))  # 상세 필드가 없거나 어긋났으면 서버에서 다시 조회한다.
	else:
		_render_detail(_created)


# --- 확인 창 ---


func _ask(text: String, on_yes: Callable, yes_text: String = "확인") -> void:
	_overlay_label.text = text
	_overlay_yes.text = yes_text
	_overlay_action = on_yes
	_overlay.visible = true
	_overlay_no.grab_focus()


func _close_overlay() -> void:
	_overlay.visible = false
	_overlay_action = Callable()
	match _view:
		"detail":
			_detail_back_btn.grab_focus()
		"form":
			_form_submit.grab_focus()


func _on_overlay_yes() -> void:
	var action: Callable = _overlay_action
	_close_overlay()
	if action.is_valid():
		action.call()


# --- 통신 결과 ---


func _on_completed(r: Dictionary) -> void:
	var id: int = int(r["request_id"])
	match str(r["kind"]):
		"list":
			if id == _list_req:
				_list_req = 0
				_on_list_done(r)
		"detail":
			if id == _detail_req:
				_detail_req = 0
				_on_detail_done(r)
		"publish":
			if id == _publish_req:
				_on_publish_done(r)
		"delete":
			if id == _delete_req:
				_on_delete_done(r)


# --- 표시 도우미 ---


func _fabric_text(fabric: String) -> String:
	return str(TrackSelectScript.FABRIC_LABELS.get(fabric, fabric))


# --- UI 구성 ---


func _build_ui() -> void:
	# 재봉 패치 패널(SewingSkin 절차 드로잉: 어두운 원단 + 박음질 테두리 + 모서리 단추). 목록·상세가
	# 패널 전체를 쓰므로 모서리 장식이 큰 9패치 대신 콘텐츠를 가리지 않는 절차 패치를 쓴다.
	var panel_bg: SewingSkin = SewingSkin.new()
	panel_bg.name = "PanelBg"
	panel_bg.fill_color = PANEL_FILL
	panel_bg.stitch_color = SewingSkin.THREAD_PURPLE
	panel_bg.corner_radius = 18.0
	panel_bg.stitch_inset = 10.0
	W.center(panel_bg, PANEL_HALF)
	add_child(panel_bg)
	var content: VBoxContainer = VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", 10)
	W.center(content, PANEL_HALF - CONTENT_INSET)
	add_child(content)
	_title_label = W.label("공유 허브", 30, _CREAM)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_outline_color", Color(0.26, 0.11, 0.15))
	_title_label.add_theme_constant_override("outline_size", 6)
	content.add_child(_title_label)
	_views["list"] = _build_list_view()
	_views["detail"] = _build_detail_view()
	_views["form"] = _build_form_view()
	_views["done"] = _build_done_view()
	for key in _views:
		content.add_child(_views[key])
	_build_overlay()


func _build_list_view() -> Control:
	var v: VBoxContainer = W.vbox(10)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var search: HBoxContainer = W.hbox(10)
	_search_edit = LineEdit.new()
	_search_edit.max_length = CommunityTrackClient.QUERY_MAX
	_search_edit.placeholder_text = "제목 검색 (최대 80자)"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.custom_minimum_size = Vector2(0, 46)
	W.style_edit(_search_edit)
	_search_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
	_search_btn = W.button("검색", 16, 130.0)
	_search_btn.pressed.connect(_on_search)
	_clear_btn = W.button("전체 보기", 16, 130.0)
	_clear_btn.pressed.connect(_on_clear_search)
	search.add_child(_search_edit)
	search.add_child(_search_btn)
	search.add_child(_clear_btn)
	v.add_child(search)
	var status_row: HBoxContainer = W.hbox(10)
	_list_status = W.label("", 16, _SOFT, true)
	_list_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_retry_btn = W.button("다시 시도", 15)
	_retry_btn.visible = false
	_retry_btn.pressed.connect(func() -> void: _request_list(false))
	status_row.add_child(_list_status)
	status_row.add_child(_retry_btn)
	v.add_child(status_row)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_rows = W.vbox(6)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	v.add_child(scroll)
	var bottom: HBoxContainer = W.hbox(12)
	_list_back_btn = W.button("뒤로", 17, BOTTOM_BTN_W)
	_list_back_btn.pressed.connect(_go_back)
	_more_btn = W.button("더 보기", 17, BOTTOM_BTN_W)
	_more_btn.visible = false
	_more_btn.pressed.connect(func() -> void: _request_list(true))
	bottom.add_child(_list_back_btn)
	bottom.add_child(W.spacer())
	bottom.add_child(_more_btn)
	v.add_child(bottom)
	return v


func _build_detail_view() -> Control:
	var v: VBoxContainer = W.vbox(10)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top: HBoxContainer = W.hbox(22)
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_preview = Control.new()
	_detail_preview.custom_minimum_size = Vector2(420, 330)
	_detail_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_detail_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_preview.draw.connect(
		func() -> void: TrackSelectScript.draw_track_preview(_detail_preview, _detail_points)
	)
	top.add_child(_detail_preview)
	var info: VBoxContainer = W.vbox(8)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_title = W.label("", 26, _CREAM, true)
	_detail_title.max_lines_visible = 2
	_detail_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_detail_author = W.label("", 17, _SOFT)
	_detail_author.clip_text = true
	_detail_author.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_detail_meta = W.label("", 16, _SOFT, true)
	var desc_scroll: ScrollContainer = ScrollContainer.new()
	desc_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_scroll.custom_minimum_size = Vector2(0, 90)
	desc_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_desc = W.label("", 16, _CREAM, true)
	_detail_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_scroll.add_child(_detail_desc)
	_detail_note = W.label(LOCAL_ONLY_NOTICE, 15, _SOFT, true)
	_detail_status = W.label("", 15, _SOFT, true)
	for c in [_detail_title, _detail_author, _detail_meta, desc_scroll, _detail_note, _detail_status]:
		info.add_child(c)
	top.add_child(info)
	v.add_child(top)
	var bottom: HBoxContainer = W.hbox(12)
	_detail_back_btn = W.button("목록으로", 17, BOTTOM_BTN_W)
	_detail_back_btn.pressed.connect(_back_to_list)
	_detail_retry_btn = W.button("다시 시도", 17, BOTTOM_BTN_W)
	_detail_retry_btn.visible = false
	_detail_retry_btn.pressed.connect(func() -> void: _open_detail(_detail_id))
	_delete_btn = W.button("게시물 삭제", 17, BOTTOM_BTN_W)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_download_btn = W.button("다운로드", 17, BOTTOM_BTN_W)
	_download_btn.pressed.connect(_download.bind(false))
	_play_btn = W.button("다운로드 후 플레이", 17, BOTTOM_BTN_W)
	_play_btn.pressed.connect(_download.bind(true))
	for c in [_detail_back_btn, _detail_retry_btn, _delete_btn, W.spacer(), _download_btn, _play_btn]:
		bottom.add_child(c)
	v.add_child(bottom)
	return v


func _build_form_view() -> Control:
	var v: VBoxContainer = W.vbox(8)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top: HBoxContainer = W.hbox(22)
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left: VBoxContainer = W.vbox(8)
	_form_preview = Control.new()
	_form_preview.custom_minimum_size = Vector2(340, 250)
	_form_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_form_preview.draw.connect(
		func() -> void: TrackSelectScript.draw_track_preview(_form_preview, _form_points)
	)
	_form_track_label = W.label("", 15, _SOFT, true)
	_form_track_label.custom_minimum_size = Vector2(340, 0)
	left.add_child(_form_preview)
	left.add_child(_form_track_label)
	top.add_child(left)
	var fields: VBoxContainer = W.vbox(6)
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_edit = LineEdit.new()
	_title_edit.max_length = CommunityTrackClient.TITLE_MAX
	_title_edit.custom_minimum_size = Vector2(0, 44)
	W.style_edit(_title_edit)
	_author_edit = LineEdit.new()
	_author_edit.max_length = CommunityTrackClient.AUTHOR_MAX
	_author_edit.custom_minimum_size = Vector2(0, 44)
	W.style_edit(_author_edit)
	_desc_edit = TextEdit.new()
	_desc_edit.custom_minimum_size = Vector2(0, 96)
	_desc_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_desc_edit.placeholder_text = "트랙 소개 (선택)"
	W.style_edit(_desc_edit)
	# Tab 은 들여쓰기 대신 포커스 이동(키보드·게임패드 조작 관례). 속성이 없는 엔진에서는 무시된다.
	if "tab_input_mode" in _desc_edit:
		_desc_edit.set("tab_input_mode", false)
	_desc_edit.text_changed.connect(_on_desc_changed)
	_desc_count = W.label("", 13, _SOFT)
	_desc_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fields.add_child(W.label("제목 (1~80자)", 15, _CREAM))
	fields.add_child(_title_edit)
	fields.add_child(W.label("작성자 표시명 (1~32자)", 15, _CREAM))
	fields.add_child(_author_edit)
	fields.add_child(W.label(AUTHOR_HINT, 13, _SOFT, true))
	fields.add_child(W.label("설명 (선택, 최대 1000자)", 15, _CREAM))
	fields.add_child(_desc_edit)
	fields.add_child(_desc_count)
	top.add_child(fields)
	v.add_child(top)
	v.add_child(W.label(PUBLIC_NOTICE, 14, _SOFT, true))
	_form_status = W.label("", 15, _SOFT, true)
	v.add_child(_form_status)
	var bottom: HBoxContainer = W.hbox(12)
	_form_cancel = W.button("취소", 17, BOTTOM_BTN_W)
	_form_cancel.pressed.connect(_go_back)
	_form_submit = W.button("게시하기", 17, BOTTOM_BTN_W)
	_form_submit.pressed.connect(_on_form_submit)
	bottom.add_child(_form_cancel)
	bottom.add_child(W.spacer())
	bottom.add_child(_form_submit)
	v.add_child(bottom)
	return v


func _build_done_view() -> Control:
	var v: VBoxContainer = W.vbox(14)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top: HBoxContainer = W.hbox(26)
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var done_preview: Control = Control.new()
	done_preview.custom_minimum_size = Vector2(380, 280)
	done_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	done_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	done_preview.draw.connect(
		func() -> void: TrackSelectScript.draw_track_preview(done_preview, _form_points)
	)
	top.add_child(done_preview)
	var info: VBoxContainer = W.vbox(14)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_done_info = W.label("", 22, _CREAM, true)
	info.add_child(_done_info)
	info.add_child(W.label(TOKEN_NOTICE, 17, _NOTICE, true))
	var tb: Dictionary = W.token_box(_WARN)
	_token_box = tb["box"]
	_token_edit = tb["edit"]
	_copy_btn = tb["copy"]
	_token_retry_btn = tb["retry"]
	_token_ack_btn = tb["ack"]
	_copy_btn.pressed.connect(_on_copy_token)
	_token_retry_btn.pressed.connect(_on_token_retry)
	_token_ack_btn.pressed.connect(_on_token_ack)
	info.add_child(_token_box)
	info.add_child(W.label(LOCAL_ONLY_NOTICE, 15, _SOFT, true))
	top.add_child(info)
	v.add_child(top)
	var bottom: HBoxContainer = W.hbox(12)
	_done_back = W.button("트랙 선택으로", 17, BOTTOM_BTN_W)
	_done_back.pressed.connect(_go_back)
	_done_view_btn = W.button("게시물 보기", 17, BOTTOM_BTN_W)
	_done_view_btn.pressed.connect(_on_done_view)
	bottom.add_child(_done_back)
	bottom.add_child(W.spacer())
	bottom.add_child(_done_view_btn)
	v.add_child(bottom)
	return v


func _build_overlay() -> void:
	var parts: Dictionary = W.confirm_overlay(
		SewingSkin.FABRIC, SewingSkin.THREAD_PURPLE, _INK, BOTTOM_BTN_W
	)
	_overlay = parts["root"]
	_overlay_label = parts["label"]
	_overlay_no = parts["no"]
	_overlay_yes = parts["yes"]
	_overlay_no.pressed.connect(_close_overlay)
	_overlay_yes.pressed.connect(_on_overlay_yes)
	add_child(_overlay)
	# 확인 창이 열린 동안 포커스가 뒤쪽 버튼으로 빠지지 않게 두 버튼 사이에서만 오가게 한다.
	for pair in [[_overlay_no, _overlay_yes], [_overlay_yes, _overlay_no]]:
		var a: Button = pair[0]
		var other: NodePath = a.get_path_to(pair[1])
		var own: NodePath = a.get_path_to(a)
		a.focus_neighbor_left = other
		a.focus_neighbor_right = other
		a.focus_neighbor_top = own
		a.focus_neighbor_bottom = own
		a.focus_next = other
		a.focus_previous = other
