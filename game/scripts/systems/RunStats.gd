class_name RunStats
extends RefCounted
## 판정·채점·페널티 누적 및 결과 확정 (기획서 §7.6/§7.7, 아키텍처 §6.5).
##
## 매 물리 틱 accumulate()로 누적하고, 피니시 시 finalize()로 결과 dict를 만든다.
## 결과 dict 필드는 리더보드 POST /api/runs 스키마(§13.3)와 정합하게 유지한다.

enum Band { PERFECT, GOOD, OFF_SEAM, TEAR }

const OFF_SEAM_PENALTY_PER_S: float = 0.5  # §7.7
const CUT_PENALTY: float = 2.0  # §7.7 부상 1회 +2.0s

# 재봉 평점(Seam Grade, 아키텍처 §6.5). in-line 충실도를 등급으로 환산한다.
# 점수 = accuracy×0.6 + perfect_rate×0.4 − cuts×5 (0~100 clamp).
# accuracy(평균 이탈의 역수)를 주 가중치로 두어 "재봉선대로 정직하게 완주"를 보상하고,
# perfect_rate로 정밀도를 더한 뒤 부상(cuts)을 무겁게 감점한다(가드레일 없는 게임 철학).
const GRADE_ACCURACY_WEIGHT: float = 0.6
const GRADE_PERFECT_WEIGHT: float = 0.4
const GRADE_CUT_PENALTY: float = 5.0
# 컷오프: S=거의 무결점, A=탁월, B=양호, C=무난, D=거침.
const GRADE_S_CUTOFF: float = 95.0
const GRADE_A_CUTOFF: float = 88.0
const GRADE_B_CUTOFF: float = 75.0
const GRADE_C_CUTOFF: float = 60.0

var active_time: float = 0.0
var perfect_time: float = 0.0
var off_seam_time: float = 0.0
var error_sum: float = 0.0  # seam_error * dt 누적
var speed_index_sum: float = 0.0
var samples: int = 0
var max_speed_index: int = 1
var cuts: int = 0
var penalty_time: float = 0.0
var combo: int = 0
var max_combo: int = 0


func accumulate(dt: float, sidx: int, band: int, err: float, just_cut: bool) -> void:
	active_time += dt
	error_sum += err * dt
	speed_index_sum += float(sidx)
	samples += 1
	max_speed_index = maxi(max_speed_index, sidx)
	match band:
		Band.PERFECT:
			perfect_time += dt
			combo += 1
			max_combo = maxi(max_combo, combo)
		Band.GOOD:
			pass  # 정상 진행, 콤보 유지
		Band.OFF_SEAM, Band.TEAR:
			# MVP: Tear는 Off-Seam과 동일 집계(+0.5s/s).
			off_seam_time += dt
			penalty_time += OFF_SEAM_PENALTY_PER_S * dt
			combo = 0
	if just_cut:
		cuts += 1
		penalty_time += CUT_PENALTY
		combo = 0


func finalize(finish_time: float, safe_width: float, track_id: String, diff: String) -> Dictionary:
	var mean_err: float = error_sum / maxf(active_time, 0.0001)
	var normalized: float = mean_err / safe_width * 100.0  # §7.6
	var accuracy: float = clampf(100.0 - normalized, 0.0, 100.0)
	var perfect_rate: float = perfect_time / maxf(active_time, 0.0001) * 100.0
	# ms 절사는 두 성분을 각각 절사한 뒤 더한다. final_time을 독립 절사하면
	# floor(a+b) ≥ floor(a)+floor(b) 때문에 final_time_ms가 finish_ms+penalty_ms보다
	# 1ms 커질 수 있어, 서버의 페널티 일관성 검증(final == time + penalty, §18)에 걸린다.
	var finish_ms: int = int(finish_time * 1000.0)
	var penalty_ms: int = int(penalty_time * 1000.0)
	var grade_score: float = _grade_score(accuracy, perfect_rate, cuts)
	return {
		"track_id": track_id,
		"difficulty": diff,
		"finish_ms": finish_ms,
		"penalty_ms": penalty_ms,
		"final_time_ms": finish_ms + penalty_ms,
		"accuracy": accuracy,
		"perfect_rate": perfect_rate,
		"off_seam_ms": int(off_seam_time * 1000.0),
		"cuts": cuts,
		"max_speed": max_speed_index,
		"avg_speed": speed_index_sum / float(maxi(samples, 1)),
		"max_combo": max_combo,
		"grade": _grade_letter(grade_score),
		"grade_score": grade_score,
	}


## in-line 충실도 점수(0~100). accuracy·perfect_rate 가중 + cuts 감점.
func _grade_score(accuracy: float, perfect_rate: float, cut_count: int) -> float:
	var raw: float = (
		accuracy * GRADE_ACCURACY_WEIGHT
		+ perfect_rate * GRADE_PERFECT_WEIGHT
		- float(cut_count) * GRADE_CUT_PENALTY
	)
	return clampf(raw, 0.0, 100.0)


## 점수를 S/A/B/C/D 등급 문자로 환산.
static func _grade_letter(score: float) -> String:
	if score >= GRADE_S_CUTOFF:
		return "S"
	if score >= GRADE_A_CUTOFF:
		return "A"
	if score >= GRADE_B_CUTOFF:
		return "B"
	if score >= GRADE_C_CUTOFF:
		return "C"
	return "D"
