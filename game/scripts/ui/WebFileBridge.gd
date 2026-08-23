class_name WebFileBridge
extends RefCounted
## 웹(HTML5) 전용 파일 업로드·다운로드 브리지 (커스텀 트랙 공유 Phase 2, track_editor.md §8).
##
## 브라우저에는 데스크톱 FileDialog/드래그드롭이 없으므로 JavaScriptBridge로 대체한다.
##  - 불러오기: 즉석 <input type=file accept=".json"> → FileReader.readAsText → GDScript 콜백.
##  - 내보내기: Godot 내장 download_buffer(Blob + <a download>)로 파일 저장을 트리거.
## 데스크톱에서는 어떤 메서드도 JavaScriptBridge를 건드리지 않는다(호출 측이 web 가드로 분기).
##
## 함정: create_callback가 돌려준 JavaScriptObject를 멤버로 붙잡아 두지 않으면 GC가
## 콜백을 회수해 onchange가 죽는다. _upload_callback로 보관해 브리지 생존 동안 유지한다.

# 업로드 텍스트 크기 상한(1MB). 초과분은 파싱 전에 잘라 too_large로 보고한다.
const MAX_BYTES: int = 1048576

# 즉석 파일 input 생성 → 선택 파일을 텍스트로 읽어 콜백(text, filename, status)을 호출한다.
# 콜백은 window.__overlock_upload_cb(아래 GDScript에서 매단 전역)로 참조한다.
const _PICK_JS: String = """
(function() {
	var cb = window.__overlock_upload_cb;
	if (!cb) { return; }
	var input = document.createElement('input');
	input.type = 'file';
	input.accept = '.json,application/json';
	input.style.position = 'fixed';
	input.style.left = '-1000px';
	function cleanup() {
		if (input.parentNode) { input.parentNode.removeChild(input); }
	}
	input.onchange = function() {
		var f = input.files && input.files[0];
		if (!f) { cb('', '', 'cancel'); cleanup(); return; }
		var reader = new FileReader();
		reader.onload = function() { cb(String(reader.result), f.name, 'ok'); cleanup(); };
		reader.onerror = function() { cb('', f.name, 'error'); cleanup(); };
		reader.readAsText(f);
	};
	document.body.appendChild(input);
	input.click();
})();
"""

# GC 방지용 콜백 참조. 최초 pick_file에서 1회 생성해 재사용한다.
var _upload_callback: JavaScriptObject
# 현재 대기 중인 수신 핸들러. status/text/filename을 넘겨 받는다.
var _on_text: Callable = Callable()


## 브라우저 파일 선택 다이얼로그를 띄운다. 완료 시 on_text.call(status, text, filename)이
## 실행된다. status: "ok" | "cancel" | "error" | "too_large". 데스크톱에서는 무동작.
func pick_file(on_text: Callable) -> void:
	if not OS.has_feature("web"):
		return
	_on_text = on_text
	if _upload_callback == null:
		_upload_callback = JavaScriptBridge.create_callback(_receive)
		# Variant로 받아 동적 프로퍼티 할당을 허용한다(JavaScriptObject 정적 검사 회피).
		var window: Variant = JavaScriptBridge.get_interface("window")
		if window != null:
			window.__overlock_upload_cb = _upload_callback
	JavaScriptBridge.eval(_PICK_JS, true)


## JS 콜백 수신부. args = [text, filename, status]. 크기 상한 초과분은 여기서 거른다.
func _receive(args: Array) -> void:
	var text: String = str(args[0]) if args.size() > 0 else ""
	var fname: String = str(args[1]) if args.size() > 1 else ""
	var status: String = str(args[2]) if args.size() > 2 else "ok"
	if status == "ok" and text.to_utf8_buffer().size() > MAX_BYTES:
		status = "too_large"
		text = ""
	if _on_text.is_valid():
		_on_text.call(status, text, fname)


## 텍스트를 파일로 다운로드시킨다(Blob + <a download>, 내장 download_buffer). 데스크톱 무동작.
func download_text(filename: String, text: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), filename, "application/json")
