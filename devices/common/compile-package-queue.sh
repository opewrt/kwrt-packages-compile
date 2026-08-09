#!/usr/bin/env bash
set -uo pipefail

queue_file="${1:-}"
state_dir="${BUILD_STATE_DIR:-$PWD/build-state}"
jobs="${JOBS:-$(($(nproc) + 1))}"
soft_deadline="${SOFT_DEADLINE_SECONDS:-$((280 * 60))}"
hard_deadline="${HARD_DEADLINE_SECONDS:-$((300 * 60))}"
term_grace="${TERM_GRACE_SECONDS:-60}"
watchdog_interval="${WATCHDOG_INTERVAL_SECONDS:-30}"
start_epoch="${QUEUE_START_EPOCH:-$(date +%s)}"
completed_file="$state_dir/completed.units"
results_dir="$state_dir/build-results"
logs_dir="$state_dir/build-logs"
active_pid=""

if [ -z "$queue_file" ] || [ ! -f "$queue_file" ]; then
	echo "Usage: compile-package-queue.sh QUEUE_TSV" >&2
	exit 1
fi
if ! [[ "$soft_deadline" =~ ^[1-9][0-9]*$ ]] || ! [[ "$hard_deadline" =~ ^[1-9][0-9]*$ ]] || [ "$soft_deadline" -ge "$hard_deadline" ]; then
	echo "Invalid queue deadlines: soft=$soft_deadline hard=$hard_deadline" >&2
	exit 1
