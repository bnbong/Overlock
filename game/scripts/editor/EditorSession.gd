class_name EditorSession
extends RefCounted
## 트랙 에디터 보조 기능(TrackEditor.gd 분리): 테스트 복귀 스냅샷 만들기·복원, 파일 읽기, 속성 패널
## 옵션(난이도·원단 견본) 채우기. 문서·undo는 TrackEditor가 소유하고 여기서는 그 필드를 읽고 쓴다.

# 원단 한국어 이름은 트랙 선택 화면의 표(FABRIC_LABELS)를, 견본은 FabricSurface.swatch_source를
# 그대로 쓴다(공유 허브 화면과 같은 방식, 중복 정의 없음).
const SelectScript = preload("res://scripts/ui/TrackSelectScreen.gd")
const DIFF_KO: Dictionary = {
	"beginner": "초급", "normal": "보통", "expert": "숙련", "master": "마스터"
}


## 편집 세션 스냅샷(문서·저장 기준·검증 기준·undo/redo·화면 상태). 깊은 복사로 보관한다.
static func make(ed: Control) -> Dictionary:
	var view: Dictionary = ed._canvas.get_view()
	return {
		"doc": EditorDoc.copy(ed._doc),
		"undo": (ed._undo_stack as Array).duplicate(true),
		"redo": (ed._redo_stack as Array).duplicate(true),
		"saved_serials": (ed._saved_serials as Dictionary).duplicate(true),
		"validated_geom": ed._validated_geom,
		"next_doc_key": ed._next_doc_key,
		"view": {
			"zoom": float(view["zoom"]),
			"pan": view["pan"],
			"tool": ed._canvas.mode,
			"selected_item": ed._selected_item,
			"place_type": ed._item_tool.place_type,
		},
	}


static func restore(ed: Control, s: Dictionary) -> void:
	ed._doc = EditorDoc.copy(s["doc"])
	ed._undo_stack = (s["undo"] as Array).duplicate(true)
	ed._redo_stack = (s["redo"] as Array).duplicate(true)
	ed._saved_serials = (s["saved_serials"] as Dictionary).duplicate(true)
	ed._validated_geom = str(s["validated_geom"])
	ed._next_doc_key = int(s["next_doc_key"])
	var view: Dictionary = s["view"]
	ed._canvas.set_view(float(view["zoom"]), view["pan"])
	ed._set_mode(int(view["tool"]))
	ed._selected_item = int(view["selected_item"])
	ed._item_tool.place_type = str(view.get("place_type", "thimble"))


## 파일 텍스트 읽기. {text} 또는 {error}.
static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "파일 없음: " + path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "파일 열기 실패"}
	var text: String = file.get_as_text()
	file.close()
	return {"text": text}


## 트랙 id의 원본 텍스트(로컬 커스텀 또는 공식). 없으면 "".
static func track_text(id: String) -> String:
	if id.begins_with(TrackLoader.CUSTOM_PREFIX):
		return TrackLoader.read_custom_track_text(id)
	var r: Dictionary = read_file(TrackLoader.OFFICIAL_DIR + id + ".json")
	return str(r.get("text", ""))


## 난이도(한국어 병기)와 원단(한국어 이름 + 견본 아이콘) 옵션을 채운다. 내부 id 순서는 EditorDoc 그대로.
static func populate_options(diff: OptionButton, fabric: OptionButton) -> void:
	for i in range(EditorDoc.DIFFS.size()):
		var d: Dictionary = EditorDoc.DIFFS[i]
		diff.add_item("%s (%s)" % [str(DIFF_KO.get(str(d["id"]), d["name"])), str(d["name"])], i)
	fabric.add_theme_constant_override("icon_max_width", 24)
	fabric.get_popup().add_theme_constant_override("icon_max_width", 32)
	# 견본 아이콘은 큰 원단 타일 크롭을 축소한 것이라 밉맵 필터로 그린다(조직 깨짐 방지).
	fabric.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	fabric.get_popup().canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	)
	for i in range(EditorDoc.FABRICS.size()):
		var id: String = str(EditorDoc.FABRICS[i])
		var icon: Texture2D = swatch(id)
		var label: String = fabric_name(id)
		if icon != null:
			fabric.add_icon_item(icon, label, i)
		else:
			fabric.add_item(label, i)
		fabric.set_item_tooltip(i, "%s (%s) · %s" % [label, id, FabricProfile.describe(id)])


