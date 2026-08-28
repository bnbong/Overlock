"""요청/응답 Pydantic 스키마 (기획서 §13.3 POST 바디 + §18 범위 검증).

DB가 필요 없는 검증(범위·형식·페널티 일관성)은 여기서 처리한다. 실패 시 FastAPI가
자동으로 HTTP 422 를 돌려준다. 트랙 등록/체크섬 대조·물리 하한처럼 DB가 필요한
검증은 routes.py 에서 수행한다.
"""

from __future__ import annotations

import unicodedata

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

# 닉네임: 1~16자, 제어/포맷 문자 금지, 공백만인 이름 금지, 그 외 유니코드 허용(§18).
PLAYER_NAME_MIN = 1
PLAYER_NAME_MAX = 16
# 게임 버전: semver 유사 형식(예 "0.1.0", "1.2.3-rc1").
GAME_VERSION_PATTERN = r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$"
# 체크섬/리플레이 해시: "sha256:" + 소문자 hex 64자.
SHA256_PATTERN = r"^sha256:[0-9a-f]{64}$"


def _has_control_char(text: str) -> bool:
    """제어/포맷/서로게이트/미할당 등 'C*' 유니코드 카테고리 문자가 있으면 True."""
    return any(unicodedata.category(ch).startswith("C") for ch in text)


class RunCreate(BaseModel):
    """POST /api/runs 바디 (기획서 §13.3 예시 스키마 그대로)."""

    model_config = ConfigDict(str_strip_whitespace=False)

    # max_length=64 는 파싱 단계 조기 차단용(거대 문자열 DoS 방어). 실제 1~16자
    # 검증은 아래 _validate_player_name 이 strip 후 수행한다.
    player_name: str = Field(max_length=64)
    track_id: str = Field(min_length=1, max_length=64)
    difficulty: str = Field(min_length=1, max_length=32)
    time_ms: int = Field(ge=0)
    penalty_ms: int = Field(ge=0)
    final_time_ms: int = Field(ge=0)
    accuracy: float = Field(ge=0.0, le=100.0)
    # 등급 산정용 perfect_rate(%). 구버전 클라이언트 호환을 위해 선택값(기본 0.0)이다
    # (없으면 등급이 다소 낮게 유도됨). app/grade.py·RunStats.gd 와 정합.
    perfect_rate: float = Field(default=0.0, ge=0.0, le=100.0)
    cuts: int = Field(ge=0)
    off_seam_ms: int = Field(ge=0)
    game_version: str = Field(pattern=GAME_VERSION_PATTERN)
    track_checksum: str = Field(pattern=SHA256_PATTERN)
    replay_hash: str | None = Field(default=None, pattern=SHA256_PATTERN)

    @field_validator("player_name")
    @classmethod
    def _validate_player_name(cls, value: str) -> str:
        # 앞뒤 공백은 정규화(중복 기록 dedup 안정화). 내부 공백은 허용.
        name = value.strip()
        if not name:
            raise ValueError("player_name은 공백만으로 구성할 수 없습니다")
        if not (PLAYER_NAME_MIN <= len(name) <= PLAYER_NAME_MAX):
            raise ValueError(
                f"player_name은 {PLAYER_NAME_MIN}~{PLAYER_NAME_MAX}자여야 합니다"
            )
        if _has_control_char(name):
            raise ValueError("player_name에 제어 문자를 포함할 수 없습니다")
        return name

    @model_validator(mode="after")
    def _validate_penalty_consistency(self) -> "RunCreate":
        # 페널티 일관성: final_time_ms == time_ms + penalty_ms (§18 범위 검증).
        if self.final_time_ms != self.time_ms + self.penalty_ms:
            raise ValueError(
                "final_time_ms는 time_ms + penalty_ms와 일치해야 합니다 "
                f"({self.final_time_ms} != {self.time_ms} + {self.penalty_ms})"
            )
        return self


class RunSubmitResponse(BaseModel):
    """POST /api/runs 응답."""

    run_id: int
    verification_status: str
    rank: int


class RunDetail(BaseModel):
    """GET /api/runs/{run_id} 응답."""

    model_config = ConfigDict(from_attributes=True)

    run_id: int = Field(validation_alias="id")
    player_name: str
    track_id: str
    difficulty: str
    time_ms: int
    penalty_ms: int
    final_time_ms: int
    accuracy: float
    perfect_rate: float
    cuts: int
    off_seam_ms: int
    game_version: str
    track_checksum: str
    replay_hash: str | None
    verification_status: str
    created_at: str


class LeaderboardEntry(BaseModel):
    """리더보드 한 행(rank 포함, 플레이어당 최고 기록 1건)."""

    rank: int
    run_id: int
    player_name: str
    track_id: str
    difficulty: str
    time_ms: int
    penalty_ms: int
    final_time_ms: int
    accuracy: float
    perfect_rate: float
    cuts: int
    off_seam_ms: int
    # 재봉 등급(S/A/B/C/D). 서버가 저장 메트릭에서 클라와 동일 공식으로 유도한다
    # (app/grade.py). 리더보드 정렬(등급 우선) 및 클라 표시용.
    grade: str
    game_version: str
    verification_status: str
    created_at: str


class LeaderboardResponse(BaseModel):
    """GET /api/leaderboard 응답."""

    track_id: str
    difficulty: str | None
    limit: int
    offset: int
    count: int
    entries: list[LeaderboardEntry]


class TrackInfo(BaseModel):
    """GET /api/tracks 항목."""

    id: str
    name: str
    difficulty: str
    checksum: str


class HealthResponse(BaseModel):
    """GET /api/health 응답."""

    status: str
    version: str
