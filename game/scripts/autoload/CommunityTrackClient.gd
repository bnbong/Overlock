extends Node
## 공유 허브 HTTP 클라이언트 오토로드(계획서 §3, server/README.md "커스텀 트랙 공유 허브 API").
##
## 목록·상세·게시·삭제 네 가지 요청만 담당한다. 서버 주소와 온라인 여부는 LeaderboardClient의
## 설정(api_base_url·is_online_enabled)을 그대로 쓰되, 점수 제출 책임과는 섞지 않는다.
##
## 호출 규약:
##  - list/detail/publish/delete는 요청 번호(int, 1 이상)를 돌려주고 결과는 completed 시그널 한
##    곳으로 알린다. 화면은 자기가 보낸 요청 번호와 결과의 request_id가 같을 때만 반영한다
##    (화면 이동 뒤 다시 들어온 화면이 이전 화면의 늦은 응답을 받는 경우를 막는다).
##  - 오프라인 같은 가드 실패도 다음 프레임에 시그널로 알린다(요청 번호를 먼저 받은 뒤 도착).
##  - list/detail은 같은 종류의 새 요청이 오면 진행 중인 이전 요청을 취소한다(늦은 응답 폐기).
##    cancel(kind)/cancel_reads()로 명시적으로 취소할 수 있고, 취소된 요청은 시그널을 내지 않는다.
##  - publish/delete는 같은 종류가 진행 중이면 새 요청을 받지 않고 0을 돌려준다(연타·중복 업로드
##    방지). 업로드는 자동 재시도하지 않는다. 이미 서버로 보낸 게시·삭제는 취소하지 않고 이
##    오토로드가 끝까지 받아, 게시 성공 시 삭제 토큰을 CommunityStore에 저장하고 삭제 요청이
##    204(삭제됨)·404(이미 없음)로 끝났을 때만 토큰 기록을 지운다. 상세 조회 404 로는 지우지 않는다.
##  - 게시 성공 후 토큰 저장에 실패하면 토큰을 이 오토로드 메모리(unsaved_tokens)에도 보관한다.
##    허브 화면은 다시 들어올 때 이를 복사 가능한 화면으로 보여 주고, 저장 재시도에 성공하거나
##    사용자가 보관을 확인하면 비운다(retry_unsaved_token·dismiss_unsaved_token). 게임을 끝내면 사라진다.
##
## 결과 dict: {kind, request_id, ok(bool), status(String), code(int), message(String),
##   errors(Array[String]), data(Dictionary)}.
##   status: ok | network_error | timeout | rate_limited | not_found | validation_error
##           | too_large | forbidden | server_error | offline
## 게시 결과에는 token_saved(bool)가 더 붙는다. 토큰 저장에 실패했을 때만 data.delete_token에
## 토큰을 남겨 화면이 복사할 수 있게 하고, 저장에 성공하면 결과에서 토큰을 지운다. 201 응답의 id·
## 토큰은 유효한데 나머지 상세 필드가 어긋나면 게시 성공으로 보고 data.partial=true 로 알린다(상세는
## 다시 조회). id·토큰조차 읽을 수 없으면 ok=false 에 maybe_published=true 를 붙인다(재게시 금지 안내).
## 오류 문구(message)는 요청 종류별로 다르다(목록 404 = 허브 없는 서버, 상세 404 = 없는 게시물,
## 삭제 401/403 = 삭제 권한 없음, 목록·상세 401/403 = 일반 접근 오류).
## 이 스크립트는 토큰·요청 본문을 print/push_* 로그에 쓰지 않는다.

signal completed(result: Dictionary)

