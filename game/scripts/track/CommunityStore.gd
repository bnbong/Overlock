class_name CommunityStore
extends RefCounted
## 공유 허브 로컬 저장소(계획서 §3·§5). 트랙 파일과 분리된 user:// JSON 두 개를 관리한다.
##
##  - DOWNLOADS_PATH(user://community/downloads.json): 허브 게시물 id → 로컬 custom_ id 매핑.
##      {"version": 1, "posts": {"<post_id>": {"track_id", "content_hash", "fingerprint",
##       "title", "downloaded_at"}}}
##    content_hash 는 서버가 준 불투명 값(재계산하지 않는다), fingerprint 는 로컬 저장본의
##    플레이 내용 지문(TrackLoader.play_fingerprint)이다. 재다운로드 때 파일 존재와 지문 일치를
##    확인해 재저장 여부를 정한다.
##  - PUBLISHED_PATH(user://community/published.json): 내가 게시한 게시물 id → 삭제 토큰.
##      {"version": 1, "posts": {"<post_id>": {"delete_token", "title", "published_at",
##       "source_track_id"}}}
##    삭제 토큰은 이 파일에만 둔다. 트랙 JSON·내보내기·게시 payload·로그에 싣지 않는다.
##
## 쓰기 절차(_write_posts): 임시 파일(<path>.tmp)에 쓰고 닫은 뒤 다시 읽어 JSON 파싱·내용 일치를
## 확인하고, rename 으로 교체한다. rename 이 기존 파일 교체에 실패하는 플랫폼을 대비해 "기존 파일
## 삭제 후 rename" 으로 한 번 더 시도한다. 그 사이에 실패하면 임시 파일을 남겨 두고, 다음 로드에서
## 본 파일이 없고 유효한 임시 파일이 있으면 임시 파일을 채택한다.
## 읽기 결과는 "파일 없음"과 "읽을 수 없음/손상/버전 불일치"를 구분한다. 파일이 있는데 읽을 수 없거나
## 손상된 경우 읽기는 빈 저장소로 간주하지만, 덮어쓰기 전에 기존 파일을 <path>.bak(이미 있으면
## <path>.bak-<시각>)으로 옮겨 보존한다(특히 published.json 의 삭제 토큰을 잃지 않게).
## 항목 단위로도 형식(게시물 id·custom_ id·토큰 문자 집합)을 검사해 이상한 항목은 버린다.
## 웹 export: user:// 는 IDBFS 이고, 엔진(OS_Web::file_access_close_callback)이 쓰기 모드로 연 user://
## 파일을 닫을 때 동기화 필요 표시를 세운 뒤 메인 루프에서 파일 시스템 전체를 동기화한다. 임시 파일을
## 닫은 직후 같은 프레임에 rename 하므로 교체 결과도 그 동기화에 포함된다. 기존 저장 코드
## (RecordStore._save·TrackLoader.save_custom_track·LeaderboardClient._write_settings)도 명시적 sync
## 없이 이 관례에 기대므로 여기서도 따로 sync 를 호출하지 않는다.

const DIR: String = "user://community/"
const DOWNLOADS_PATH: String = "user://community/downloads.json"
const PUBLISHED_PATH: String = "user://community/published.json"
const FORMAT_VERSION: int = 1
const POST_ID_MAX: int = 64
const TOKEN_MAX: int = 256
const TITLE_MAX: int = 80


## 게시물 id 형식 검사(서버 UUID 문자열). 영숫자와 하이픈만, 1~64자.
static func is_valid_post_id(post_id: String) -> bool:
	if post_id.is_empty() or post_id.length() > POST_ID_MAX:
		return false
	for ch in post_id:
		if not (ch == "-" or _is_alnum(ch)):
			return false
	return true


## 로컬 커스텀 트랙 id 형식 검사(custom_ + 영숫자). 경로 구분자·점을 허용하지 않는다.
static func is_valid_local_id(track_id: String) -> bool:
	if not track_id.begins_with("custom_") or track_id.length() > 40:
		return false
	var rest: String = track_id.substr(7)
	if rest.is_empty():
		return false
	for ch in rest:
		if not _is_alnum(ch):
			return false
	return true


## 삭제 토큰 형식 검사(URL-safe base64 문자 집합, 1~256자). 헤더 주입 문자를 막는다.
static func is_valid_token(token: String) -> bool:
	if token.is_empty() or token.length() > TOKEN_MAX:
		return false
	for ch in token:
		if not (ch == "-" or ch == "_" or _is_alnum(ch)):
			return false
	return true