static func fabric_name(id: String) -> String:
	return str(SelectScript.FABRIC_LABELS.get(id, id))


## 원단 견본 옆 주행 특성 문구 Label을 속성 줄(FabricOption 바로 뒤)에 만든다. 장면 파일은 그대로 두고
## 코드로 붙인다(EditorSkin 크기 조정 전에 호출). 문구·툴팁은 show_fabric_note가 채운다.
static func add_fabric_note(row: Control, after: Control) -> Label:
	var l: Label = Label.new()
	l.name = "FabricNoteLabel"
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_color_override("font_color", Color(0.72, 0.66, 0.56, 1))
	l.add_theme_font_size_override("font_size", 14)
	row.add_child(l)
	row.move_child(l, after.get_index() + 1)
	return l


## 원단 주행 특성 문구(FabricProfile.describe)와 배율 수치 툴팁을 Label에 채운다. 재질 물리를 과장하지
## 않고 배율 차이만 짧게 말한다.
static func show_fabric_note(l: Label, id: String) -> void:
	l.text = "주행: " + FabricProfile.describe(id)
	l.tooltip_text = FabricProfile.detail(id)


static func diff_name(id: String) -> String:
	return str(DIFF_KO.get(id, id))


## 원단 견본(타일 텍스처 가운데를 FabricSurface.swatch_source의 region만큼 잘라 낸 AtlasTexture). 타일
## 파일이 없는 원단은 게임 바닥이 쓰는 대표색 단색 견본을 만든다(트랙 선택 화면의 색 패치 폴백과 같은
## 기준). 미지 재질은 null.
static func swatch(id: String) -> Texture2D:
	var src: Dictionary = FabricSurface.swatch_source(id)
	if not bool(src.get("known", false)):
		return null
	var tex: Texture2D = src.get("texture", null)
	if tex == null:
		var img: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.fill(src["color"])
		return ImageTexture.create_from_image(img)
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = src.get("region", Rect2(Vector2.ZERO, tex.get_size()))
	return atlas


## 폭 표시 문구: 프리셋인지 사용자 지정인지와, 난이도를 고르면 프리셋 폭으로 바뀐다는 안내.
static func width_text(doc: Dictionary) -> String:
	var w: Dictionary = doc["width"]
	var nums: String = "%s/%s/%s" % [
		EditorDoc.fmt(w["perfect"]), EditorDoc.fmt(w["safe"]), EditorDoc.fmt(w["fail"])
	]
	if EditorDoc.is_custom_width(doc):
		return "사용자 지정 폭 %s" % nums
	return "폭 %s (%s 프리셋)" % [nums, diff_name(str(doc["difficulty"]))]


## 실제로 저장될 트랙(to_track_dict: 0.1 격자·중간점 삽입 경로)을 게임과 같은 방식으로 베이크해 기하
## 검증과 아이템 제약(베이크 길이 기준)을 다시 확인한다. 편집 경로로 통과했어도 격자화 때문에 하드
## 경계에서 어긋날 수 있다. 문제가 없으면 빈 문자열, 있으면 사유.
static func check_saved(track: Dictionary) -> String:
	var td: TrackData = TrackData.new()
	td.bake(track["path"])
	var fail: float = float(track["width"]["fail"])
	var res: Dictionary = TrackValidator.new().validate(td.points, fail)
	if not bool(res["ok"]):
		var msgs: Array = res["messages"]
		return "저장될 경로(0.1 격자)가 검증을 통과하지 못합니다 · " + (
			str(msgs[0]) if not msgs.is_empty() else "기하 부적합"
		)
	var bad: String = EditorDoc.items_problem(track["items"], td.length, fail)
	if not bad.is_empty():
		return "저장될 경로 기준 " + bad
	return ""