fi
if ! [[ "$term_grace" =~ ^[1-9][0-9]*$ ]] || ! [[ "$watchdog_interval" =~ ^[1-9][0-9]*$ ]] || ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || ! [[ "$start_epoch" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid queue settings: jobs=$jobs term_grace=$term_grace watchdog_interval=$watchdog_interval start_epoch=$start_epoch" >&2
	exit 1
fi

mkdir -p "$state_dir" "$results_dir" "$logs_dir"
touch "$completed_file"
queue_sha256="$(sha256sum "$queue_file" | cut -d ' ' -f 1)"
if [ -f "$state_dir/queue.sha256" ] && [ "$(<"$state_dir/queue.sha256")" != "$queue_sha256" ]; then
	echo "Saved queue state does not match the current build plan" >&2
	exit 1
fi
printf '%s\n' "$queue_sha256" > "$state_dir/queue.sha256"
if [ -n "${BUILD_IDENTITY:-}" ]; then
	if ! [[ "$BUILD_IDENTITY" =~ ^[0-9a-f]{64}$ ]]; then
		echo "Invalid BUILD_IDENTITY: $BUILD_IDENTITY" >&2
		exit 1
	fi
	if [ -n "${RESUME_BUILD_IDENTITY:-}" ] && ! [[ "$RESUME_BUILD_IDENTITY" =~ ^[0-9a-f]{64}$ ]]; then
		echo "Invalid RESUME_BUILD_IDENTITY: $RESUME_BUILD_IDENTITY" >&2
		exit 1
	fi
	if [ -f "$state_dir/build-identity" ] && [ "$(<"$state_dir/build-identity")" != "$BUILD_IDENTITY" ]; then
		saved_build_identity="$(<"$state_dir/build-identity")"
		if [ -z "${RESUME_BUILD_IDENTITY:-}" ] || [ "$saved_build_identity" != "$RESUME_BUILD_IDENTITY" ]; then
			echo "Saved queue state does not match the current build identity" >&2
			exit 1
		fi
		echo "migrate queue checkpoint from $saved_build_identity to $BUILD_IDENTITY"
		printf '%s\n' "$saved_build_identity" > "$state_dir/resumed-from-build-identity"
	fi
	printf '%s\n' "$BUILD_IDENTITY" > "$state_dir/build-identity"
fi

requeue_missing_mac80211_symvers() {
	local producer_unit consumer_unit
	producer_unit="$(awk -F '\t' '$4 ~ /\/mac80211\/compile$/ { print $1; exit }' "$queue_file")"
	consumer_unit="$(awk -F '\t' '$4 ~ /\/batman-adv\/compile$/ { print $1; exit }' "$queue_file")"
	[ -n "$producer_unit" ] && [ -n "$consumer_unit" ] || return 0
	grep -Fqx -- "$producer_unit" "$completed_file" || return 0
	if grep -Fqx -- "$consumer_unit" "$completed_file"; then
		return 0
	fi
	if find build_dir -path '*/symvers/mac80211.symvers' -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	awk -v unit="$producer_unit" '$0 != unit' "$completed_file" > "$completed_file.tmp"
	mv "$completed_file.tmp" "$completed_file"
	echo "requeue $producer_unit to restore mac80211.symvers before $consumer_unit"
}

requeue_missing_mac80211_symvers

requeue_missing_ovn_openvswitch() {
	local producer_unit consumer_unit
	producer_unit="$(awk -F '\t' '$4 ~ /\/openvswitch\/compile$/ { print $1; exit }' "$queue_file")"
	consumer_unit="$(awk -F '\t' '$4 ~ /\/ovn\/compile$/ { print $1; exit }' "$queue_file")"
	[ -n "$producer_unit" ] && [ -n "$consumer_unit" ] || return 0
	grep -Fqx -- "$producer_unit" "$completed_file" || return 0
	if grep -Fqx -- "$consumer_unit" "$completed_file"; then
		return 0
	fi
	if find build_dir/target-*/linux-* -maxdepth 1 -type d -name 'openvswitch-*' -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	awk -v unit="$producer_unit" '$0 != unit' "$completed_file" > "$completed_file.tmp"
	mv "$completed_file.tmp" "$completed_file"
	echo "requeue $producer_unit to restore the Open vSwitch build tree before $consumer_unit"
}

requeue_missing_ovn_openvswitch

terminate_active() {
	if [ -n "$active_pid" ] && kill -0 -- "-$active_pid" 2>/dev/null; then
		kill -TERM -- "-$active_pid" 2>/dev/null || true
		sleep "$term_grace"
		kill -KILL -- "-$active_pid" 2>/dev/null || true
		wait "$active_pid" 2>/dev/null || true
	fi
	active_pid=""
}
trap 'terminate_active; exit 130' INT TERM HUP

elapsed_seconds() {
	printf '%s\n' "$(( $(date +%s) - start_epoch ))"
}

refresh_results() {
	awk 'NF' "$completed_file" | sort -u > "$completed_file.sorted"
	mv "$completed_file.sorted" "$completed_file"
	awk -F '\t' '$5 == "1" { print $3 }' "$queue_file" | sort -u > "$results_dir/EXPECTED.txt"
	awk -F '\t' 'NR == FNR { done[$1] = 1; next } $1 in done && $5 == "1" { print $3 }' \
		"$completed_file" "$queue_file" | sort -u > "$results_dir/SUCCESS.txt"
	printf 'feed\tpackage\tstatus\tlog\n' > "$results_dir/BUILD-RESULTS.tsv"
	awk -F '\t' 'NR == FNR { done[$1] = 1; next } $1 in done && $5 == "1" {
		ref = $3
		split(ref, parts, "/")
		feed = parts[1]
		package = substr(ref, length(feed) + 2)
		print feed "\t" package "\tsuccess\t-"
	}' "$completed_file" "$queue_file" | sort -u >> "$results_dir/BUILD-RESULTS.tsv"
	if [ -f "${BUILD_PLAN_DIR:-$PWD/build-plan}/SKIPPED.txt" ]; then
		cp -f "${BUILD_PLAN_DIR:-$PWD/build-plan}/SKIPPED.txt" "$results_dir/SKIPPED.txt"
	else
		: > "$results_dir/SKIPPED.txt"
	fi
}

next_unit() {
	awk -F '\t' 'NR == FNR { done[$1] = 1; next } !seen[$1]++ && !($1 in done) { print $1; exit }' \
		"$completed_file" "$queue_file"
}

write_state() {
	local status="$1"
	local current_unit="${2:--}"
	local total_units completed_units expected success failed dependency_failed skipped next
	total_units="$(cut -f 1 "$queue_file" | awk '!seen[$0]++ { count++ } END { print count + 0 }')"
	completed_units="$(awk 'NF { count++ } END { print count + 0 }' "$completed_file")"
	expected="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/EXPECTED.txt")"
	success="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/SUCCESS.txt")"
	failed="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/FAILED.txt")"
	dependency_failed="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/FAILED-DEPENDENCIES.txt")"
	skipped="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/SKIPPED.txt")"
	next="$(next_unit)"
	[ -n "$next" ] || next="-"
	{
		echo "status=$status"
		echo "queue_sha256=$queue_sha256"
		echo "build_identity=${BUILD_IDENTITY:-none}"
		echo "current_unit=$current_unit"
		echo "next_unit=$next"
		echo "total_units=$total_units"
		echo "completed_units=$completed_units"
		echo "expected=$expected"
		echo "success=$success"
		echo "failed=$failed"
		echo "dependency_failed=$dependency_failed"
		echo "skipped=$skipped"
		echo "elapsed_seconds=$(elapsed_seconds)"
	} > "$state_dir/QUEUE-STATE.txt"
	cp -f "$state_dir/QUEUE-STATE.txt" "$results_dir/SUMMARY.txt"
}