const API_PATH: String = "/api/community/tracks"
const LIST_LIMIT: int = 20
const LIST_LIMIT_MAX: int = 50
const QUERY_MAX: int = 80
const TITLE_MAX: int = 80
const AUTHOR_MAX: int = 32
const DESCRIPTION_MAX: int = 1000
# 초. 목록·상세·삭제는 짧게, 게시는 본문(최대 1MiB)을 고려해 조금 길게 둔다.
const READ_TIMEOUT: float = 10.0
const PUBLISH_TIMEOUT: float = 20.0
# 응답 본문 상한(바이트). 상세 응답은 트랙 JSON 을 포함하지만 서버 업로드 상한(1MiB)을 넘지 않는다.
const BODY_SIZE_LIMIT: int = 2 * 1048576
# 목록 total/offset 클램프 상한(비정상 응답이 표시·페이지 계산을 흔들지 않게).
const LIST_COUNT_MAX: int = 1000000
# 422 detail 에서 뽑는 메시지 수·길이 상한(서버는 최대 20건).
const DETAIL_MSG_MAX: int = 20
const DETAIL_MSG_LEN: int = 200

const KINDS: Array = ["list", "detail", "publish", "delete"]

# 트랙 선택 화면 → 허브 화면 전환 사이의 게시 대상(로컬 custom_ id). 비어 있으면 허브 목록으로
# 진입한다. 씬 전환 사이 상태 버스(LeaderboardClient.view_track_id 와 같은 관례)이며 HTTP 와 무관하다.
var pending_publish_track_id: String = ""
# 요청 제한 시간(초). 기본은 위 상수이며 회귀 검사가 시간 초과 분기를 짧게 확인할 때만 바꾼다.
var read_timeout: float = READ_TIMEOUT
var publish_timeout: float = PUBLISH_TIMEOUT

# 게시에 성공했지만 CommunityStore 에 저장하지 못한 토큰들(메모리 전용, 파일·로그에 쓰지 않는다).
# 각 항목: {post_id, delete_token, title, published_at, source_track_id}.
var unsaved_tokens: Array = []

var _next_id: int = 0
# kind → 진행 중 요청 {id, http(HTTPRequest)}. 비어 있으면 진행 중 아님.
var _active: Dictionary = {}


## 진행 중인 요청이 있는지.
func is_busy(kind: String) -> bool:
	return _active.has(kind)


## 공개 목록. q는 제목 검색어(앞뒤 공백 제거, 최대 80자). 진행 중인 목록 요청은 취소한다.
func list(q: String = "", offset: int = 0, limit: int = LIST_LIMIT) -> int:
	var query: String = q.strip_edges()
	if query.length() > QUERY_MAX:
		query = query.substr(0, QUERY_MAX)
	var lim: int = clampi(limit, 1, LIST_LIMIT_MAX)
	var off: int = clampi(offset, 0, LIST_COUNT_MAX)
	var url: String = "%s?limit=%d&offset=%d" % [_url(""), lim, off]
	if not query.is_empty():
		url += "&q=" + query.uri_encode()
	return _start(
		"list", HTTPClient.METHOD_GET, url, "", PackedStringArray(),
		{"q": query, "limit": lim, "offset": off}
	)


## 게시물 상세. 형식이 틀린 id는 요청하지 않고 not_found로 알린다.
func detail(post_id: String) -> int:
	if not CommunityStore.is_valid_post_id(post_id):
		return _fail_later("detail", "not_found", "게시물을 찾을 수 없습니다")
	return _start(
		"detail", HTTPClient.METHOD_GET, _url("/" + post_id), "", PackedStringArray(),
		{"post_id": post_id}
	)


