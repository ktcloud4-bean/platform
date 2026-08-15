#!/usr/bin/env bash
set -euo pipefail

backlog_path=${1:-docs/backlog.md}

if [[ ! -f "$backlog_path" ]]; then
  printf 'ERROR backlog file not found: %s\n' "$backlog_path" >&2
  exit 2
fi

allowed_statuses=(DONE READY BLOCKED DEFERRED)
declare -A allowed_status=()
declare -A task_status=()
declare -A task_line=()
declare -A task_predecessors=()
declare -a task_ids=()

for status in "${allowed_statuses[@]}"; do
  allowed_status["$status"]=1
done

errors=0
task_re='^[[:space:]]*\|[[:space:]]*`([^[:space:]`]+)[[:space:]]+([^[:space:]`]+)`[[:space:]]*\|'

line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_number += 1))

  if [[ ! $line =~ $task_re ]]; then
    continue
  fi

  task_id=${BASH_REMATCH[1]}
  status=${BASH_REMATCH[2]}
  IFS='|' read -r _ _ _ predecessor_cell _ <<< "$line"

  if [[ ! ${allowed_status[$status]+_} ]]; then
    printf 'ERROR invalid status: %s at line %d\n' "$status" "$line_number" >&2
    errors=1
  fi

  if [[ ${task_line[$task_id]+_} ]]; then
    printf 'ERROR duplicate ID: %s at lines %d and %d\n' \
      "$task_id" "${task_line[$task_id]}" "$line_number" >&2
    errors=1
    continue
  fi

  task_ids+=("$task_id")
  task_status["$task_id"]=$status
  task_line["$task_id"]=$line_number
  task_predecessors["$task_id"]=$predecessor_cell
done < "$backlog_path"

predecessor_re='`([A-Z0-9-]+)`'
for task_id in "${task_ids[@]}"; do
  remaining=${task_predecessors[$task_id]}

  while [[ $remaining =~ $predecessor_re ]]; do
    predecessor_id=${BASH_REMATCH[1]}
    matched_text=${BASH_REMATCH[0]}
    remaining=${remaining#*"$matched_text"}

    if [[ ! ${task_status[$predecessor_id]+_} ]]; then
      printf 'ERROR missing predecessor: %s required by %s at line %d\n' \
        "$predecessor_id" "$task_id" "${task_line[$task_id]}" >&2
      errors=1
      continue
    fi

    if [[ ${task_status[$task_id]} == READY && ${task_status[$predecessor_id]} != DONE ]]; then
      printf 'ERROR premature READY: %s requires %s=%s at line %d\n' \
        "$task_id" "$predecessor_id" "${task_status[$predecessor_id]}" "${task_line[$task_id]}" >&2
      errors=1
    fi
  done
done

if (( errors )); then
  exit 1
fi

printf 'BACKLOG_LINT=PASS tasks=%d\n' "${#task_ids[@]}"