mark_complete() {
	local unit_id="$1"
	{
		cat "$completed_file"
		printf '%s\n' "$unit_id"
	} | awk 'NF' | sort -u > "$completed_file.tmp"
	mv "$completed_file.tmp" "$completed_file"
}

run_make() {
	local unit_id="$1"
	local parallel_jobs="$2"
	local log_file="$3"
	local dependency_mode="$4"
	local verbose="$5"
	shift 5
	local targets=("$@")
	local make_args=(-k -j"$parallel_jobs")
	local elapsed remaining watchdog status timeout_marker
	if [ "$dependency_mode" = "no-deps" ]; then
		make_args+=(NO_DEPS=1)
	fi
	if [ "$verbose" = "true" ]; then
		make_args+=(V=s)
	fi
	elapsed="$(elapsed_seconds)"
	remaining="$((hard_deadline - elapsed))"
	if [ "$remaining" -le 0 ]; then
		return 75
	fi
	timeout_marker="$state_dir/.${unit_id}.timeout"
	rm -f "$timeout_marker"
	printf '\n[%s] make %s %s\n' "$(date -Iseconds)" "${make_args[*]}" "${targets[*]}" >> "$log_file"
	setsid make "${make_args[@]}" "${targets[@]}" >> "$log_file" 2>&1 &
	active_pid=$!
	(
		while kill -0 "$active_pid" 2>/dev/null; do
			elapsed="$(elapsed_seconds)"
			if [ "$elapsed" -ge "$hard_deadline" ]; then
				printf '%s\n' "hard deadline reached for $unit_id" > "$timeout_marker"
				kill -TERM -- "-$active_pid" 2>/dev/null || true
				sleep "$term_grace"
				kill -KILL -- "-$active_pid" 2>/dev/null || true
				exit 0
			fi
			echo "queue unit $unit_id running: elapsed=${elapsed}s remaining=$((hard_deadline - elapsed))s"
			sleep "$watchdog_interval"
		done
	) &
	watchdog=$!
	wait "$active_pid"
	status=$?
	if [ -f "$timeout_marker" ]; then
		wait "$watchdog" 2>/dev/null || true
		kill -KILL -- "-$active_pid" 2>/dev/null || true
	else
		kill "$watchdog" 2>/dev/null || true
		wait "$watchdog" 2>/dev/null || true
	fi
	active_pid=""
	if [ -f "$timeout_marker" ]; then
		rm -f "$timeout_marker"
		return 75
	fi
	return "$status"
}

record_failure() {
	local unit_id="$1"
	local log_name="$2"
	local row_id row_phase row_ref row_target row_report
	while IFS=$'\t' read -r row_id row_phase row_ref row_target row_report; do
		[ "$row_id" = "$unit_id" ] || continue
		if [ "$row_report" = "1" ]; then
			printf '%s\n' "$row_ref" >> "$results_dir/FAILED.txt"
		else
			printf '%s\t%s\n' "$row_target" "build-logs/$log_name" >> "$results_dir/FAILED-DEPENDENCIES.txt"
		fi
	done < "$queue_file"
	awk 'NF' "$results_dir/FAILED.txt" | sort -u > "$results_dir/FAILED.txt.sorted"
	mv "$results_dir/FAILED.txt.sorted" "$results_dir/FAILED.txt"
	awk 'NF' "$results_dir/FAILED-DEPENDENCIES.txt" | sort -u > "$results_dir/FAILED-DEPENDENCIES.txt.sorted"
	mv "$results_dir/FAILED-DEPENDENCIES.txt.sorted" "$results_dir/FAILED-DEPENDENCIES.txt"
}