## 게시. track은 TrackLoader.build_publish_track이 허용 필드만 추린 dict. 같은 종류가 진행 중이면
## 0(요청하지 않음). 제목·작성자·설명 길이는 서버 규칙과 같게 앞에서 거른다(서버가 최종 판정).
func publish(
	title: String, author_name: String, description: String, track: Dictionary,
	source_track_id: String = ""
) -> int:
	if is_busy("publish"):
		return 0
	var t: String = title.strip_edges()
	var a: String = author_name.strip_edges()
	var d: String = description.strip_edges()
	var local_err: String = ""
	if t.is_empty() or t.length() > TITLE_MAX:
		local_err = "제목은 1~%d자로 입력하세요" % TITLE_MAX
	elif a.is_empty() or a.length() > AUTHOR_MAX:
		local_err = "작성자 표시명은 1~%d자로 입력하세요" % AUTHOR_MAX
	elif d.length() > DESCRIPTION_MAX:
		local_err = "설명은 최대 %d자입니다" % DESCRIPTION_MAX
	elif track.is_empty():
		local_err = "게시할 트랙이 없습니다"
	if not local_err.is_empty():
		return _fail_later("publish", "validation_error", local_err, [local_err])
	var body: Dictionary = {"title": t, "author_name": a, "description": d, "track": track}
	return _start(
		"publish", HTTPClient.METHOD_POST, _url(""), JSON.stringify(body), PackedStringArray(),
		{"title": t, "source_track_id": source_track_id}
	)


## 게시물 삭제. 이 기기에 저장된 삭제 토큰으로 요청한다. 토큰이 없으면 forbidden으로 알린다.
## 같은 종류가 진행 중이면 0.
func delete_post(post_id: String) -> int:
	if is_busy("delete"):
		return 0
	var token: String = CommunityStore.token_for(post_id)
	if not CommunityStore.is_valid_post_id(post_id) or token.is_empty():
		return _fail_later("delete", "forbidden", "이 기기에 삭제 권한(토큰)이 없습니다")
	var headers: PackedStringArray = PackedStringArray(["Authorization: Bearer " + token])
	return _start(
		"delete", HTTPClient.METHOD_DELETE, _url("/" + post_id), "", headers, {"post_id": post_id}
	)


## kind 요청을 취소한다. 취소된 요청은 시그널을 내지 않는다. 게시·삭제는 서버로 이미 보냈을 수
## 있어 취소하지 않는다(결과 처리와 토큰 저장을 이 오토로드가 끝까지 수행) — false 반환.
func cancel(kind: String) -> bool:
	if kind == "publish" or kind == "delete":
		return false
	if not _active.has(kind):
		return false
	var entry: Dictionary = _active[kind]
	_active.erase(kind)
	var http: HTTPRequest = entry["http"]
	if is_instance_valid(http):
		http.cancel_request()
		http.queue_free()
	return true


## 화면을 떠날 때: 목록·상세 요청을 모두 취소한다.
func cancel_reads() -> void:
	cancel("list")
	cancel("detail")


## 저장하지 못한 토큰 중 가장 먼저 쌓인 것(복사본). 없으면 빈 dict.
func first_unsaved_token() -> Dictionary:
	return (unsaved_tokens[0] as Dictionary).duplicate() if not unsaved_tokens.is_empty() else {}


## 저장하지 못한 토큰을 CommunityStore 에 다시 저장해 본다. 성공하면 메모리에서 지우고 true.
func retry_unsaved_token(post_id: String) -> bool:
	for i in range(unsaved_tokens.size()):
		var e: Dictionary = unsaved_tokens[i]
		if str(e["post_id"]) != post_id:
			continue
		var saved: bool = CommunityStore.remember_published(
			post_id, str(e["delete_token"]), str(e["title"]), str(e["published_at"]),
			str(e["source_track_id"])
		)
		if saved:
			unsaved_tokens.remove_at(i)
		return saved
	return false


## 사용자가 토큰을 따로 보관했다고 확인하면 메모리에서 지운다.
func dismiss_unsaved_token(post_id: String) -> void:
	for i in range(unsaved_tokens.size() - 1, -1, -1):
		if str((unsaved_tokens[i] as Dictionary)["post_id"]) == post_id:
			unsaved_tokens.remove_at(i)


# --- 내부 ---


func _url(suffix: String) -> String:
	return LeaderboardClient.api_base_url() + API_PATH + suffix


func _new_id() -> int:
	_next_id += 1
	return _next_id


