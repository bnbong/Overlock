"""커스텀 트랙 공유 허브 업로드 검증·정규화 (계획서 §4).

클라이언트 TrackValidator 성공을 신뢰하지 않고 서버가 같은 하드 거부 기준을 다시
적용한다. 흐름(값싼 검사 → 비싼 검사 순):

  1) JSON 중첩 깊이 사전 스캔(파싱 전, 단일 패스 O(n)) → 2) json.loads(NaN/Infinity 리터럴 거부)
  → 3) 값싼 크기 검사(세그먼트·점·아이템 개수, 점 모양) → 4) pydantic strict 스키마
  (형·범위·허용 필드) → 5) 좌표 0.1 스냅 정규화 → 6) 원시 길이 사전 상한(베이크 전 DoS 방어)
  → 7) TrackData.bake 폴리라인 세분 포팅(float32 모사) → 8) TrackValidator 하드 기준 포팅
  (점 수·곡률·길이·자기근접, 보수 밴드) → 9) 아이템 s/lat 범위.
  422 오류 목록은 최대 MAX_ERROR_ITEMS 건으로 자르고 입력값을 에코하지 않는다.

기하 포팅 대응표(game/scripts/track/*.gd, 줄 단위):
  - bake_polyline      ↔ TrackData._bake_polyline (≤6px 세분, 세그먼트 경계 0.01 중복 제거)
  - build_arc_lengths  ↔ TrackValidator.build_arc_lengths
  - _span_index        ↔ TrackValidator._span_index (이진탐색 + 정확 술어 보정, 결과 동일)
  - menger_radius      ↔ TrackValidator.menger_radius
  - _check_curvature   ↔ TrackValidator.check_curvature + _cluster_curvature (hard 만 집계)
  - _check_hard_proximity ↔ TrackValidator.check_self_proximity 의 hard 분기 + _dedupe_pairs
  - validate_geometry  ↔ TrackValidator.validate 의 hard 집계(soft 경고는 계산하지 않음)

수치 정책: Godot 는 Vector2/PackedFloat32Array(float32)로 계산한다. 베이크 점·세분 개수·
누적 호길이는 float32 반올림을 연산 단위로 모사해 Godot 4.6(macOS arm64) 헤드리스 결과와
비트 단위로 같다. 반경·거리는 float32 점에서 double 로 계산하고, 플랫폼별 FMA 차이까지 덮도록
하드 임계값에 서버 쪽이 더 엄격한 여유 밴드(LEN_MARGIN 등)를 둔다. 그래서 "서버 수락 ∧
Godot 거부" 는 생기지 않고, 밴드 안의 경계 입력만 "서버 거부 ∧ Godot 수락" 이 된다.
"""

from __future__ import annotations

import bisect
import hashlib
import json
import math
import re
import struct
import unicodedata
from dataclasses import dataclass
from fractions import Fraction
from typing import Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)

# ---------------------------------------------------------------------------
# 지원 목록 (TrackEditor.gd DIFFS/FABRICS, RaceDirector._apply_item, TrackLoader.EDITOR_VERSION)
# ---------------------------------------------------------------------------
SUPPORTED_DIFFICULTIES: tuple[str, ...] = ("beginner", "normal", "expert", "master")
SUPPORTED_FABRICS: tuple[str, ...] = (
    "cotton",
    "denim",
    "silk",
    "knit",
    "wool",
    "felt",
    "satin",
    "leather",
)
SUPPORTED_ITEM_TYPES: tuple[str, ...] = ("thimble", "autopilot")
SUPPORTED_EDITOR_VERSIONS: tuple[str, ...] = ("0.1.0",)
NORMALIZED_EDITOR_VERSION = "0.1.0"

# ---------------------------------------------------------------------------
# 업로드 제한 (계획서 §4 초기값)
# ---------------------------------------------------------------------------
MAX_JSON_DEPTH = 8  # 정상 업로드 최대 깊이 = 6 ({}→track{}→path[]→seg{}→points[]→[x,y])
MAX_POINTS_TOTAL = 4096  # 정규화 점(모든 세그먼트 합) 상한
MAX_SEGMENTS = 64
# 좌표 절댓값 상한. 에디터 원시 입력 클램프는 StrokeProcessor.COORD_CLAMP=4000, 공식 15개
# 트랙의 최대 절댓값 좌표는 1546(cotton_01)이고, 자동 스케일을 거쳐도 길이 상한(8000px)
# 안에서는 4000+8000 을 넘기 어렵다. 2^14 로 두면 정상 트랙을 배제하지 않으면서 float32
# 좌표 표현 오차(ulp/2)를 0.001px 이하로 묶어 Godot(float32)와의 판정 차이를 줄인다.
MAX_ABS_COORD = 16384.0
MAX_WIDTH = 1000.0
MAX_ITEMS = 128
TITLE_MAX = 80
AUTHOR_MAX = 32
DESCRIPTION_MAX = 1000
# 파싱 단계 조기 차단용 원문 길이(정규화 전). 실제 제한은 정규화 후 위 상한으로 본다.
_RAW_TEXT_MAX = 4000

# ---------------------------------------------------------------------------
# TrackData / TrackValidator 상수 (GDScript 와 동일 값)
# ---------------------------------------------------------------------------
BAKE_INTERVAL = 6.0  # TrackData.BAKE_INTERVAL
MIN_RADIUS = 28.0  # TrackValidator.MIN_RADIUS
RADIUS_RECOMMEND = 45.0  # TrackValidator.RADIUS_RECOMMEND
CURV_SPAN = 15.0  # TrackValidator.CURV_SPAN
LEN_HARD_MIN = 1500.0  # TrackValidator.LEN_HARD_MIN
LEN_HARD_MAX = 8000.0  # TrackValidator.LEN_HARD_MAX
ARC_EXEMPT = 110.0  # TrackValidator.ARC_EXEMPT
RELOCALIZE_REACH = 300.0  # TrackValidator.RELOCALIZE_REACH
MIN_POINTS = 8  # TrackValidator.MIN_POINTS

