extends "res://track_editor_regression/check_erase.gd"
## 트랙 에디터 회귀 검사(사본 프로젝트 전용, run.sh 가 실행한다).
##
## 구획:
##  dirty_undo : 이름(연속 입력 한 단위)·원단·난이도·새로 그리기의 dirty/undo/redo, 검증 유지·무효화.
##  shortcuts  : 이름 입력 포커스·확인창 중 Ctrl+Z·Ctrl+Shift+Z·Backspace·Delete·C 비가로채기(양성 대조 포함).
##  far_stroke : 끝점에서 먼 스트로크는 경로를 바꾸지 않고 안내, 끝점 이어 그리기는 붙음(실제 포인터 입력).
##  trim       : 끝부분 자르기 미리보기(제거 아이템 수)·포인터 자르기·아이템 동반 제거·undo/redo, 길이 맞추기 비율.
##  import     : 가져오기 실패 시 문서·id·화면 불변, 미저장 확인, undo 복원, modifiers 제외 안내.
##  roundtrip  : 아이템 4개(lat≠0)·closed·사용자 폭 JSON 가져오기→저장→내보내기→재가져오기→저장 일치,
##               play_fingerprint·build_publish_track, 일반 가져오기 보존·지문 기준 duplicate.
##  open       : 공식·허브 트랙은 사본, 로컬 트랙은 제자리 편집.
##  view       : 새 문서 zoom 0.15, 그리기 영역이 툴바·상태줄과 하단 패널 사이, 불러오기·열기 전체 보기(경로
##               bounds가 보이는 영역 안), +/−·전체 보기 버튼, 화면 이동 도구, 화면 조작 전후 경로 좌표 불변.
##  hit_zoom   : 줌별 스냅·자르기 히트 영역(화면 px 기준 환산).
##  pointer_release : 그리기 영역 밖 뗌·뗌 누락·포커스 잃음 뒤 입력 상태가 남지 않음.
##  stroke_quality  : 같은 월드 곡선을 zoom 1.0과 0.15에서 그렸을 때 점 간격·최소반경·모양 비교.
##  length     : 트랙 길이 조절(1500·2500·4500·6000·8000, 오차 ±1.5), 기본값=현재 길이, 취소 불변, undo 한 단계,
##               아이템 진행 비율·lat·closed 보존, 6000 자동 축소 없음, 짧은 트랙 권장 길이 제안.
##  autofix_review : 자동 수정 미리보기 적용·취소, 아이템 재투영·검토 필요가 저장·테스트를 막고 확정으로 풀림.
##  publish_clamp  : 게시 payload에서 끝점 0.5px 안 아이템 s를 길이−0.5로(파일은 그대로).
##  edit_button    : 트랙 선택 유저 모드 "편집" → 에디터가 그 파일을 열고 저장이 같은 파일에 기록.
##  item_tool  : 아이템 배치(실제 클릭)·먼 곳 클릭·종류 변경·드래그 이동(뗄 때 undo 한 번)·삭제(키·버튼,
##               이름 입력 중 비가로채기)·s 상한·출발/도착 경고·128개 상한·스트로크 미시작.
##  item_lat_cross : 가져온 lat≠0 유지, 8자 교차점을 지나는 드래그가 다른 갈래로 튀지 않음.
##  item_review    : 검토 필요 아이템을 도구로 옮기거나 개별 확정해 해결.
##  fabric_width   : 원단 한국어 이름·견본·선택 반영·저장·게임 로더, 난이도 한국어, 프리셋/사용자 지정 폭,
##                   폭 축소 시 lat 검토.
##  issue_list     : 검증 항목 목록(저장 불가/가능, 권장 경고 요약), 위치로 이동, 접기, px 표기 없음.
##  roundtrip_ui   : 파일 대화상자 → 아이템 도구 → 저장 버튼 → 내보내기 → 재가져오기 → 저장, 지문·게시 형식.
##  play_items     : 테스트 주행에서 배치 아이템 위치·획득(게임 자동주행), 원단 적용, 편집 복귀 시 유지.
##  fix_*      : 교차 리뷰 수정(일괄 확정 lat 클램프·실제 제약 게이트, undo/redo 선택 해제·진행 중 제스처
##               취소, 가져오기 베이크 전 방어, 루프 닫기와 자동 수정·길이 조절, 예전 저장본 중복, 긴 트랙
##               전체 보기·최저 배율 0.04, 저장될 경로 기준 검증).
##  erase_*    : v2.2.1 구간 지우기(끝쪽·시작쪽·중간, 틈 상태 저장·테스트·검증 차단, 양방향 이어 그리기, 닿지 않은
##               스트로크, 직선으로 잇기, 뒤쪽 버리기, 아이템 동반 제거·재계산, undo 한 단위, dirty, 닫힌 루프,
##               줌별 브러시 반경, 취소 시 문서 불변, 라운드트립 지문, 테스트 복귀 스냅샷).
##  test_flow  : 테스트 출발 조건(미검증·미저장 취소·저장 실패), editor_test 출처 진입, 일시정지 복귀,
##               재시작 출처 유지, 완주 시 기록·제출 미발생, 결과 화면 복귀·다시 테스트, 스냅샷 복원,
##               에디터 나가기 후 출처 정리, 일반 플레이 기록 유지.
## 씬 전환 흐름을 따라가려고 이 노드는 current_scene이 아니라 root의 자식으로 남는다.
## 실패한 assertion 이 하나라도 있으면 종료 코드 1, 모두 통과하면 0.

