"""재봉 등급(Seam Grade) 산정 — 클라이언트 단일 진실의 서버 복제본 (기획서 §6.5).

이 공식은 게임 클라이언트 ``game/scripts/systems/RunStats.gd`` 의 ``_grade_score`` /
``_grade_letter`` 와 **1:1 로 일치**해야 한다. 리더보드 정렬·표시 등급이 결과 화면 등급과
어긋나면 안 되기 때문이다. 어느 한쪽 공식을 바꾸면 반드시 다른 쪽도 같이 바꾸고 이
상호 참조 주석을 유지한다.

    점수 = clamp(accuracy*0.6 + perfect_rate*0.4 - cuts*5, 0, 100)
    등급 = S(>=95) A(>=88) B(>=75) C(>=60) D(그 외)

리더보드는 "등급 우선 → 시간 차선"으로 정렬하므로(§14.1), 정렬용 티어(S=5..D=1)를
SQL ``CASE`` 식으로도 제공한다(``grade_tier_expr``).
"""

from __future__ import annotations

from sqlalchemy import case

# --- RunStats.gd 상수와 1:1 대응(변경 시 양쪽 동시 수정) ---
GRADE_ACCURACY_WEIGHT = 0.6  # RunStats.GRADE_ACCURACY_WEIGHT
GRADE_PERFECT_WEIGHT = 0.4  # RunStats.GRADE_PERFECT_WEIGHT
GRADE_CUT_PENALTY = 5.0  # RunStats.GRADE_CUT_PENALTY
GRADE_S_CUTOFF = 95.0  # RunStats.GRADE_S_CUTOFF
GRADE_A_CUTOFF = 88.0  # RunStats.GRADE_A_CUTOFF
GRADE_B_CUTOFF = 75.0  # RunStats.GRADE_B_CUTOFF
GRADE_C_CUTOFF = 60.0  # RunStats.GRADE_C_CUTOFF

# 등급 문자 → 정렬 티어(클수록 상위). 리더보드는 이 값 내림차순으로 정렬한다.
_LETTER_TIER = {"S": 5, "A": 4, "B": 3, "C": 2, "D": 1}


def grade_score(accuracy: float, perfect_rate: float, cuts: int) -> float:
    """in-line 충실도 점수(0~100). RunStats._grade_score 와 동일 산식."""
    raw = (
        accuracy * GRADE_ACCURACY_WEIGHT
        + perfect_rate * GRADE_PERFECT_WEIGHT
        - float(cuts) * GRADE_CUT_PENALTY
    )
    return min(100.0, max(0.0, raw))


def grade_letter(score: float) -> str:
    """점수를 S/A/B/C/D 로 환산. RunStats._grade_letter 와 동일 컷오프."""
    if score >= GRADE_S_CUTOFF:
        return "S"
    if score >= GRADE_A_CUTOFF:
        return "A"
    if score >= GRADE_B_CUTOFF:
        return "B"
    if score >= GRADE_C_CUTOFF:
        return "C"
    return "D"


def grade_for(accuracy: float, perfect_rate: float, cuts: int) -> str:
    """저장된 메트릭에서 등급 문자를 바로 산출(응답의 grade 필드용)."""
    return grade_letter(grade_score(accuracy, perfect_rate, cuts))


def grade_tier_of(letter: str) -> int:
    """등급 문자의 정렬 티어(없으면 최하위 1)."""
    return _LETTER_TIER.get(letter, 1)


def grade_tier_expr(entity):
    """ORDER BY 용 등급 티어 SQL 식(S=5 … D=1).

    ``entity`` 는 원본 ``Run`` 또는 서브쿼리 alias 로, ``accuracy``·``perfect_rate``·
    ``cuts`` 컬럼에서 점수를 계산해 컷오프별 티어로 매핑한다. 정렬 키로만 쓰므로 [0,100]
    clamp 는 생략한다 — 모든 컷오프가 [60,95] 안이라 clamp 전후 티어가 동일하다
    (score>100 은 여전히 S, score<0 은 여전히 D). ``grade_score`` 주석 참조.
    """
    raw = (
        entity.accuracy * GRADE_ACCURACY_WEIGHT
        + entity.perfect_rate * GRADE_PERFECT_WEIGHT
        - entity.cuts * GRADE_CUT_PENALTY
    )
    return case(
        (raw >= GRADE_S_CUTOFF, 5),
        (raw >= GRADE_A_CUTOFF, 4),
        (raw >= GRADE_B_CUTOFF, 3),
        (raw >= GRADE_C_CUTOFF, 2),
        else_=1,
    )