## 요청 없이 실패를 다음 프레임에 알린다(호출자가 요청 번호를 먼저 받도록).
func _fail_later(kind: String, status: String, message: String, errors: Array = []) -> int:
	var id: int = _new_id()
	var result: Dictionary = _result(kind, id, status, 0, message)
	result["errors"] = errors
	_emit_deferred.call_deferred(result)
	return id


func _emit_deferred(result: Dictionary) -> void:
	completed.emit(result)


func _start(
	kind: String, method: int, url: String, body: String, extra_headers: PackedStringArray,
	ctx: Dictionary
) -> int:
	if not LeaderboardClient.is_online_enabled():
		return _fail_later(kind, "offline", "오프라인 (서버 주소 미설정)")
	cancel(kind)  # list/detail: 이전 요청 폐기. publish/delete는 호출부에서 진행 중 여부를 막았다.
	var id: int = _new_id()
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = publish_timeout if kind == "publish" else read_timeout
	http.body_size_limit = BODY_SIZE_LIMIT
	# LeaderboardClient._request 와 같은 웹 export 회피책(브라우저가 이미 푼 gzip 을 다시 풀지 않게).
	if OS.has_feature("web"):
		http.accept_gzip = false
	add_child(http)
	var headers: PackedStringArray = request_headers(method, extra_headers)
	_active[kind] = {"id": id, "http": http}
	http.request_completed.connect(_on_http_done.bind(kind, id, ctx))
	var err: int = http.request(url, headers, method, body)
	if err != OK:
		_active.erase(kind)
		http.queue_free()
		_emit_deferred.call_deferred(_result(kind, id, "network_error", 0, "요청을 보내지 못했습니다"))
	return id


## 요청 헤더. Content-Type 은 본문이 있는 POST 에만 붙인다(웹에서 GET·DELETE 가 불필요한 CORS
## preflight 를 일으키지 않게. DELETE 는 Authorization 때문에 preflight 가 필요하며 서버가 허용한다).
static func request_headers(method: int, extra_headers: PackedStringArray) -> PackedStringArray:
	var headers: PackedStringArray = PackedStringArray(["Accept: application/json"])
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
	headers.append_array(extra_headers)
	return headers


func _on_http_done(
	result_code: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray,
	kind: String, id: int, ctx: Dictionary
) -> void:
	var entry: Dictionary = _active.get(kind, {})
	if entry.is_empty() or int(entry["id"]) != id:
		return  # 취소·대체된 요청의 늦은 응답은 버린다.
	_active.erase(kind)
	var http: HTTPRequest = entry["http"]
	if is_instance_valid(http):
		http.queue_free()
	var res: Dictionary = classify(result_code, response_code, body.get_string_from_utf8(), kind)
	var out: Dictionary = _result(kind, id, str(res["status"]), response_code, str(res["message"]))
	out["errors"] = res["errors"]
	if bool(out["ok"]):
		var parsed: Dictionary = _parse_ok(kind, res["json"], ctx)
		if kind == "delete" and response_code != 204:
			parsed = {"ok": false, "data": {}}  # 계약은 204 뿐이다. 그 밖의 2xx 로는 토큰을 지우지 않는다.
		if not bool(parsed["ok"]):
			out["ok"] = false
			out["status"] = "server_error"
			out["message"] = "서버 응답 형식이 올바르지 않습니다"
			if kind == "publish":
				out["maybe_published"] = true
				out["message"] = (
					"서버 응답을 해석하지 못했습니다. 게시되었을 수 있으니 다시 게시하지 말고 "
					+ "목록에서 확인하세요."
				)
		else:
			out["data"] = parsed["data"]
	_after(kind, out, ctx)
	completed.emit(out)


