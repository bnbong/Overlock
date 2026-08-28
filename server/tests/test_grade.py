"""재봉 등급 공식(app/grade.py) 단위 테스트.

이 공식은 클라이언트 RunStats.gd 의 _grade_score/_grade_letter 와 1:1 로 일치해야 한다.
컷오프 경계·clamp·cuts 감점·정렬 티어를 고정해, 어느 한쪽이 흔들리면 여기서 잡는다.
"""

from __future__ import annotations

import pytest

from app.grade import grade_for, grade_score, grade_tier_of


def test_grade_score_formula():
    # acc*0.6 + pr*0.4 - cuts*5.
    assert grade_score(100.0, 100.0, 0) == 100.0
    assert grade_score(90.0, 90.0, 0) == pytest.approx(90.0)
    assert grade_score(60.0, 0.0, 0) == pytest.approx(36.0)
    # cuts 감점.
    assert grade_score(100.0, 100.0, 1) == pytest.approx(95.0)
    # [0,100] clamp.
    assert grade_score(100.0, 100.0, 50) == 0.0
    assert grade_score(100.0, 100.0, 0) <= 100.0


@pytest.mark.parametrize(
    "acc,pr,cuts,expected",
    [
        (100.0, 100.0, 0, "S"),  # 100
        (100.0, 90.0, 0, "S"),  # 96 >= 95
        (90.0, 90.0, 0, "A"),  # 90
        (90.0, 87.5, 0, "A"),  # 89 (>= 88)
        (80.0, 80.0, 0, "B"),  # 80
        (75.0, 75.0, 0, "B"),  # 75 경계
        (60.0, 60.0, 0, "C"),  # 60 경계
        (60.0, 0.0, 0, "D"),  # 36
        (100.0, 100.0, 20, "D"),  # 0 (clamp)
    ],
)
def test_grade_letter_boundaries(acc, pr, cuts, expected):
    assert grade_for(acc, pr, cuts) == expected


def test_grade_tier_ordering():
    tiers = [grade_tier_of(g) for g in ("S", "A", "B", "C", "D")]
    assert tiers == [5, 4, 3, 2, 1]
    # 높은 등급일수록 큰 티어 → 내림차순 정렬 시 상위.
    assert tiers == sorted(tiers, reverse=True)
