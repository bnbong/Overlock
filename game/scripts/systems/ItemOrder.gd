class_name ItemOrder
extends RefCounted
## 필드 아이템의 정규 순서 (v2.3.0, docs/architecture.md §3.2·§6.6).
##
## 트랙 파일의 items 배열 순서는 에디터 조작 순서 등으로 임의일 수 있다. 슬롯은 FIFO라 한 틱에 여러
## 아이템을 담을 때 담는 순서가 플레이에 영향을 주므로, RaceDirector의 획득 판정과 기록 지문
## (TrackLoader.record_fingerprint)이 모두 이 정규 순서를 쓴다: s 오름차순, 같으면 type, lat, 원래 인덱스.
## 그래서 배열 순서만 다른 같은 트랙은 같은 지문을 갖고 실제 획득 순서도 같다.


## items의 인덱스를 정규 순서로 정렬해 돌려준다(원래 인덱스는 ItemField 통지용으로 그대로 쓴다).
static func indices(items: Array) -> Array:
	var order: Array = range(items.size())
	order.sort_custom(func(a: int, b: int) -> bool: return _less(items, a, b))
	return order


static func _less(items: Array, a: int, b: int) -> bool:
	var ia: Dictionary = items[a] if items[a] is Dictionary else {}
	var ib: Dictionary = items[b] if items[b] is Dictionary else {}
	var sa: float = _num(ia.get("s", 0.0))
	var sb: float = _num(ib.get("s", 0.0))
	if not is_equal_approx(sa, sb):
		return sa < sb
	var ta: String = str(ia.get("type", ""))
	var tb: String = str(ib.get("type", ""))
	if ta != tb:
		return ta < tb
	var la: float = _num(ia.get("lat", 0.0))
	var lb: float = _num(ib.get("lat", 0.0))
	if not is_equal_approx(la, lb):
		return la < lb
	return a < b


static func _num(v: Variant) -> float:
	return float(v) if (v is float or v is int) else 0.0