## 게시·삭제 결과의 로컬 후처리(토큰 저장·정리). 화면 존재 여부와 무관하게 수행한다.
func _after(kind: String, out: Dictionary, ctx: Dictionary) -> void:
	if kind == "publish" and bool(out["ok"]):
		var data: Dictionary = out["data"]
		if str(data.get("title", "")).is_empty():
			data["title"] = str(ctx.get("title", ""))
		var entry: Dictionary = {
			"post_id": str(data["id"]),
			"delete_token": str(data["delete_token"]),
			"title": str(data["title"]),
			"published_at": str(data.get("created_at", "")),
			"source_track_id": str(ctx.get("source_track_id", "")),
		}
		var saved: bool = CommunityStore.remember_published(
			entry["post_id"], entry["delete_token"], entry["title"], entry["published_at"],
			entry["source_track_id"]
		)
		out["token_saved"] = saved
		if saved:
			data.erase("delete_token")
		else:
			unsaved_tokens.append(entry)  # 화면이 이미 사라졌어도 다음 허브 진입 때 보여 준다.
	elif kind == "delete":
		var post_id: String = str(ctx.get("post_id", ""))
		# 삭제 요청의 204(삭제됨)·404(이미 없음)일 때만 이 기기의 토큰 기록을 지운다.
		var code: int = int(out["code"])
		if (bool(out["ok"]) and code == 204) or (str(out["status"]) == "not_found" and code == 404):
			CommunityStore.forget_published(post_id)
		out["data"] = {"post_id": post_id}


func _result(kind: String, id: int, status: String, code: int, message: String) -> Dictionary:
	return {
		"kind": kind,
		"request_id": id,
		"ok": status == "ok",
		"status": status,
		"code": code,
		"message": message,
		"errors": [],
		"data": {},
	}


## HTTPRequest 결과 → {status, message, errors(Array[String]), json(Variant)}. 순수 함수라 검사에서
## 합성 입력으로 분기를 확인할 수 있다. 422 는 detail 목록의 msg만, 그 밖의 오류는 detail 문자열을
## 쓰지 않고 상태별 고정 문구를 쓴다(서버 문구가 바뀌어도 화면 표시가 흔들리지 않게). kind 는 요청
## 종류(list|detail|publish|delete)이며 404·401·403 문구를 나누는 데만 쓴다.
static func classify(
	result_code: int, response_code: int, body_text: String, kind: String = ""
) -> Dictionary:
	var out: Dictionary = {"status": "", "message": "", "errors": [], "json": null}
	if result_code != HTTPRequest.RESULT_SUCCESS:
		if result_code == HTTPRequest.RESULT_TIMEOUT:
			out["status"] = "timeout"
			out["message"] = "서버 응답 없음 (시간 초과)"
		else:
			out["status"] = "network_error"
			out["message"] = "서버에 연결할 수 없음"
		return out
	if response_code >= 200 and response_code < 300:
		out["status"] = "ok"
		out["json"] = JSON.parse_string(body_text) if not body_text.is_empty() else null
		return out
	match response_code:
		404:
			out["status"] = "not_found"
			match kind:
				"list", "publish":
					out["message"] = "공유 허브를 사용할 수 없는 서버입니다 (HTTP 404)"
				"delete":
					out["message"] = "이미 삭제되었거나 없는 게시물입니다"
				_:
					out["message"] = "삭제되었거나 없는 게시물입니다"
		413:
			out["status"] = "too_large"
			out["message"] = "업로드 크기가 너무 큽니다"
		422:
			out["status"] = "validation_error"
			out["errors"] = _detail_messages(body_text)
			out["message"] = (
				"검증 실패: " + str(out["errors"][0]) if not out["errors"].is_empty() else "검증 실패"
			)
		429:
			out["status"] = "rate_limited"
			out["message"] = "요청이 너무 잦습니다. 잠시 후 다시 시도하세요"
		401, 403:
			out["status"] = "forbidden"
			if kind == "delete":
				out["message"] = "삭제 권한이 없습니다 (토큰이 맞지 않음)"
			else:
				out["message"] = "서버가 요청을 거부했습니다 (HTTP %d)" % response_code
		_:
			out["status"] = "server_error"
			out["message"] = "서버 오류 (HTTP %d)" % response_code
	return out