refresh_results
: > "$results_dir/FAILED.txt"
: > "$results_dir/FAILED-DEPENDENCIES.txt"

current_unit=""
current_phase=""
declare -a current_targets=()
process_unit() {
	local unit_id="$1"
	local phase="$2"
	shift 2
	local targets=("$@")
	local dependency_mode="no-deps"
	local log_name log_file status elapsed
	if [ "${#targets[@]}" -gt 1 ]; then
		dependency_mode="with-deps"
	fi
	if grep -Fqx -- "$unit_id" "$completed_file"; then
		echo "skip completed $unit_id ($phase)"
		return 0
	fi
	elapsed="$(elapsed_seconds)"
	if [ "$elapsed" -ge "$soft_deadline" ]; then
		refresh_results
		write_state paused "$unit_id"
		return 75
	fi
	log_name="${unit_id}_${phase}.log"
	log_file="$logs_dir/$log_name"
	: > "$log_file"
	echo "compile $unit_id phase=$phase targets=${#targets[@]} mode=$dependency_mode elapsed=${elapsed}s"
	run_make "$unit_id" "$jobs" "$log_file" "$dependency_mode" false "${targets[@]}"
	status=$?
	if [ "$status" -eq 75 ]; then
		refresh_results
		write_state paused "$unit_id"
		return 75
	fi
	if [ "$status" -ne 0 ]; then
		echo "retry $unit_id with -j1 V=s"
		printf '\n[%s] retry with -j1 V=s\n' "$(date -Iseconds)" >> "$log_file"
		run_make "$unit_id" 1 "$log_file" "$dependency_mode" true "${targets[@]}"
		status=$?
		if [ "$status" -eq 75 ]; then
			refresh_results
			write_state paused "$unit_id"
			return 75
		fi
	fi
	if [ "$status" -ne 0 ]; then
		echo "queue unit $unit_id failed; see $log_file" >&2
		tail -n 200 "$log_file" >&2
		refresh_results
		record_failure "$unit_id" "$log_name"
		write_state failed "$unit_id"
		return 1
	fi
	mark_complete "$unit_id"
	refresh_results
	write_state running "$unit_id"
	echo "completed $unit_id phase=$phase elapsed=$(elapsed_seconds)s"
	return 0
}

queue_status=0
while IFS=$'\t' read -r unit_id phase package_ref target report; do
	[ -n "$unit_id" ] || continue
	if [ -n "$current_unit" ] && [ "$unit_id" != "$current_unit" ]; then
		process_unit "$current_unit" "$current_phase" "${current_targets[@]}"
		queue_status=$?
		[ "$queue_status" -eq 0 ] || break
		current_targets=()
	fi
	if [ "$unit_id" != "$current_unit" ]; then
		current_unit="$unit_id"
		current_phase="$phase"
	fi
	current_targets+=("$target")
done < "$queue_file"

if [ "$queue_status" -eq 0 ] && [ -n "$current_unit" ]; then
	process_unit "$current_unit" "$current_phase" "${current_targets[@]}"
	queue_status=$?
fi

refresh_results
if [ "$queue_status" -eq 75 ]; then
	write_state paused "${current_unit:--}"
	exit 75
fi
if [ "$queue_status" -ne 0 ]; then
	write_state failed "${current_unit:--}"
	exit 1
fi
if ! cmp -s "$results_dir/EXPECTED.txt" "$results_dir/SUCCESS.txt"; then
	write_state failed "${current_unit:--}"
	echo "Queue finished without successful results for every selected package" >&2
	exit 1
fi
write_state complete -
echo "package queue complete: $(<"$state_dir/QUEUE-STATE.txt")"
exit 0