# ---------------------------------------------------------------------------
# float32 판정 차이 해소 정책(계획서 §7): "서버가 수락하면 Godot 도 수락한다"
# ---------------------------------------------------------------------------
# 1) 베이크 점·세분 개수·누적 호길이는 Godot 의 float32 연산(Vector2 성분, PackedFloat32Array
#    저장)을 IEEE 단정밀도 반올림으로 그대로 모사한다(bake_track / build_arc_lengths).
# 2) 플랫폼마다 FMA 축약 여부가 달라 마지막 비트가 갈릴 수 있으므로, 하드 임계값에는 서버 쪽이
#    더 엄격해지는 작은 여유 밴드를 둔다. 밴드 안의 경계 입력은 서버가 거부한다.
#    (여유 폭은 좌표 ≤ MAX_ABS_COORD 에서의 float32 오차 상한보다 한 자릿수 이상 크다.)
LEN_MARGIN = 0.5  # 길이: [LEN_HARD_MIN + m, LEN_HARD_MAX - m] 만 수락
RADIUS_MARGIN = 0.1  # 곡률: 반경 < MIN_RADIUS + m 이면 하드
SPAN_EPS = 0.01  # 스텐실 선택: |Δs - CURV_SPAN| ≤ eps 면 양쪽 후보 중 작은 반경을 쓴다
PROX_S_EPS = 0.05  # 자기근접 Δs 윈도: (ARC_EXEMPT - eps, RELOCALIZE_REACH + eps]
PROX_D_EPS = 0.01  # 자기근접 거리: d < fail + eps 면 하드
ITEM_S_MARGIN = 0.5  # 아이템 s ≤ (float32 길이) - m


# 422 응답 detail 항목 수 상한(잘못된 점을 대량으로 넣어 오류 목록·응답을 부풀리는 것 방지).
MAX_ERROR_ITEMS = 20
# loc 안의 문자열(미지 필드 키 등 사용자 입력) 길이 상한. 긴 키가 그대로 에코되지 않게 한다.
_LOC_TEXT_MAX = 64


def _clip_loc(loc: list[Any]) -> list[Any]:
    out: list[Any] = []
    for part in loc:
        if isinstance(part, str) and len(part) > _LOC_TEXT_MAX:
            part = part[:_LOC_TEXT_MAX] + "…"
        out.append(part)
    return out