## 422 본문 {"detail": [{loc,msg,type}]} 에서 msg 목록(각 최대 200자, 최대 20개, 표시용으로 정리)을
## 뽑는다.
static func _detail_messages(body_text: String) -> Array:
	var msgs: Array = []
	var parsed: Variant = JSON.parse_string(body_text)
	if not (parsed is Dictionary):
		return msgs
	var detail: Variant = (parsed as Dictionary).get("detail", null)
	if detail is Array:
		for e in detail:
			if e is Dictionary and (e as Dictionary).has("msg"):
				var m: String = _plain(e["msg"], DETAIL_MSG_LEN)
				if not m.is_empty():
					msgs.append(m)
			if msgs.size() >= DETAIL_MSG_MAX:
				break
	elif detail is String:
		msgs.append(_plain(detail, DETAIL_MSG_LEN))
	return msgs


## 2xx 응답 본문을 kind별로 검사·정리한다. {ok, data}. 서버가 준 임의 키는 싣지 않는다.
func _parse_ok(kind: String, json: Variant, ctx: Dictionary) -> Dictionary:
	var out: Dictionary = {"ok": false, "data": {}}
	match kind:
		"list":
			out = _parse_list(json, int(ctx.get("limit", LIST_LIMIT)), int(ctx.get("offset", 0)))
		"detail":
			out = _parse_detail(json)
			if bool(out["ok"]) and str(out["data"]["id"]) != str(ctx.get("post_id", "")):
				out = {"ok": false, "data": {}}
		"publish":
			out = _parse_created(json)
		"delete":
			out = {"ok": true, "data": {}}
	return out


## 게시 201 응답: id·delete_token 형식이 맞으면 토큰을 살린다. 나머지 상세 필드까지 맞으면 전체
## 상세, 어긋나면 {id, delete_token, title, created_at, partial=true} 만 돌려준다(게시는 성공).
static func _parse_created(json: Variant) -> Dictionary:
	if not (json is Dictionary):
		return {"ok": false, "data": {}}
	var d: Dictionary = json
	var id: String = str(d.get("id", "")) if d.get("id", null) is String else ""
	var raw_token: Variant = d.get("delete_token", null)
	var token: String = str(raw_token) if raw_token is String else ""
	if not CommunityStore.is_valid_post_id(id) or not CommunityStore.is_valid_token(token):
		return {"ok": false, "data": {}}
	var p: Dictionary = _parse_detail(json)
	if not bool(p["ok"]):
		p = {
			"ok": true,
			"data":
			{
				"id": id,
				"title": _plain(d.get("title", ""), TITLE_MAX),
				"created_at": _plain(d.get("created_at", ""), 40),
				"partial": true,
			},
		}
	p["data"]["delete_token"] = token
	return p


## 목록 응답 정리. 요청한 limit 보다 많은 항목은 잘라내고, count 에 서버가 준(잘라낸 뒤) 항목 수를
## 담는다(형식이 틀려 버린 항목도 서버 offset 소비에는 포함되므로 화면은 count 로 offset 을 전진).
## total 은 [offset+count, LIST_COUNT_MAX], offset 은 [0, LIST_COUNT_MAX] 로 클램프한다.
static func _parse_list(json: Variant, limit: int = LIST_LIMIT, req_offset: int = 0) -> Dictionary:
	if not (json is Dictionary):
		return {"ok": false, "data": {}}
	var d: Dictionary = json
	var raw_items: Variant = d.get("items", null)
	if not (raw_items is Array):
		return {"ok": false, "data": {}}
	var raw: Array = raw_items
	var count: int = mini(raw.size(), clampi(limit, 1, LIST_LIMIT_MAX))
	var items: Array = []
	for i in range(count):
		var s: Dictionary = _summary(raw[i])
		if not s.is_empty():
			items.append(s)
	var off: int = clampi(int(_num_or(d.get("offset", 0), 0)), 0, LIST_COUNT_MAX)
	var total: int = clampi(int(_num_or(d.get("total", 0), 0)), 0, LIST_COUNT_MAX)
	total = clampi(total, mini(maxi(req_offset, 0) + count, LIST_COUNT_MAX), LIST_COUNT_MAX)
	return {
		"ok": true,
		"data": {
			"total": total,
			"offset": off,
			"count": count,
			"q": _plain(d.get("q", ""), QUERY_MAX),
			"items": items,
		},
	}