static func _is_alnum(ch: String) -> bool:
	var c: int = ch.unicode_at(0)
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


# --- 다운로드 매핑 ---


## 검증을 통과한 다운로드 매핑 전체({post_id: entry}). 파일이 없거나 손상되면 빈 dict.
static func load_downloads() -> Dictionary:
	var out: Dictionary = {}
	var posts: Dictionary = _read_posts(DOWNLOADS_PATH)
	for key in posts:
		var post_id: String = str(key)
		var raw: Variant = posts[key]
		if not is_valid_post_id(post_id) or not (raw is Dictionary):
			continue
		var e: Dictionary = raw
		var local_id: String = str(e.get("track_id", ""))
		var chash: String = str(e.get("content_hash", ""))
		var fp: String = str(e.get("fingerprint", ""))
		if not is_valid_local_id(local_id) or chash.is_empty() or fp.is_empty():
			continue
		out[post_id] = {
			"track_id": local_id,
			"content_hash": chash.substr(0, 128),
			"fingerprint": fp.substr(0, 128),
			"title": str(e.get("title", "")).substr(0, TITLE_MAX),
			"downloaded_at": str(e.get("downloaded_at", "")).substr(0, 40),
		}
	return out


## 매핑 전체를 저장한다. 성공 여부 반환.
static func save_downloads(posts: Dictionary) -> bool:
	return _write_posts(DOWNLOADS_PATH, posts)


## 게시물 매핑 하나(없으면 빈 dict).
static func download_entry(post_id: String) -> Dictionary:
	return load_downloads().get(post_id, {})


## 로컬 트랙 id 를 가리키는 매핑의 게시물 id(없으면 빈 문자열).
static func post_for_local(track_id: String) -> String:
	var posts: Dictionary = load_downloads()
	for post_id in posts:
		if str(posts[post_id]["track_id"]) == track_id:
			return str(post_id)
	return ""


# --- 게시(삭제 토큰) ---


## 검증을 통과한 게시 기록 전체({post_id: entry}). 파일이 없거나 손상되면 빈 dict.
static func load_published() -> Dictionary:
	var out: Dictionary = {}
	var posts: Dictionary = _read_posts(PUBLISHED_PATH)
	for key in posts:
		var post_id: String = str(key)
		var raw: Variant = posts[key]
		if not is_valid_post_id(post_id) or not (raw is Dictionary):
			continue
		var e: Dictionary = raw
		var token: String = str(e.get("delete_token", ""))
		if not is_valid_token(token):
			continue
		var src: String = str(e.get("source_track_id", ""))
		out[post_id] = {
			"delete_token": token,
			"title": str(e.get("title", "")).substr(0, TITLE_MAX),
			"published_at": str(e.get("published_at", "")).substr(0, 40),
			"source_track_id": src if is_valid_local_id(src) else "",
		}
	return out


## 게시 성공 직후 삭제 토큰을 기록한다. 성공 여부 반환(실패 시 호출부가 토큰을 화면에 유지).
static func remember_published(
	post_id: String, token: String, title: String, published_at: String, source_track_id: String
) -> bool:
	if not is_valid_post_id(post_id) or not is_valid_token(token):
		return false
	var posts: Dictionary = load_published()
	posts[post_id] = {
		"delete_token": token,
		"title": title.substr(0, TITLE_MAX),
		"published_at": published_at.substr(0, 40),
		"source_track_id": source_track_id if is_valid_local_id(source_track_id) else "",
	}
	return _write_posts(PUBLISHED_PATH, posts)


## 게시물의 삭제 토큰(없으면 빈 문자열).
static func token_for(post_id: String) -> String:
	return str(load_published().get(post_id, {}).get("delete_token", ""))


## 삭제 완료(또는 이미 삭제됨 확인) 후 토큰 기록을 지운다. 기록이 없으면 true.
static func forget_published(post_id: String) -> bool:
	var posts: Dictionary = load_published()
	if not posts.has(post_id):
		return true
	posts.erase(post_id)
	return _write_posts(PUBLISHED_PATH, posts)


# --- 파일 입출력 ---


