extends Node
func _ready() -> void:
	await get_tree().process_frame
	var ed = load("res://scenes/TrackEditor.tscn").instantiate()
	get_tree().root.add_child(ed)
	get_tree().current_scene = ed
	await get_tree().process_frame
	await get_tree().process_frame
	var cv = ed.get_node("Canvas")
	cv._reset_view()
	print("AUDIT initial_zoom=", cv._zoom, " min=", cv.ZOOM_MIN)
	print("AUDIT fabric_count=", ed.get_node("MetaPanel/Row1/FabricOption").item_count)
	var pts: Array = []
	for i in range(1001): pts.append([i * 6.0, 0.0])
	var data = {"name":"Audit 6000", "difficulty":"normal", "fabric":"silk", "width":{"perfect":18,"safe":42,"fail":90}, "path":[{"type":"polyline","points":pts,"closed":false}], "items":[{"s":600,"type":"thimble","lat":0}]}
	ed._import_from_text(JSON.stringify(data))
	print("AUDIT imported_length=", ed._current_length(), " validated=", ed._validated, " exported_items=", ed._build_track_dict().get("items", "MISSING"), " fabric=", ed._build_track_dict()["fabric"])
	ed._length_fit()
	print("AUDIT fitted_length=", ed._current_length(), " validated=", ed._validated)
	ed._save()
	print("AUDIT saved=", ed._saved_id != "", " dirty=", ed._dirty)
	ed.get_node("MetaPanel/Row1/NameEdit").text = "Changed after save"
	ed.get_node("MetaPanel/Row1/NameEdit").text_changed.emit("Changed after save")
	ed.get_node("MetaPanel/Row1/FabricOption").select(1)
	ed.get_node("MetaPanel/Row1/FabricOption").item_selected.emit(1)
	print("AUDIT after_metadata_edit_dirty=", ed._dirty, " test_enabled=", not ed._testplay_button.disabled)
	ed._test_play()
	await get_tree().process_frame
	await get_tree().process_frame
	print("AUDIT test_scene=", get_tree().current_scene.scene_file_path)
	var rd = get_tree().current_scene
	if rd != null:
		rd._to_menu()
		await get_tree().process_frame
		await get_tree().process_frame
		print("AUDIT pause_exit_scene=", get_tree().current_scene.scene_file_path)
	var result = load("res://scenes/Result.tscn").instantiate()
	get_tree().root.add_child(result)
	result._on_menu_pressed()
	await get_tree().process_frame
	await get_tree().process_frame
	print("AUDIT result_exit_scene=", get_tree().current_scene.scene_file_path)
	result.free()
	get_tree().quit()