## 목록 항목 정리. id 형식이 틀리면 빈 dict(항목 제외).
static func _summary(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	var id: String = str(d.get("id", ""))
	if not CommunityStore.is_valid_post_id(id):
		return {}
	return {
		"id": id,
		"title": _plain(d.get("title", ""), TITLE_MAX),
		"author_name": _plain(d.get("author_name", ""), AUTHOR_MAX),
		"difficulty": _plain(d.get("difficulty", ""), 32),
		"fabric": _plain(d.get("fabric", ""), 32),
		"length": maxi(int(_num_or(d.get("length", 0), 0)), 0),
		"created_at": _plain(d.get("created_at", ""), 40),
	}


static func _parse_detail(json: Variant) -> Dictionary:
	var s: Dictionary = _summary(json)
	if s.is_empty():
		return {"ok": false, "data": {}}
	var d: Dictionary = json
	var track: Variant = d.get("track", null)
	var chash: String = str(d.get("content_hash", ""))
	if not (track is Dictionary) or chash.is_empty() or chash.length() > 128:
		return {"ok": false, "data": {}}
	s["description"] = _multiline(d.get("description", ""), DESCRIPTION_MAX)
	s["content_hash"] = chash
	s["track"] = track
	return {"ok": true, "data": s}


## 한 줄 표시용 문자열. 먼저 max_len 으로 자른 뒤(긴 입력에서도 비용이 길이 상한에 묶이게) 줄바꿈 등
## C0 제어 문자는 공백으로 바꾸고, 표시 순서를 바꾸거나 보이지 않는 문자(is_hidden_char)는 지운다.
static func _plain(v: Variant, max_len: int) -> String:
	return _clean(v, max_len, false).strip_edges()


## 여러 줄 표시용(설명). 줄바꿈(\n)만 남기고 나머지 규칙은 _plain 과 같다.
static func _multiline(v: Variant, max_len: int) -> String:
	return _clean(v, max_len, true).strip_edges()


static func _clean(v: Variant, max_len: int, keep_newline: bool) -> String:
	var text: String = (v as String) if v is String else str(v)
	text = text.substr(0, maxi(max_len, 0))
	var parts: PackedStringArray = PackedStringArray()
	for ch in text:
		var c: int = ch.unicode_at(0)
		if keep_newline and c == 10:
			parts.append(ch)
		elif c < 32 or c == 127:
			parts.append(" ")
		elif not is_hidden_char(c):
			parts.append(ch)
	return "".join(parts)


## 서버가 준 표시 문자열에서 지울 문자: 제로폭·방향 표시(U+200B–200F), 방향 내장·재정의(U+202A–202E),
## 방향 격리(U+2066–2069), BOM(U+FEFF), 아랍 문자 표시(U+061C), C1 제어(U+0080–009F).
static func is_hidden_char(c: int) -> bool:
	return (
		(c >= 0x200B and c <= 0x200F)
		or (c >= 0x202A and c <= 0x202E)
		or (c >= 0x2066 and c <= 0x2069)
		or c == 0xFEFF
		or c == 0x061C
		or (c >= 0x80 and c <= 0x9F)
	)


static func _num_or(v: Variant, fallback: float) -> float:
	if (v is float or v is int) and is_finite(float(v)):
		return float(v)
	return fallback