def cap_errors(errors: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """오류 목록을 MAX_ERROR_ITEMS 건 이하로 자른다(마지막 1건은 생략 안내)."""
    if len(errors) <= MAX_ERROR_ITEMS:
        return errors
    kept = errors[: MAX_ERROR_ITEMS - 1]
    kept.append(
        {
            "loc": ["body"],
            "msg": f"오류가 너무 많아 앞의 {MAX_ERROR_ITEMS - 1}건만 표시합니다 (전체 {len(errors)}건)",
            "type": "too_many_errors",
        }
    )
    return kept


class TrackRejected(Exception):
    """업로드 거부(422). errors 는 FastAPI 422 형식과 같은 {loc,msg,type} 목록(최대 20건)."""

    def __init__(self, errors: list[dict[str, Any]]) -> None:
        super().__init__(errors[0]["msg"] if errors else "invalid")
        self.errors = [{**e, "loc": _clip_loc(list(e["loc"]))} for e in cap_errors(errors)]


def _err(loc: list[Any], msg: str, typ: str) -> dict[str, Any]:
    return {"loc": loc, "msg": msg, "type": typ}


# ---------------------------------------------------------------------------
# 1) JSON 깊이 사전 스캔 + 파싱
# ---------------------------------------------------------------------------
# 깊이 판정에 의미가 있는 바이트만 한 글자짜리 문자 클래스로 찾는다. 반복·대안이 없는
# 단일 문자 클래스라 finditer 는 본문을 한 번만 훑는다(백트래킹 없음 → O(n)).
_JSON_DEPTH_TOKEN_RE = re.compile(rb'[\[\]{}"\\]')
_QUOTE = 0x22  # "
_BACKSLASH = 0x5C  # \
_OPENERS = (0x5B, 0x7B)  # [ {


def json_depth_exceeds(body: bytes, max_depth: int) -> bool:
    """문자열 리터럴을 제외한 괄호 중첩이 max_depth 를 넘으면 True.

    json.loads 재귀 전에 호출해 깊은 중첩(RecursionError·스택 소모)을 싸게 거부한다.
    문자열/이스케이프 상태를 추적하는 단일 패스 스캐너다. 예전의 문자열 제거 정규식은
    닫히지 않은 문자열 + 이스케이프 따옴표 반복(b'"' + b'\\\\"' * n)에서 O(n^2) 로
    폭주했으므로(80KB 에 수십 초) 정규식 치환을 쓰지 않는다. 괄호 짝이 맞지 않거나
    문자열이 닫히지 않은 입력은 여기서 판정하지 않고 파서가 거부하게 둔다.
    """
    depth = 0
    in_string = False
    escaped_pos = -1  # 문자열 안에서 역슬래시 바로 다음 위치(이 위치의 토큰은 리터럴)
    for match in _JSON_DEPTH_TOKEN_RE.finditer(body):
        pos = match.start()
        ch = body[pos]
        if in_string:
            if pos == escaped_pos:
                continue
            if ch == _BACKSLASH:
                escaped_pos = pos + 1
            elif ch == _QUOTE:
                in_string = False
            continue
        if ch == _QUOTE:
            in_string = True
        elif ch in _OPENERS:
            depth += 1
            if depth > max_depth:
                return True
        elif ch != _BACKSLASH:  # 문자열 밖 역슬래시는 잘못된 JSON → 파서가 거부
            depth -= 1
    return False


def _reject_constant(name: str) -> Any:
    raise ValueError(f"허용되지 않는 JSON 상수: {name}")


def parse_json_body(body: bytes) -> dict[str, Any]:
    """요청 본문 → dict. 깊이 초과·NaN/Infinity·비객체 최상위는 TrackRejected."""
    if not body.strip():
        raise TrackRejected([_err(["body"], "요청 본문이 비어 있습니다", "json_invalid")])
    if json_depth_exceeds(body, MAX_JSON_DEPTH):
        raise TrackRejected(
            [_err(["body"], f"JSON 중첩이 너무 깊습니다 (최대 {MAX_JSON_DEPTH})", "json_too_deep")]
        )
    try:
        parsed = json.loads(body, parse_constant=_reject_constant)
    except (ValueError, RecursionError) as exc:  # JSONDecodeError 는 ValueError 하위
        raise TrackRejected([_err(["body"], f"JSON 파싱 실패: {exc}", "json_invalid")]) from None
    if not isinstance(parsed, dict):
        raise TrackRejected([_err(["body"], "최상위 JSON 은 객체여야 합니다", "json_invalid")])
    return parsed


# ---------------------------------------------------------------------------
# 2) 텍스트 정규화
# ---------------------------------------------------------------------------
_WS_RUN_RE = re.compile(r"\s+")
_INLINE_WS_RUN_RE = re.compile(r"[^\S\n]+")
_MANY_NEWLINES_RE = re.compile(r"\n{3,}")


# 공백(\s)은 아니지만 화면에 아무것도 그리지 않는 문자(명시 목록). 제목·작성자명이 이
# 문자들과 공백만으로 이루어지면 "비어 있음"으로 본다. 제어/포맷(C*)은 별도로 이미 거부한다.
_INVISIBLE_CHARS = frozenset(
    "ᅟ"  # HANGUL CHOSEONG FILLER
    "ᅠ"  # HANGUL JUNGSEONG FILLER
    "឴"  # KHMER VOWEL INHERENT AQ
    "឵"  # KHMER VOWEL INHERENT AA
    "⠀"  # BRAILLE PATTERN BLANK
    "ㅤ"  # HANGUL FILLER
    "ﾠ"  # HALFWIDTH HANGUL FILLER
)


def _has_visible_char(text: str) -> bool:
    return any(not ch.isspace() and ch not in _INVISIBLE_CHARS for ch in text)


def _unsupported_msg(name: str, allowed: tuple[str, ...]) -> str:
    """허용 목록만 안내한다(입력값은 에코하지 않는다)."""
    return f"지원하지 않는 {name}입니다 (허용: {', '.join(allowed)})"


def _has_disallowed_char(text: str, allow_newline: bool) -> bool:
    """제어/포맷/서로게이트/미할당('C*') 문자가 있으면 True(schemas._has_control_char 관례)."""
    for ch in text:
        if allow_newline and ch == "\n":
            continue
        if unicodedata.category(ch).startswith("C"):
            return True
    return False


def normalize_single_line(value: str) -> str:
    """NFC → 모든 공백(탭·개행 포함) 연속을 공백 1개로 축약 → strip."""
    text = unicodedata.normalize("NFC", value)
    return _WS_RUN_RE.sub(" ", text).strip()


def normalize_multiline(value: str) -> str:
    """NFC → CRLF/CR→LF → 줄 안 공백 축약 → 줄 끝 공백 제거 → 3줄 이상 빈 줄 축약 → strip."""
    text = unicodedata.normalize("NFC", value).replace("\r\n", "\n").replace("\r", "\n")
    lines = [_INLINE_WS_RUN_RE.sub(" ", line).strip() for line in text.split("\n")]
    text = "\n".join(lines)
    return _MANY_NEWLINES_RE.sub("\n\n", text).strip()


def normalize_search_query(value: str) -> str:
    """검색어 정규화(제목 정규화와 동일 규칙이어야 부분 일치가 안정적)."""
    return normalize_single_line(value)


# ---------------------------------------------------------------------------
# 3) 업로드 스키마 (strict: bool/string → 숫자 묵시 변환 금지, 미지 필드 거부)
# ---------------------------------------------------------------------------
_STRICT = ConfigDict(strict=True, extra="forbid", allow_inf_nan=False)

Coord = float  # strict float: int 는 허용, bool·str 은 거부


class WidthIn(BaseModel):
    model_config = _STRICT

    perfect: Coord = Field(gt=0.0, le=MAX_WIDTH)
    safe: Coord = Field(gt=0.0, le=MAX_WIDTH)
    fail: Coord = Field(gt=0.0, le=MAX_WIDTH)

    @model_validator(mode="after")
    def _ordered(self) -> "WidthIn":
        if not (self.perfect < self.safe < self.fail):
            raise ValueError("width 는 perfect < safe < fail 이어야 합니다")
        return self


class PolylineSegmentIn(BaseModel):
    model_config = _STRICT

    type: Literal["polyline"]
    points: list[list[Coord]] = Field(min_length=2, max_length=MAX_POINTS_TOTAL)
    closed: bool = False

    @field_validator("points")
    @classmethod
    def _points_shape(cls, value: list[list[float]]) -> list[list[float]]:
        for idx, pt in enumerate(value):
            if len(pt) != 2:
                raise ValueError(f"points[{idx}] 는 [x, y] 두 수여야 합니다")
            for c in pt:
                if abs(c) > MAX_ABS_COORD:
                    raise ValueError(
                        f"points[{idx}] 좌표 절댓값이 {MAX_ABS_COORD:g} 를 넘습니다"
                    )
        return value


class ItemIn(BaseModel):
    model_config = _STRICT

    s: Coord
    type: str = Field(max_length=32)
    lat: Coord = 0.0

    @field_validator("type")
    @classmethod
    def _supported_type(cls, value: str) -> str:
        if value not in SUPPORTED_ITEM_TYPES:
            raise ValueError(_unsupported_msg("아이템 type", SUPPORTED_ITEM_TYPES))
        return value


class TrackIn(BaseModel):
    """업로드 track 본문. TrackLoader.save_custom_track 저장 포맷을 그대로 받는다.

    track_id·name·is_custom·checksum·length 는 형만 확인하고 버린다(서버 재계산/무시).
    """

    model_config = _STRICT

    difficulty: str = Field(max_length=32)
    fabric: str = Field(max_length=32)
    width: WidthIn
    path: list[PolylineSegmentIn] = Field(min_length=1, max_length=MAX_SEGMENTS)
    items: list[ItemIn] = Field(default_factory=list, max_length=MAX_ITEMS)
    modifiers: list[Any] = Field(default_factory=list)
    editor_version: str | None = Field(default=None, max_length=32)
    # --- 무시 필드(클라이언트 로컬 메타). 형만 검사하고 정규화 결과에 넣지 않는다. ---
    track_id: str | None = Field(default=None, max_length=64)
    name: str | None = Field(default=None, max_length=_RAW_TEXT_MAX)
    is_custom: bool | None = None
    checksum: str | None = Field(default=None, max_length=128)
    length: Coord | None = None

    @field_validator("difficulty")
    @classmethod
    def _supported_difficulty(cls, value: str) -> str:
        if value not in SUPPORTED_DIFFICULTIES:
            raise ValueError(_unsupported_msg("difficulty", SUPPORTED_DIFFICULTIES))
        return value

    @field_validator("fabric")
    @classmethod
    def _supported_fabric(cls, value: str) -> str:
        if value not in SUPPORTED_FABRICS:
            raise ValueError(_unsupported_msg("fabric", SUPPORTED_FABRICS))
        return value

    @field_validator("editor_version")
    @classmethod
    def _supported_editor_version(cls, value: str | None) -> str | None:
        if value is not None and value not in SUPPORTED_EDITOR_VERSIONS:
            raise ValueError(_unsupported_msg("editor_version", SUPPORTED_EDITOR_VERSIONS))
        return value

    @field_validator("modifiers", mode="before")
    @classmethod
    def _no_modifiers(cls, value: Any) -> Any:
        if isinstance(value, list) and value:
            raise ValueError("modifiers 는 아직 지원하지 않습니다 (빈 배열만 허용)")
        return value

    @model_validator(mode="after")
    def _total_points(self) -> "TrackIn":
        total = sum(len(seg.points) for seg in self.path)
        if total > MAX_POINTS_TOTAL:
            raise ValueError(f"경로 점이 너무 많습니다 ({total}개, 최대 {MAX_POINTS_TOTAL}개)")
        return self


def _text_field(value: str, *, name: str, max_len: int, required: bool, multiline: bool) -> str:
    raw = value
    text = normalize_multiline(raw) if multiline else normalize_single_line(raw)
    if _has_disallowed_char(text, allow_newline=multiline):
        raise ValueError(f"{name}에 제어 문자를 포함할 수 없습니다")
    if required and not _has_visible_char(text):
        raise ValueError(f"{name}은(는) 비워 둘 수 없습니다")
    if len(text) > max_len:
        raise ValueError(f"{name}은(는) 최대 {max_len}자입니다 (현재 {len(text)}자)")
    return text


class CommunityTrackCreate(BaseModel):
    """POST /api/community/tracks 본문."""

    model_config = _STRICT

    title: str = Field(max_length=_RAW_TEXT_MAX)
    author_name: str = Field(max_length=_RAW_TEXT_MAX)
    description: str = Field(default="", max_length=_RAW_TEXT_MAX * 2)
    track: TrackIn

    @field_validator("title")
    @classmethod
    def _title(cls, value: str) -> str:
        return _text_field(value, name="title", max_len=TITLE_MAX, required=True, multiline=False)

    @field_validator("author_name")
    @classmethod
    def _author(cls, value: str) -> str:
        return _text_field(
            value, name="author_name", max_len=AUTHOR_MAX, required=True, multiline=False
        )

    @field_validator("description")
    @classmethod
    def _description(cls, value: str) -> str:
        return _text_field(
            value, name="description", max_len=DESCRIPTION_MAX, required=False, multiline=True
        )


def prescan_sizes(parsed: dict[str, Any]) -> list[dict[str, Any]] | None:
    """스키마 검증 전 값싼 크기 검사. 위반이 있으면 오류 1건 목록, 없으면 None.

    pydantic 은 잘못된 원소마다 오류를 만든다. 점·세그먼트·아이템 개수와 점 모양을 먼저
    확인해, 거대한 배열이 스키마 검증(오류 수·CPU)까지 가지 않게 한다. 형이 틀린 경우
    (track 이 객체가 아님 등)는 여기서 판정하지 않고 스키마 검증에 맡긴다.
    """
    track = parsed.get("track")
    if not isinstance(track, dict):
        return None
    loc_track = ["body", "track"]
    path = track.get("path")
    if isinstance(path, list):
        if len(path) > MAX_SEGMENTS:
            return [
                _err(
                    [*loc_track, "path"],
                    f"세그먼트가 너무 많습니다 (최대 {MAX_SEGMENTS}개)",
                    "too_long",
                )
            ]
        total = 0
        for k, seg in enumerate(path):
            if not isinstance(seg, dict):
                continue
            points = seg.get("points")
            if not isinstance(points, list):
                continue
            total += len(points)
            loc_points = [*loc_track, "path", k, "points"]
            if total > MAX_POINTS_TOTAL:
                return [
                    _err(
                        loc_points,
                        f"경로 점이 너무 많습니다 (최대 {MAX_POINTS_TOTAL}개)",
                        "too_long",
                    )
                ]
            for idx, pt in enumerate(points):
                if not isinstance(pt, list) or len(pt) != 2:
                    return [
                        _err(
                            [*loc_points, idx],
                            f"points[{idx}] 는 [x, y] 두 수여야 합니다",
                            "point_shape",
                        )
                    ]
    items = track.get("items")
    if isinstance(items, list) and len(items) > MAX_ITEMS:
        return [
            _err([*loc_track, "items"], f"아이템이 너무 많습니다 (최대 {MAX_ITEMS}개)", "too_long")
        ]
    return None


def _pydantic_errors(exc: ValidationError) -> list[dict[str, Any]]:
    """pydantic 오류 → {loc,msg,type} 목록. 입력값(input)은 에코하지 않는다(대용량/개인정보)."""
    out: list[dict[str, Any]] = []
    for e in exc.errors(include_url=False, include_input=False, include_context=False):
        out.append({"loc": ["body", *e["loc"]], "msg": e["msg"], "type": e["type"]})
    return out


# ---------------------------------------------------------------------------
# 4) 좌표 정규화 · 베이크 (TrackData._bake_polyline 포팅, float32 모사)
# ---------------------------------------------------------------------------
Point = tuple[float, float]

_F32 = struct.Struct("<f")
_f32_pack = _F32.pack
_f32_unpack = _F32.unpack


def f32(value: float) -> float:
    """IEEE 단정밀도(round-to-nearest-even)로 반올림한 값. Godot real_t(float) 저장을 모사한다.

    float32 두 수의 +,-,*,/,sqrt 를 double 로 계산한 뒤 한 번 반올림하면 단정밀도로 직접
    계산한 결과와 같다(53 ≥ 2·24+2 이라 이중 반올림 오차가 생기지 않는다).
    """
    return _f32_unpack(_f32_pack(value))[0]


def snap01(value: float) -> float:
    """GDScript snappedf(value, 0.1) 와 같은 반올림(floor(v/0.1 + 0.5)) → k/10."""
    k = math.floor(value / 0.1 + 0.5)
    return k / 10.0 + 0.0  # + 0.0: -0.0 → 0.0


def _dist(a: Point, b: Point) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def _dist32(ax: float, ay: float, bx: float, by: float) -> float:
    """Vector2.distance_to (float32): sqrt((ax-bx)^2 + (ay-by)^2) 를 연산마다 단정밀도로."""
    dx = f32(ax - bx)
    dy = f32(ay - by)
    return f32(math.sqrt(f32(f32(dx * dx) + f32(dy * dy))))


def _f32_of_fraction(value: Fraction) -> float:
    """양의 유리수를 float32 로 정확히 한 번 반올림(round-half-even). 정규 범위만 다룬다."""
    if value <= 0:
        return 0.0
    _, exp = math.frexp(float(value))  # value ≈ f·2^exp, 0.5 ≤ f < 1 (경계는 아래에서 보정)
    e = exp - 24
    scaled = value / (Fraction(2) ** e) if e >= 0 else value * (Fraction(2) ** -e)
    while scaled >= 2**24:
        e += 1
        scaled /= 2
    while scaled < 2**23:
        e -= 1
        scaled *= 2
    mant = round(scaled)  # Fraction.__round__ 는 half-even
    return math.ldexp(float(mant), e)


def _subdiv_ambiguous(ax: float, ay: float, bx: float, by: float, d32: float) -> bool:
    """세분 개수 ceil(d/6) 이 FMA 축약 여부(플랫폼·컴파일러)에 따라 갈릴 수 있으면 True.

    Vector2.distance_to 의 dx*dx + dy*dy 는 컴파일러가 곱셈-덧셈을 하나로 축약(FMA)하면
    마지막 비트가 달라질 수 있다. d 가 6 의 배수에 몇 ulp 이내로 가까울 때만 세 가지 평가
    순서(축약 없음, dx 쪽 축약, dy 쪽 축약)의 결과를 정확히 계산해 세분 개수를 비교한다.
    dx 나 dy 가 0 이면 축약이 결과를 바꾸지 않는다.
    """
    if ax == bx or ay == by or d32 <= 0.0:
        return False
    _, exp = math.frexp(d32)
    ulp = math.ldexp(1.0, exp - 24)
    if math.ceil((d32 - 4 * ulp) / BAKE_INTERVAL) == math.ceil((d32 + 4 * ulp) / BAKE_INTERVAL):
        return False  # 6 의 배수에서 충분히 멀다(대부분의 구간은 여기서 끝난다)
    dx = Fraction(f32(ax - bx))
    dy = Fraction(f32(ay - by))
    xx = dx * dx
    yy = dy * dy
    sums = {
        _f32_of_fraction(Fraction(f32(float(xx))) + Fraction(f32(float(yy)))),  # 축약 없음
        _f32_of_fraction(xx + Fraction(f32(float(yy)))),  # fma(dx, dx, dy*dy)
        _f32_of_fraction(Fraction(f32(float(xx))) + yy),  # fma(dy, dy, dx*dx)
    }
    counts = {math.ceil(f32(math.sqrt(s)) / BAKE_INTERVAL) for s in sums}
    return len(counts) > 1


def raw_path_length(segments: list[list[Point]]) -> float:
    """베이크 전 원시 폴리라인 길이(세그먼트 사이 연결 포함). 선형 세분은 길이를 바꾸지 않는다."""
    total = 0.0
    last: Point | None = None
    for seg in segments:
        for q in seg:
            if last is not None:
                total += _dist(last, q)
            last = q
    return total


@dataclass
class BakeResult:
    points: list[Point]  # float32 로 표현 가능한 값만 담는다(Vector2 성분과 같은 값)
    s_arr: list[float]  # TrackData._append / TrackValidator.build_arc_lengths 와 같은 float32 누적
    ambiguous_segments: int  # 세분 개수가 플랫폼마다 갈릴 수 있는 원시 구간 수


def bake_track(segments: list[list[Point]]) -> BakeResult:
    """TrackData.bake(polyline 전용) 포팅: 각 점 사이를 ≤BAKE_INTERVAL 로 선형 세분한다.

    Godot 와 같은 float32 연산 순서를 따른다:
      q = Vector2(f32(x), f32(y)), d = last.distance_to(q), n = max(1, ceil(d / 6)),
      p = last.lerp(q, f32(m / n)) = last + (q - last) * w (성분별 float32),
      s[k] = f32(s[k-1] + last.distance_to(p)) (PackedFloat32Array 저장).
    """
    points: list[Point] = []
    s_arr: list[float] = []
    ambiguous = 0

    def append(px: float, py: float) -> None:
        if points:
            lx, ly = points[-1]
            s_arr.append(f32(s_arr[-1] + _dist32(lx, ly, px, py)))
        else:
            s_arr.append(0.0)
        points.append((px, py))

    for seg in segments:
        for k, raw_q in enumerate(seg):
            qx = f32(raw_q[0])
            qy = f32(raw_q[1])
            if not points:
                append(qx, qy)
                continue
            lx, ly = points[-1]
            d = _dist32(lx, ly, qx, qy)
            if k == 0 and d < 0.01:
                continue  # 이전 세그먼트 끝점과 공유 → 중복 제거
            if _subdiv_ambiguous(lx, ly, qx, qy, d):
                ambiguous += 1
            n = max(1, math.ceil(d / BAKE_INTERVAL))
            if n > 1:
                ddx = f32(qx - lx)
                ddy = f32(qy - ly)
                for m in range(1, n):
                    w = f32(m / n)
                    append(f32(lx + f32(ddx * w)), f32(ly + f32(ddy * w)))
            append(qx, qy)
    return BakeResult(points=points, s_arr=s_arr, ambiguous_segments=ambiguous)


def bake_polyline(segments: list[list[Point]]) -> list[Point]:
    """bake_track 의 점 목록만 반환한다."""
    return bake_track(segments).points


# ---------------------------------------------------------------------------
# 5) TrackValidator 하드 기준 포팅
# ---------------------------------------------------------------------------
def build_arc_lengths(pts: list[Point]) -> list[float]:
    """TrackValidator.build_arc_lengths: PackedFloat32Array 누적(float32 거리·저장)."""
    s_arr = [0.0] * len(pts)
    for i in range(1, len(pts)):
        ax, ay = pts[i - 1]
        bx, by = pts[i]
        s_arr[i] = f32(s_arr[i - 1] + _dist32(ax, ay, bx, by))
    return s_arr


def menger_radius(a: Point, b: Point, c: Point) -> float:
    ab = _dist(a, b)
    bc = _dist(b, c)
    ca = _dist(c, a)
    cross = abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]))
    if cross < 0.0001:
        return math.inf
    return (ab * bc * ca) / (2.0 * cross)


