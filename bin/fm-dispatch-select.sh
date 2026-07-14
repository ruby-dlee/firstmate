#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--quota-json <file>] [<rule-or-use-json>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# quota-balanced is deterministic, and this header is the single owner of its
# contract:
#   - Any candidate carrying account_profile is invalid because pinned profiles
#     are direct per-spawn overrides, never inputs to quota-balanced selection.
#   - A candidate set carrying account_pool uses only Agent Fleet's no-secret
#     `pool status` summaries. Every candidate must then carry account_pool and
#     use claude/codex. The best available pool's adjusted headroom wins; exact
#     ties use the first array element. A quota-fresh pool beats a degraded
#     fallback pool; if every available pool is degraded, the first available
#     candidate wins. Agent Fleet trouble degrades to the first element and
#     never falls through to default-account quota-axi data.
#   - Enforced account routing rejects quota-balanced candidates without pools.
#     Off and observe retain the legacy no-pool quota-axi path.
#   - Per candidate vendor it takes the minimum percentRemaining across that
#     vendor's GENERAL windows only - Claude five_hour and seven_day, Codex
#     five_hour and weekly - ignoring model-scoped windows such as model:fable
#     and model:codex_bengalfox:*.
#   - The vendor with the higher minimum remaining quota wins; an exact tie
#     between equally trusted candidates uses the first array element.
#   - Stale-but-cached general-window numbers are usable, but a fresh candidate
#     wins unless the stale candidate's minimum is at least the stale-clear
#     margin higher (default 20 points - the definition of "clearly less
#     constrained").
#   - A vendor absent from quota output, or with no usable general windows, is
#     unavailable; selection happens among available candidates.
#   - If quota-axi is missing, exits non-zero, returns unparseable JSON, or no
#     candidate is usable, the reason is logged to stderr and the first array
#     element is printed - quota trouble never blocks dispatch.
#
# quota-balanced uses quota-axi --json unless --quota-json supplies a fixture.
# FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_DISPATCH_AGENT_FLEET overrides FM_AGENT_FLEET_BIN, which overrides the
# Agent Fleet command resolved from PATH.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides the default 20 point stale margin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"

STALE_CLEAR_MARGIN=${FM_DISPATCH_STALE_CLEAR_MARGIN:-20}
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
ARGS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --quota-json)
      [ "$#" -gt 1 ] || { echo "error: --quota-json requires a file" >&2; exit 2; }
      QUOTA_JSON_FILE=$2
      shift 2
      ;;
    --quota-json=*)
      QUOTA_JSON_FILE=${1#--quota-json=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$(cat)
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | jq 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end)
      + (if ($p.account_pool? | type) == "string" then {account_pool: $p.account_pool} else {} end)
      + (if ($p.account_profile? | type) == "string" then {account_profile: $p.account_profile} else {} end);
    clean(.[0])
  '
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

if [ "$select_strategy" != quota-balanced ]; then
  if [ -n "$select_strategy" ]; then
    log "unknown select strategy '$select_strategy'; using first profile"
  fi
  first_profile
  exit 0
fi

if printf '%s\n' "$profiles_json" | jq -e 'any(.[]; (.account_profile? | type) == "string")' >/dev/null 2>&1; then
  echo "error: quota-balanced candidates cannot carry account_profile" >&2
  exit 2
fi

# Once any account pool participates, provider choice must come from Agent
# Fleet's same per-account view that concrete selection will use. Never compare
# those pools against quota-axi's default-account cache (double selection).
pooled_count=$(printf '%s\n' "$profiles_json" | jq '[.[] | select((.account_pool? | type) == "string")] | length')
routing_mode=$(fm_account_resolve_mode "$CONFIG" 0 0) || exit 2
if [ "$routing_mode" = enforce ]; then
  pool_ids_valid=1
  while IFS= read -r encoded_pool; do
    case "$encoded_pool" in
      \"*\") pool=${encoded_pool#\"}; pool=${pool%\"} ;;
      *) pool_ids_valid=0; continue ;;
    esac
    fm_account_valid_id "$pool" || pool_ids_valid=0
  done < <(printf '%s\n' "$profiles_json" | jq -c '.[].account_pool')
  if [ "$pooled_count" -ne "$profile_count" ] || [ "$pool_ids_valid" != 1 ]; then
    echo "error: enforced quota-balanced dispatch requires a non-empty valid account_pool on every candidate" >&2
    exit 2
  fi