## 파일 상태와 내용. state: ok | missing | unreadable | corrupt | version. ok 가 아니면 posts 는 빈 dict.
## 본 파일이 없고 유효한 임시 파일이 남아 있으면(교체 도중 중단) 임시 파일을 본 파일로 복구해 읽는다.
static func read_state(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		var tmp: String = path + ".tmp"
		if not FileAccess.file_exists(tmp):
			return {"state": "missing", "posts": {}}
		var recovered: Dictionary = _parse_file(tmp)
		if str(recovered["state"]) != "ok":
			return {"state": "missing", "posts": {}}
		DirAccess.rename_absolute(tmp, path)  # 실패해도 이번 읽기는 임시 파일 내용으로 진행한다.
		return recovered
	return _parse_file(path)


static func _parse_file(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"state": "unreadable", "posts": {}}
	var text: String = file.get_as_text()
	var err: int = file.get_error()
	file.close()
	if err != OK and err != ERR_FILE_EOF:
		return {"state": "unreadable", "posts": {}}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"state": "corrupt", "posts": {}}
	var root: Dictionary = parsed
	if not _is_num(root.get("version", null)) or int(root["version"]) != FORMAT_VERSION:
		return {"state": "version", "posts": {}}
	var posts: Variant = root.get("posts", {})
	if not (posts is Dictionary):
		return {"state": "corrupt", "posts": {}}
	return {"state": "ok", "posts": posts}


static func _is_num(v: Variant) -> bool:
	return v is int or v is float


static func _read_posts(path: String) -> Dictionary:
	return read_state(path)["posts"]


## 파일이 있는데 읽을 수 없거나 손상·버전 불일치면 덮어쓰기 전에 옆으로 옮겨 보존한다.
## 보존할 필요가 없거나 보존에 성공하면 true, 보존하지 못했으면 false(호출부는 쓰지 않는다).
static func _preserve_if_unreadable(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	if str(_parse_file(path)["state"]) == "ok":
		return true
	var bak: String = path + ".bak"
	if FileAccess.file_exists(bak) or DirAccess.dir_exists_absolute(bak):
		bak = "%s.bak-%d-%d" % [path, int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	if DirAccess.rename_absolute(path, bak) == OK:
		push_warning("CommunityStore: 읽을 수 없는 파일을 보존했습니다 " + bak)
		return true
	if DirAccess.copy_absolute(path, bak) == OK:
		push_warning("CommunityStore: 읽을 수 없는 파일을 복사해 보존했습니다 " + bak)
		return true
	push_error("CommunityStore: 읽을 수 없는 파일을 보존하지 못해 쓰지 않습니다 " + path)
	return false


## 임시 파일을 다시 읽어 쓴 내용과 같고 JSON 으로 파싱되는지 확인한다.
static func verify_written(tmp: String, expected: String) -> bool:
	var file: FileAccess = FileAccess.open(tmp, FileAccess.READ)
	if file == null:
		return false
	var got: String = file.get_as_text()
	file.close()
	return got == expected and JSON.parse_string(got) is Dictionary


## 임시 파일에 쓰고 검증한 뒤 rename 으로 교체한다. 디렉터리 생성·쓰기·검증·보존·교체 중 하나라도
## 실패하면 false(기존 파일 유지, 단 "삭제 후 rename" 폴백 도중 실패하면 다음 로드가 임시 파일을 채택).
static func _write_posts(path: String, posts: Dictionary) -> bool:
	if not DirAccess.dir_exists_absolute(DIR):
		if DirAccess.make_dir_recursive_absolute(DIR) != OK:
			push_error("CommunityStore: 디렉터리 생성 실패 " + DIR)
			return false
	var tmp: String = path + ".tmp"
	var file: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("CommunityStore: 임시 파일 쓰기 실패 " + tmp)
		return false
	var text: String = JSON.stringify({"version": FORMAT_VERSION, "posts": posts}, "  ")
	file.store_string(text)
	var write_err: int = file.get_error()
	file.close()
	if write_err != OK or not verify_written(tmp, text):
		DirAccess.remove_absolute(tmp)
		push_error("CommunityStore: 임시 파일 쓰기·검증 오류 " + tmp)
		return false
	if not _preserve_if_unreadable(path):
		DirAccess.remove_absolute(tmp)
		return false
	if DirAccess.rename_absolute(tmp, path) == OK:
		return true
	# 폴백: 기존 파일을 지운 뒤 다시 rename. 삭제에 실패하면 기존 파일이 그대로이므로 임시 파일을 지운다.
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
		DirAccess.remove_absolute(tmp)
		push_error("CommunityStore: 파일 교체 실패 " + path)
		return false
	if DirAccess.rename_absolute(tmp, path) == OK:
		return true
	push_error("CommunityStore: 파일 교체 실패(임시 파일을 남겨 다음 로드에서 복구) " + path)
	return false