# s_arr 는 비감소이고 float32 두 값의 차는 double 에서 정확하다. 그래서 "s[j] - s[i] ≥ thr" 같은
# 술어는 j 에 대해 단조이며, bisect 의 key 로 차이를 직접 비교하면 원본 선형 스캔과 같은 인덱스를
# 반올림 보정 루프 없이 O(log n) 에 찾는다.
def _first_fwd_at_least(s_arr: list[float], i: int, thr: float) -> int:
    """j > i 중 s[j] - s[i] ≥ thr 인 첫 j. 없으면 len(s_arr)."""
    si = s_arr[i]
    return bisect.bisect_left(s_arr, thr, i + 1, len(s_arr), key=lambda v: v - si)


def _first_fwd_above(s_arr: list[float], i: int, thr: float) -> int:
    """j > i 중 s[j] - s[i] > thr 인 첫 j. 없으면 len(s_arr)."""
    si = s_arr[i]
    return bisect.bisect_right(s_arr, thr, i + 1, len(s_arr), key=lambda v: v - si)


def _first_bwd_at_least(s_arr: list[float], i: int, thr: float) -> int:
    """j < i 중 s[i] - s[j] ≥ thr 인 (i 에 가장 가까운) j. 없으면 -1."""
    si = s_arr[i]
    # s[j] - s[i] > -thr ⇔ s[i] - s[j] < thr 인 첫 j 의 바로 앞.
    return bisect.bisect_right(s_arr, -thr, 0, i, key=lambda v: v - si) - 1