fi
if [ "$pooled_count" -gt 0 ]; then
  if [ "$pooled_count" -ne "$profile_count" ] || ! printf '%s\n' "$profiles_json" | jq -e 'all(.[]; (.account_pool | length) > 0 and (.harness == "claude" or .harness == "codex"))' >/dev/null 2>&1; then
    log "account_pool quota-balanced candidates must all name claude/codex pools; using first profile"
    first_profile
    exit 0
  fi
  agent_fleet_cmd=${FM_DISPATCH_AGENT_FLEET:-${FM_AGENT_FLEET_BIN:-agent-fleet}}
  if ! command -v "$agent_fleet_cmd" >/dev/null 2>&1; then
    log "agent-fleet missing for account_pool summaries; using first profile"
    first_profile
    exit 0
  fi
  summaries='[]'
  while IFS=$(printf '\t') read -r index harness pool; do
    if ! pool_json=$("$agent_fleet_cmd" --format json pool status --pool "$pool" --provider "$harness" 2>/dev/null); then
      log "agent-fleet pool status failed for $pool/$harness; using first profile"
      first_profile
      exit 0
    fi
    if ! summary=$(printf '%s\n' "$pool_json" | jq -ec --arg harness "$harness" '
      .providers[]? | select(.provider == $harness)
      | select((.available | type) == "boolean")
      | {
          available,
          selection_mode: (.selection_mode // "unavailable"),
          headroom: .best_adjusted_headroom_percent
        }
    ' 2>/dev/null); then
      log "agent-fleet returned invalid pool summary for $pool/$harness; using first profile"
      first_profile
      exit 0
    fi
    profile=$(printf '%s\n' "$profiles_json" | jq -c --argjson index "$index" '.[$index]')
    summaries=$(printf '%s\n' "$summaries" | jq -c \
      --argjson index "$index" --argjson profile "$profile" --argjson summary "$summary" \
      '. + [{index: $index, profile: $profile, summary: $summary}]')
  done < <(printf '%s\n' "$profiles_json" | jq -r 'to_entries[] | [.key, .value.harness, .value.account_pool] | @tsv')

  selection=$(printf '%s\n' "$summaries" | jq -ec '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end)
      + {account_pool: $p.account_pool}
      + (if ($p.account_profile? | type) == "string" then {account_profile: $p.account_profile} else {} end);
    ([.[] | select(.summary.available == true and .summary.selection_mode == "quota" and (.summary.headroom | type) == "number")]
      | sort_by([-(.summary.headroom), .index])) as $fresh
    | ([.[] | select(.summary.available == true and .summary.selection_mode != "quota")]
      | sort_by(.index)) as $fallback
    | if ($fresh | length) > 0 then {fallback: false, profile: clean($fresh[0].profile)}
      elif ($fallback | length) > 0 then {fallback: false, profile: clean($fallback[0].profile)}
      else {fallback: true, reason: "no available Agent Fleet account pools", profile: clean(.[0].profile)}
      end
  ') || {
    log "Agent Fleet pool summaries could not be evaluated; using first profile"
    first_profile
    exit 0
  }
  if [ "$(printf '%s\n' "$selection" | jq -r '.fallback')" = true ]; then
    log "$(printf '%s\n' "$selection" | jq -r '.reason'); using first profile"
  fi
  printf '%s\n' "$selection" | jq -c '.profile'
  exit 0
fi

if [ -n "$QUOTA_JSON_FILE" ]; then
  if ! quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null); then
    log "cannot read quota JSON; using first profile"
    first_profile
    exit 0
  fi
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  if ! command -v "$quota_cmd" >/dev/null 2>&1; then
    log "quota-axi missing; using first profile"
    first_profile
    exit 0
  fi
  quota_json=$("$quota_cmd" --json 2>/dev/null)
  quota_status=$?
  if [ "$quota_status" -ne 0 ]; then
    log "quota-axi exited $quota_status; using first profile"
    first_profile
    exit 0
  fi
fi

if ! printf '%s\n' "$quota_json" | jq -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1; then
  log "quota-axi returned unparseable JSON; using first profile"
  first_profile
  exit 0
fi

selection=$(printf '%s\n' "$quota_json" | jq -ec \
  --argjson profiles "$profiles_json" \
  --argjson margin "$STALE_CLEAR_MARGIN" '
  def clean($p):
    {harness: $p.harness}
    + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
    + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end)
    + (if ($p.account_pool? | type) == "string" then {account_pool: $p.account_pool} else {} end)
    + (if ($p.account_profile? | type) == "string" then {account_profile: $p.account_profile} else {} end);
  def provider_for($h): [.providers[]? | select(.provider == $h)][0];
  def general_ids($h):
    if $h == "claude" then ["five_hour", "seven_day"]
    elif $h == "codex" then ["five_hour", "weekly"]
    else []
    end;
  def candidate_metric($p; $i):
    . as $root
    | ($p.harness // "") as $h
    | ($root | provider_for($h)) as $provider
    | if ($provider == null) or ((general_ids($h) | length) == 0) then empty
      else
        (($provider.windows // [])
          | map(. as $window
            | select(((general_ids($h) | index($window.id)) != null)
              and (($window.kind? // "") != "model")
              and (($window.percentRemaining? | type) == "number")))) as $windows
        | if ($windows | length) == 0 then empty
          else {
            index: $i,
            profile: clean($p),
            harness: $h,
            min: ($windows | map(.percentRemaining) | min),
            fresh: (($provider.state.status? // "") == "fresh")
          }
          end
      end;
  def better($a; $b):
    if $a == null then $b
    elif $b == null then $a
    elif ($b.min > $a.min) then $b
    elif ($b.min == $a.min and $b.index < $a.index) then $b
    else $a
    end;
  def best_by_min($xs): reduce $xs[] as $x (null; better(.; $x));
  . as $quota_root
  | ([$profiles | to_entries[] | . as $entry | ($quota_root | candidate_metric($entry.value; $entry.key))]) as $candidates
  | if ($candidates | length) == 0 then {
      fallback: true,
      reason: "no usable quota windows for candidate vendors",
      profile: clean($profiles[0])
    }
    else
      (best_by_min($candidates | map(select(.fresh)))) as $fresh_best
      | (best_by_min($candidates | map(select(.fresh | not)))) as $stale_best
      | (if $fresh_best != null and $stale_best != null then
          if $stale_best.min >= ($fresh_best.min + $margin) then $stale_best else $fresh_best end
        elif $fresh_best != null then $fresh_best
        else $stale_best
        end) as $chosen
      | {fallback: false, profile: $chosen.profile}
    end
' 2>/dev/null) || {
  log "quota-axi data could not be evaluated; using first profile"
  first_profile
  exit 0
}

if [ "$(printf '%s\n' "$selection" | jq -r '.fallback')" = true ]; then
  log "$(printf '%s\n' "$selection" | jq -r '.reason'); using first profile"
fi
printf '%s\n' "$selection" | jq -c '.profile'