const SECTIONS: Array[String] = [
	"dirty_undo",
	"shortcuts",
	"far_stroke",
	"trim",
	"import",
	"roundtrip",
	"open",
	"test_flow",
	"view",
	"hit_zoom",
	"pointer_release",
	"stroke_quality",
	"length",
	"autofix_review",
	"publish_clamp",
	"edit_button",
	"item_tool",
	"item_lat_cross",
	"item_review",
	"fabric_width",
	"issue_list",
	"roundtrip_ui",
	"play_items",
	"fix_bulk_resolve",
	"fix_undo_selection",
	"fix_import_guard",
	"fix_close_autofix",
	"fix_dup_legacy",
	"fix_fit_zoom",
	"fix_saved_path",
	"erase_end_start",
	"erase_mid_gap",
	"erase_join",
	"erase_loop_zoom",
	"erase_cancel",
	"erase_roundtrip",
	"erase_session",
	"erase_guard",
	"erase_view_jump",
]
const MIN_PASSED: int = 400


func _ready() -> void:
	# current_scene을 빈 노드로 돌려 change_scene_to_file이 이 검사 노드를 지우지 않게 한다.
	var holder: Node = Node.new()
	holder.name = "SceneHolder"
	get_tree().root.add_child.call_deferred(holder)
	await _frames(2)
	get_tree().current_scene = holder
	LeaderboardClient.tutorial_seen = true
	await _check_dirty_undo()
	await _check_shortcuts()
	await _check_far_stroke()
	await _check_trim()
	await _check_import()
	await _check_roundtrip()
	await _check_open()
	# 구간 지우기 검사는 테스트 주행을 한 번 거치므로, 주행 오디오가 종료 시점까지 남지 않게 앞쪽에서 돈다.
	await _check_erase()
	await _check_test_flow()
	await _check_view()
	await _check_hit_zoom()
	await _check_pointer_release()
	await _check_stroke_quality()
	await _check_length()
	await _check_autofix_review()
	_check_publish_clamp()
	await _check_edit_button()
	await _check_item_tool()
	await _check_item_lat_and_cross()
	await _check_item_review()
	await _check_fabric_width()
	await _check_issue_list()
	await _check_roundtrip_ui()
	await _check_play_items()
	await _check_fix_bulk_resolve()
	await _check_fix_undo_selection()
	await _check_fix_import_guard()
	await _check_fix_close_autofix()
	_check_fix_dup_legacy()
	await _check_fix_fit_zoom()
	await _check_fix_saved_path()
	for s in SECTIONS:
		_ok(_done.has(s), "section completed: " + s)
	_ok(_passed >= MIN_PASSED, "at least %d assertions ran (got %d)" % [MIN_PASSED, _passed])
	print("track editor regression: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check_test_flow() -> void:
	var ed: Control = await _change_to_editor()
	_ok(_scene_path() == GameState.EDITOR_SCENE, "editor scene opened")
	ed._canvas.set_view(ZOOM, ed._canvas.size * 0.5)
	# 미검증 → 출발 안 함
	ed._test_play()
	await _frames(2)
	_ok(_scene() == ed and not GameState.is_editor_test(), "unvalidated: no test start")
	await _draw_valid(ed)
	ed._name_edit.text = ""
	# 미저장 → 확인창, 취소하면 출발 안 함
	ed._test_play()
	_ok(ed._confirm.dialog_text.contains("Custom Track"), "new track save confirm names track")
	_confirm_cancel(ed)
	await _frames(2)
	_ok(_scene() == ed and str(ed._doc["local_id"]) == "", "cancel: not saved, not started")
	# 저장 실패 → 출발 안 함
	var dir_abs: String = ProjectSettings.globalize_path(TrackLoader.CUSTOM_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	OS.execute("chmod", ["a-w", dir_abs])
	ed._test_play()
	_confirm_accept(ed)
	await _frames(2)
	OS.execute("chmod", ["u+w", dir_abs])
	_ok(_scene() == ed and not GameState.is_editor_test(), "save failure: no test start")
	_ok(ed._status_label.text.contains("저장 실패"), "save failure reported: " + ed._status_label.text)
	# 저장 후 테스트 → 스냅샷 보관, editor_test 진입
	ed._name_edit.text = "Flow Track"
	ed._name_edit.text_changed.emit("Flow Track")
	ed._set_mode(DrawCanvas.Mode.TRIM)
	ed._canvas.set_view(0.42, Vector2(611.0, 377.0))
	ed._test_play()
	_confirm_accept(ed)
	var id: String = str(GameState.editor_session.get("doc", {}).get("local_id", ""))
	_ok(id.begins_with("custom_") and GameState.is_editor_test(), "save+test: editor_test source")
	var snap: Dictionary = GameState.editor_session.duplicate(true)
	var snap_serial: String = EditorDoc.serial(snap["doc"])
	var snap_undo: int = (snap["undo"] as Array).size()
	await _frames(3)
	_ok(_scene_path() == GameState.GAMEPLAY_SCENE, "gameplay entered")
	_ok(GameState.track_id == id, "gameplay runs saved track")
	# 일시정지 → 편집 복귀 버튼/안내, 재시작은 출처 유지
	var rd: Node = _scene()
	rd._toggle_pause()
	var hud: Node = rd.get_node("HUD")
	_ok(str(hud.get_node("PauseOverlay/PauseHint").text).contains("편집"), "pause hint: back to editor")
	_ok(hud.get_node_or_null("PauseOverlay/EditorReturnButton") != null, "pause has editor button")
	rd._restart()
	await _frames(3)
	_ok(_scene_path() == GameState.GAMEPLAY_SCENE and _scene() != rd, "restart reloads gameplay")
	_ok(GameState.is_editor_test() and GameState.has_editor_session(), "restart keeps test source")
	rd = _scene()
	rd._toggle_pause()
	rd._to_menu()
	await _frames(3)
	ed = _scene() as Control
	_ok(_scene_path() == GameState.EDITOR_SCENE, "pause M returns to editor")
	_check_restored(ed, snap, snap_serial, snap_undo, "pause")
	# redo가 있는 상태로 다시 테스트(저장돼 있으면 확인 없이 바로)
	ed._fabric_option.select(3)
	ed._fabric_option.item_selected.emit(3)
	ed._undo()
	_ok(ed._redo_stack.size() == 1 and not ed._needs_save(), "redo pending, no save needed")
	ed._test_play()
	_ok(not ed._confirm.visible, "saved doc: test starts without confirm")
	snap = GameState.editor_session.duplicate(true)
	await _frames(3)
	# 완주 → 기록·제출 없음
	rd = _scene()
	var best_before: Dictionary = RecordStore.best_for(id, GameState.difficulty)
	rd._finish()
	_ok(RecordStore.best_for(id, GameState.difficulty) == best_before, "test finish: no personal best")
	_ok(bool(rd._pending_result.get("editor_test", false)), "result marked editor_test")
	_ok(not bool(rd._pending_result.get("is_new_record", true)), "test result not new record")
	rd._go_to_result()
	await _frames(4)
	_ok(_scene_path() == "res://scenes/Result.tscn", "result screen shown")
	var res: Node = _scene()
	_ok(str(res._menu_button.text) == "편집으로 돌아가기", "result primary: back to editor")
	_ok(res._menu_button.get_index() == 0, "back-to-editor is first button")
	_ok(str(res._retry_button.text) == "다시 테스트", "result secondary: retest")
	_ok(not res._submit_button.visible, "test result: submit hidden")
	_ok(str(res._submit_status.text).contains("기록을 저장하지 않습니다"), "test result: no-record note")
	var conns: int = LeaderboardClient.submit_completed.get_connections().size()
	res._on_submit_pressed()
	_ok(
		LeaderboardClient.submit_completed.get_connections().size() == conns,
		"test result: submit guarded at call"
	)
	# 다시 테스트 → 출처 유지
	res._on_retry_pressed()
	await _frames(3)
	_ok(
		_scene_path() == GameState.GAMEPLAY_SCENE and GameState.is_editor_test(),
		"retest keeps source"
	)
	rd = _scene()
	rd._finish()
	rd._go_to_result()
	await _frames(4)
	res = _scene()
	res._on_menu_pressed()
	await _frames(3)
	ed = _scene() as Control
	_ok(_scene_path() == GameState.EDITOR_SCENE, "result returns to editor")
	_check_restored(ed, snap, EditorDoc.serial(snap["doc"]), (snap["undo"] as Array).size(), "result")
	_ok(ed._redo_stack.size() == 1, "redo stack restored")
	# 에디터 나가기 → 출처 정리
	ed._on_back()
	await _frames(3)
	_ok(not GameState.is_editor_test() and GameState.editor_session.is_empty(), "exit clears source")
	# 일반 플레이는 기존대로 기록
	GameState.start_run(id, "normal")
	await _frames(3)
	rd = _scene()
	_ok(not GameState.is_editor_test(), "normal run source")
	rd._finish()
	_ok(not RecordStore.best_for(id, "normal").is_empty(), "normal finish records best")
	_ok(not rd._pending_result.has("editor_test"), "normal result not marked")
	rd._go_to_result()
	await _frames(4)
	res = _scene()
	_ok(
		str(res._menu_button.text) == "Menu" and res._menu_button.get_index() == 1,
		"normal result buttons"
	)
	# 다음 구획은 이 노드의 자식 에디터로 검사하므로 전체 화면 씬을 내려 입력을 가리지 않게 한다.
	get_tree().unload_current_scene()
	await _frames(3)
	_done.append("test_flow")


func _check_restored(
	ed: Control, snap: Dictionary, serial: String, n_undo: int, tag: String
) -> void:
	_ok(EditorDoc.serial(ed._doc) == serial, tag + ": doc restored")
	_ok(str(ed._doc["local_id"]) == str(snap["doc"]["local_id"]), tag + ": local id restored")
	_ok(ed._undo_stack.size() == n_undo, tag + ": undo restored (%d)" % ed._undo_stack.size())
	var view: Dictionary = ed._canvas.get_view()
	_ok(
		(
			is_equal_approx(float(view["zoom"]), float(snap["view"]["zoom"]))
			and (view["pan"] as Vector2).is_equal_approx(snap["view"]["pan"])
		),
		tag + ": zoom/pan restored %s" % str(view)
	)
	_ok(ed._canvas.mode == int(snap["view"]["tool"]), tag + ": tool restored")
	_ok(ed._is_validated() and not ed._testplay_button.disabled, tag + ": validation restored")
	_ok(not ed._is_dirty(), tag + ": clean after restore")
	_ok(
		not GameState.is_editor_test() and GameState.editor_session.is_empty(),
		tag + ": session consumed"
	)