def _span_index(s_arr: list[float], i: int, direction: int) -> int:
    """TrackValidator._span_index 와 같은 결과(이진탐색).

    GDScript 원본: j=i 에서 (0<j<n-1 인 동안) j+=dir 하며 |s[j]-s[i]| >= CURV_SPAN 인 첫 j,
    못 찾으면 끝 j 가 CURV_SPAN*0.6 이상이면 j, 아니면 -1. i 가 양 끝이면 루프가 돌지 않는다.
    """
    n = len(s_arr)
    if not 0 < i < n - 1:
        return -1  # j = i → |s[j]-s[i]| = 0 < CURV_SPAN*0.6
    if direction > 0:
        j = _first_fwd_at_least(s_arr, i, CURV_SPAN)
        if j < n:
            return j
        j = n - 1
    else:
        j = _first_bwd_at_least(s_arr, i, CURV_SPAN)
        if j >= 0:
            return j
        j = 0
    if abs(s_arr[j] - s_arr[i]) >= CURV_SPAN * 0.6:
        return j
    return -1


def _span_candidates(s_arr: list[float], i: int, direction: int, eps: float) -> list[int]:
    """Δs 비교가 ±eps 만큼 흔들릴 때 Godot 가 고를 수 있는 스텐실 인덱스 후보(보수적).

    원본 규칙에서 임계 비교(≥ CURV_SPAN, 끝단 ≥ CURV_SPAN*0.6)만 흔들린다고 보고, 첫 후보
    (Δs ≥ CURV_SPAN - eps)와 확정 후보(Δs ≥ CURV_SPAN + eps)를 모두 돌려준다. 끝단 대체는
    Δs ≥ CURV_SPAN*0.6 - eps 면 포함한다. 두 첫 후보 사이의 점들은 호길이 2·eps 안에 있다.
    """
    n = len(s_arr)
    if not 0 < i < n - 1:
        return []
    out: list[int] = []
    if direction > 0:
        lo = _first_fwd_at_least(s_arr, i, CURV_SPAN - eps)
        hi = _first_fwd_at_least(s_arr, i, CURV_SPAN + eps)
        end = n - 1
        for j in (lo, hi):
            if j < n and j not in out:
                out.append(j)
        fallback_possible = hi >= n
    else:
        lo = _first_bwd_at_least(s_arr, i, CURV_SPAN - eps)
        hi = _first_bwd_at_least(s_arr, i, CURV_SPAN + eps)
        end = 0
        for j in (lo, hi):
            if j >= 0 and j not in out:
                out.append(j)
        fallback_possible = hi < 0
    if fallback_possible and end not in out:
        if abs(s_arr[end] - s_arr[i]) >= CURV_SPAN * 0.6 - eps:
            out.append(end)
    return out


def _cluster(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """_cluster_curvature: 인덱스가 6 이내로 이어지는 위반을 묶어 최소 반경만 남긴다."""
    if not raw:
        return raw
    out: list[dict[str, Any]] = []
    cur = raw[0]
    last_i = raw[0]["i"]
    for v in raw[1:]:
        if v["i"] - last_i <= 6:
            if v["radius"] < cur["radius"]:
                cur = v
        else:
            out.append(cur)
            cur = v
        last_i = v["i"]
    out.append(cur)
    return out


def _check_curvature(
    pts: list[Point], s_arr: list[float], *, conservative: bool = False
) -> list[dict[str, Any]]:
    """check_curvature + _cluster_curvature. 반환: 클러스터 대표 {i, radius, kind}.

    conservative=True 면 스텐실 후보 중 가장 작은 반경을 쓰고 하드 임계에 RADIUS_MARGIN 을
    더한다(서버가 Godot 보다 같거나 더 엄격해진다).
    """
    hard_thr = MIN_RADIUS + (RADIUS_MARGIN if conservative else 0.0)
    raw: list[dict[str, Any]] = []
    for i in range(len(pts)):
        if conservative:
            kbs = _span_candidates(s_arr, i, -1, SPAN_EPS)
            kfs = _span_candidates(s_arr, i, 1, SPAN_EPS)
            if not kbs or not kfs:
                continue
            r = min(menger_radius(pts[kb], pts[i], pts[kf]) for kb in kbs for kf in kfs)
        else:
            kb = _span_index(s_arr, i, -1)
            kf = _span_index(s_arr, i, 1)
            if kb < 0 or kf < 0:
                continue
            r = menger_radius(pts[kb], pts[i], pts[kf])
        if r < max(RADIUS_RECOMMEND, hard_thr):
            raw.append({"i": i, "radius": r, "kind": "hard" if r < hard_thr else "soft"})
    return _cluster(raw)


def _check_hard_proximity(
    pts: list[Point], s_arr: list[float], fail: float, *, conservative: bool = False
) -> int:
    """check_self_proximity 의 hard 분기(ARC_EXEMPT < Δs ≤ RELOCALIZE_REACH, d < fail) + _dedupe_pairs.

    GDScript 는 셀=1.5·fail 공간 해시로 후보를 모은다. d < fail 인 쌍은 항상 인접 셀 안에
    있으므로 hard 쌍 집합은 "Δs 윈도 안의 모든 j" 를 보는 것과 같다. 여기서는 Δs 윈도를
    이진탐색으로 잡고, 경로가 1-립시츠(|d(i,j+k)-d(i,j)| ≤ s[j+k]-s[j])라는 점을 이용해
    d ≥ fail 인 구간을 보수적으로 건너뛴다(건너뛴 점은 모두 d > fail 이 보장된다).
    hard 쌍을 찾으면 같은 16 인덱스 버킷의 나머지 j 는 건너뛴다(버킷 수는 같다).
    conservative=True 면 Δs 윈도를 PROX_S_EPS, 거리 임계를 PROX_D_EPS 만큼 넓힌다.
    반환: 버킷(16 인덱스) 중복 제거 후 hard 쌍 수.
    """
    if fail <= 0.0:
        return 0
    exempt = ARC_EXEMPT - (PROX_S_EPS if conservative else 0.0)
    reach = RELOCALIZE_REACH + (PROX_S_EPS if conservative else 0.0)
    fail_thr = fail + (PROX_D_EPS if conservative else 0.0)
    n = len(pts)
    buckets: set[tuple[int, int]] = set()
    for i in range(n):
        si = s_arr[i]
        xi, yi = pts[i]
        # |s[j]-s[i]| <= exempt 면 면제 → s[j]-s[i] > exempt 인 첫 j 부터 본다.
        j = _first_fwd_above(s_arr, i, exempt)
        while j < n:
            ds = s_arr[j] - si
            if ds > reach:
                break
            xj, yj = pts[j]
            d = math.hypot(xj - xi, yj - yi)
            if d < fail_thr:
                # _dedupe_pairs 는 (i//16, j//16) 버킷마다 1건만 남기므로 같은 j 버킷의
                # 나머지 점은 결과를 바꾸지 않는다 → 다음 버킷 경계로 건너뛴다.
                buckets.add((i // 16, j // 16))
                j = (j // 16 + 1) * 16
                continue
            gap = (d - fail_thr) * 0.999 - 1e-6
            if gap > 0.0:
                target = s_arr[j] + gap
                nj = bisect.bisect_left(s_arr, target, j + 1, n)
                j = nj if nj > j + 1 else j + 1
            else:
                j += 1
    return len(buckets)


@dataclass
class GeometryResult:
    ok: bool
    length: float
    baked_points: int
    hard_curvature: int
    hard_proximity: int
    length_status: str
    messages: list[str]


def validate_geometry(
    pts: list[Point],
    fail: float,
    *,
    s_arr: list[float] | None = None,
    conservative: bool = True,
) -> GeometryResult:
    """TrackValidator.validate 의 하드 판정 포팅(soft 경고는 판정에 쓰지 않아 계산하지 않는다).

    conservative=True(업로드 판정 기본값)면 float32/FMA 차이를 덮는 여유 밴드를 적용해 Godot
    보다 같거나 더 엄격하게 판정한다. False 는 원본과 같은 임계값(포팅 일치 검증용)이다.
    s_arr 를 주지 않으면 build_arc_lengths(float32 누적)로 계산한다.
    """
    if len(pts) < MIN_POINTS:
        return GeometryResult(
            ok=False,
            length=0.0,
            baked_points=len(pts),
            hard_curvature=0,
            hard_proximity=0,
            length_status="ok",
            messages=[f"너무 짧음 (점 {len(pts)}개, 최소 {MIN_POINTS}개)"],
        )
    if s_arr is None:
        s_arr = build_arc_lengths(pts)
    total_len = s_arr[-1]

    curv = _check_curvature(pts, s_arr, conservative=conservative)
    hard_curv = sum(1 for v in curv if v["kind"] == "hard")

    margin = LEN_MARGIN if conservative else 0.0
    len_status = "ok"
    len_hard = 0
    if total_len < LEN_HARD_MIN + margin:
        len_status, len_hard = "too_short", 1
    elif total_len > LEN_HARD_MAX - margin:
        len_status, len_hard = "too_long", 1

    hard_prox = _check_hard_proximity(pts, s_arr, fail, conservative=conservative)

    messages: list[str] = []
    if hard_curv > 0:
        messages.append(f"곡률 위반 {hard_curv}곳 (반경 < {int(MIN_RADIUS)}px)")
    if hard_prox > 0:
        messages.append(f"자기근접 위반 {hard_prox}곳 (s 점프 위험)")
    if len_status == "too_short":
        messages.append(f"길이 {total_len:.1f}px: 하한 {int(LEN_HARD_MIN)}px 미만")
    elif len_status == "too_long":
        messages.append(f"길이 {total_len:.1f}px: 상한 {int(LEN_HARD_MAX)}px 초과")
    if margin and len_hard:
        messages[-1] += f" (경계 여유 {margin:g}px 포함)"
    hard = hard_curv + hard_prox + len_hard
    return GeometryResult(
        ok=hard == 0,
        length=total_len,
        baked_points=len(pts),
        hard_curvature=hard_curv,
        hard_proximity=hard_prox,
        length_status=len_status,
        messages=messages,
    )


# ---------------------------------------------------------------------------
# 6) 정규화 결과 + content_hash
# ---------------------------------------------------------------------------
@dataclass
class NormalizedUpload:
    title: str
    author_name: str
    description: str
    difficulty: str
    fabric: str
    length: int  # round(베이크 경로 길이) — TrackLoader.save_custom_track 의 length 와 같은 규칙
    track: dict[str, Any]  # 응답·저장용 정규화 track JSON
    content_hash: str


def _num(value: float) -> float:
    """해시·저장용 수치 정규화: float 로 맞추고 -0.0 을 0.0 으로 통일한다."""
    return float(value) + 0.0


def play_data(track: dict[str, Any]) -> dict[str, Any]:
    """content_hash 대상(플레이에 영향을 주는 필드만): difficulty·fabric·width·path·items.

    세그먼트의 closed 는 Godot TrackData 가 읽지 않으므로(플레이에 영향 없음) 제외한다.
    세그먼트 분할 자체는 그대로 반영한다(같은 점 열이라도 분할이 다르면 해시가 다르다).
    """
    return {
        "difficulty": track["difficulty"],
        "fabric": track["fabric"],
        "width": {k: _num(v) for k, v in track["width"].items()},
        "path": [
            {
                "type": seg["type"],
                "points": [[_num(x), _num(y)] for x, y in seg["points"]],
            }
            for seg in track["path"]
        ],
        "items": [
            {"s": _num(it["s"]), "type": it["type"], "lat": _num(it["lat"])}
            for it in track["items"]
        ],
    }


def compute_content_hash(track: dict[str, Any]) -> str:
    """정규화 track 의 플레이 데이터를 정렬 키·공백 없는 JSON(UTF-8)으로 직렬화한 SHA-256.

    수치는 모두 float 로 맞추고 -0.0 은 0.0 으로 통일한다(18·18.0·-0 이 같은 해시). 결과는
    "sha256:<소문자 hex 64>". 클라이언트는 재계산하지 않고 불투명 식별자로 비교만 한다.
    """
    canonical = json.dumps(
        play_data(track),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_upload(body: bytes) -> NormalizedUpload:
    """요청 본문 바이트 → 정규화 결과. 실패 시 TrackRejected(422 오류 목록)."""
    parsed = parse_json_body(body)
    # 값싼 크기 검사를 스키마 검증보다 먼저 한다(거대한 배열의 원소별 오류·CPU 방지).
    size_errors = prescan_sizes(parsed)
    if size_errors:
        raise TrackRejected(size_errors)
    try:
        req = CommunityTrackCreate.model_validate(parsed)
    except ValidationError as exc:
        raise TrackRejected(_pydantic_errors(exc)) from None

    track_in = req.track
    fail = _num(track_in.width.fail)

    # 좌표 0.1 스냅(에디터 저장·_prepare_import 와 같은 격자). 저장·해시·검증 모두 이 값 기준.
    segments: list[list[Point]] = [
        [(snap01(float(p[0])), snap01(float(p[1]))) for p in seg.points] for seg in track_in.path
    ]

    # 베이크 전 DoS 방어: 원시 길이가 하드 상한을 넘으면 세분(점 폭증) 없이 거부한다.
    raw_len = raw_path_length(segments)
    if raw_len > LEN_HARD_MAX + 1.0:
        raise TrackRejected(
            [
                _err(
                    ["body", "track", "path"],
                    f"길이 {int(raw_len)}px: 상한 {int(LEN_HARD_MAX)}px 초과",
                    "track_geometry",
                )
            ]
        )

    baked = bake_track(segments)
    if baked.ambiguous_segments:
        raise TrackRejected(
            [
                _err(
                    ["body", "track", "path"],
                    "점 사이 거리가 세분 경계(6px 배수)에 너무 가까워 기기마다 다르게 해석될 수"
                    f" 있습니다 ({baked.ambiguous_segments}곳). 해당 점을 조금 옮겨 주세요",
                    "track_geometry",
                )
            ]
        )
    geo = validate_geometry(baked.points, fail, s_arr=baked.s_arr)
    if not geo.ok:
        raise TrackRejected(
            [_err(["body", "track", "path"], msg, "track_geometry") for msg in geo.messages]
        )

    # float32 누적 길이(Godot td.length 와 같은 값). 아이템 s 상한은 여유를 두고 더 엄격하게 본다.
    length = geo.length
    s_max = length - ITEM_S_MARGIN
    item_errors: list[dict[str, Any]] = []
    items_out: list[dict[str, Any]] = []
    for idx, item in enumerate(track_in.items):
        s_val = _num(item.s)
        lat_val = _num(item.lat)
        if not (0.0 <= s_val <= s_max):
            item_errors.append(
                _err(
                    ["body", "track", "items", idx, "s"],
                    f"아이템 s 는 0 이상 {s_max:.1f} 이하여야 합니다"
                    f" (트랙 길이 {length:.1f} - 여유 {ITEM_S_MARGIN:g})",
                    "item_range",
                )
            )
        if abs(lat_val) > fail:
            item_errors.append(
                _err(
                    ["body", "track", "items", idx, "lat"],
                    f"아이템 lat 절댓값은 fail 폭({fail:g}) 이하여야 합니다",
                    "item_range",
                )
            )
        items_out.append({"s": s_val, "type": item.type, "lat": lat_val})
    if item_errors:
        raise TrackRejected(item_errors)
    # 픽업 판정은 순서와 무관하므로 정렬해 같은 아이템 집합이 같은 해시를 갖게 한다.
    items_out.sort(key=lambda it: (it["s"], it["lat"], it["type"]))

    width = {
        "perfect": _num(track_in.width.perfect),
        "safe": _num(track_in.width.safe),
        "fail": fail,
    }
    path_out = [
        {
            "type": "polyline",
            "points": [[_num(x), _num(y)] for (x, y) in seg],
            "closed": bool(track_in.path[k].closed),
        }
        for k, seg in enumerate(segments)
    ]
    # GDScript round() 는 0.5 에서 0 반대 방향으로 올린다(파이썬 round 의 은행가 반올림과 다름).
    length_int = int(math.floor(length + 0.5))
    track = {
        "name": req.title,
        "difficulty": track_in.difficulty,
        "fabric": track_in.fabric,
        "width": width,
        "path": path_out,
        "items": items_out,
        "modifiers": [],
        "length": length_int,
        "editor_version": NORMALIZED_EDITOR_VERSION,
    }
    return NormalizedUpload(
        title=req.title,
        author_name=req.author_name,
        description=req.description,
        difficulty=track_in.difficulty,
        fabric=track_in.fabric,
        length=length_int,
        track=track,
        content_hash=compute_content_hash(track),
    )
