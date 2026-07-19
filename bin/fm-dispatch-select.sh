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
#     use claude/codex. Only a non-degraded, quota-fresh provider summary backed
#     by at least one freshly proven eligible profile is available. The best
#     adjusted headroom wins; exact ties use the first array element. Stale or
#     otherwise degraded summaries are diagnostics only. Agent Fleet trouble
#     degrades to the first element and never falls through to default-account
#     quota-axi data; enforced spawn still obtains the real fresh lease before
#     any provider launch.
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
# FM_DISPATCH_AGENT_FLEET and FM_AGENT_FLEET_BIN are test/lab-only. Production
# uses the fixed passwd-home ~/.local/bin/agent-fleet front door.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides the default 20 point stale margin.
set -u

FM_DISPATCH_SOURCE=${BASH_SOURCE[0]}
case "$FM_DISPATCH_SOURCE" in
  */*) FM_DISPATCH_SOURCE_DIR=${FM_DISPATCH_SOURCE%/*} ;;
  *) FM_DISPATCH_SOURCE_DIR=. ;;
esac
SCRIPT_DIR=$(CDPATH='' builtin cd -- "$FM_DISPATCH_SOURCE_DIR" 2>/dev/null && builtin pwd -P) || {
  echo "error: cannot resolve fm-dispatch-select directory" >&2
  exit 2
}
if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT=$FM_ROOT_OVERRIDE
else
  FM_ROOT=$(CDPATH='' builtin cd -- "$SCRIPT_DIR/.." 2>/dev/null && builtin pwd -P) || {
    echo "error: cannot resolve FirstMate root" >&2
    exit 2
  }
fi
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
FM_DISPATCH_JQ_BIN=$FM_ACCOUNT_SYSTEM_JQ_BIN
FM_DISPATCH_AWK_BIN=$FM_ACCOUNT_SYSTEM_AWK_BIN
FM_DISPATCH_CAT_BIN=$FM_ACCOUNT_SYSTEM_CAT_BIN

STALE_CLEAR_MARGIN=${FM_DISPATCH_STALE_CLEAR_MARGIN:-20}
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
ARGS=()

usage() {
  "$FM_DISPATCH_AWK_BIN" '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

if [ -n "${FM_DISPATCH_AGENT_FLEET_TIMEOUT:-}" ]; then
  AGENT_FLEET_TIMEOUT=$FM_DISPATCH_AGENT_FLEET_TIMEOUT
  case "$AGENT_FLEET_TIMEOUT" in
    ''|*[!0-9]*|0)
      echo "error: FM_DISPATCH_AGENT_FLEET_TIMEOUT must be a positive integer" >&2
      exit 2
      ;;
  esac
else
  AGENT_FLEET_TIMEOUT=$(fm_account_selection_timeout) || exit 2
fi

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
[ -x "$FM_DISPATCH_JQ_BIN" ] || { echo "error: fixed system jq is required" >&2; exit 2; }
[ -x "$FM_DISPATCH_AWK_BIN" ] || { echo "error: fixed system awk is required" >&2; exit 2; }
[ -x "$FM_DISPATCH_CAT_BIN" ] || { echo "error: fixed system cat is required" >&2; exit 2; }

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$("$FM_DISPATCH_CAT_BIN")
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | "$FM_DISPATCH_JQ_BIN" -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  # shellcheck disable=SC2016
  printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -c '
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
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | "$FM_DISPATCH_JQ_BIN" -r '
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

if printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -e 'any(.[]; (.account_profile? | type) == "string")' >/dev/null 2>&1; then
  echo "error: quota-balanced candidates cannot carry account_profile" >&2
  exit 2
fi

# Once any account pool participates, provider choice must come from Agent
# Fleet's same per-account view that concrete selection will use. Never compare
# those pools against quota-axi's default-account cache (double selection).
pooled_count=$(printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" '[.[] | select((.account_pool? | type) == "string")] | length')
pool_ids_valid=1
while IFS= read -r encoded_pool; do
  case "$encoded_pool" in
    \"*\") pool=${encoded_pool#\"}; pool=${pool%\"} ;;
    *) pool_ids_valid=0; continue ;;
  esac
  fm_account_valid_id "$pool" || pool_ids_valid=0
done < <(printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -c '.[].account_pool')
if [ "$pooled_count" -eq "$profile_count" ] && [ "$pool_ids_valid" = 1 ]; then
  routing_mode=off
else
  routing_mode=$(fm_account_resolve_mode "$CONFIG" 0 0) || exit 2
fi
if [ "$routing_mode" = enforce ]; then
  if [ "$pooled_count" -ne "$profile_count" ] || [ "$pool_ids_valid" != 1 ]; then
    echo "error: enforced quota-balanced dispatch requires a non-empty valid account_pool on every candidate" >&2
    exit 2
  fi
fi
if [ "$pooled_count" -gt 0 ]; then
  if [ "$pooled_count" -ne "$profile_count" ] || ! printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -e 'all(.[]; (.account_pool | length) > 0 and (.harness == "claude" or .harness == "codex"))' >/dev/null 2>&1; then
    log "account_pool quota-balanced candidates must all name claude/codex pools; using first profile"
    first_profile
    exit 0
  fi
  if ! agent_fleet_cmd=$(fm_account_fleet_bin "${FM_DISPATCH_AGENT_FLEET:-}"); then
    log "agent-fleet missing for account_pool summaries; using first profile"
    first_profile
    exit 0
  fi
  if ! fm_account_validate_contract "$agent_fleet_cmd"; then
    log "agent-fleet contract mismatch for account_pool summaries; using first profile"
    first_profile
    exit 0
  fi
  summaries='[]'
  while IFS=$(printf '\t') read -r index harness pool; do
    if ! pool_json=$(fm_account_run_fleet_bounded "$AGENT_FLEET_TIMEOUT" "$agent_fleet_cmd" --format json pool status --pool "$pool" --provider "$harness" 2>/dev/null); then
      log "agent-fleet pool status failed for $pool/$harness; using first profile"
      first_profile
      exit 0
    fi
    # shellcheck disable=SC2016
    if ! summary=$(printf '%s\n' "$pool_json" | "$FM_DISPATCH_JQ_BIN" -ec \
      --arg harness "$harness" --arg pool "$pool" '
      select(.schema == 1 and .pool == $pool and (.providers | type) == "array")
      | [.providers[] | select(.provider == $harness)]
      | select(length == 1)
      | .[0]
      | select(
          (.available | type) == "boolean"
          and (.selection_mode | type) == "string"
          and (.degraded | type) == "boolean"
          and (.eligible_profiles | type) == "number"
          and (.profiles | type) == "array"
        )
      | ([.profiles[]
          | select(
              .eligible == true
              and .quota_fresh == true
              and (.identity_binding_conflict // null) == null
              and (.live_identity_failure // null) == null
            )] | length) as $fresh_profiles
      | if (
          .available == true
          and .selection_mode == "quota"
          and .degraded == false
          and (.best_adjusted_headroom_percent | type) == "number"
          and .eligible_profiles == $fresh_profiles
          and $fresh_profiles > 0
        ) then {
          available: true,
          selection_mode: "quota",
          headroom: .best_adjusted_headroom_percent
        } else {
          available: false,
          selection_mode: "unavailable",
          headroom: null
        } end
    ' 2>/dev/null); then
      log "agent-fleet returned invalid pool summary for $pool/$harness; using first profile"
      first_profile
      exit 0
    fi
    # shellcheck disable=SC2016
    profile=$(printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -c --argjson index "$index" '.[$index]')
    # shellcheck disable=SC2016
    summaries=$(printf '%s\n' "$summaries" | "$FM_DISPATCH_JQ_BIN" -c \
      --argjson index "$index" --argjson profile "$profile" --argjson summary "$summary" \
      '. + [{index: $index, profile: $profile, summary: $summary}]')
  done < <(printf '%s\n' "$profiles_json" | "$FM_DISPATCH_JQ_BIN" -r 'to_entries[] | [.key, .value.harness, .value.account_pool] | @tsv')

  # shellcheck disable=SC2016
  selection=$(printf '%s\n' "$summaries" | "$FM_DISPATCH_JQ_BIN" -ec '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end)
      + {account_pool: $p.account_pool}
      + (if ($p.account_profile? | type) == "string" then {account_profile: $p.account_profile} else {} end);
    ([.[] | select(.summary.available == true and .summary.selection_mode == "quota" and (.summary.headroom | type) == "number")]
      | sort_by([-(.summary.headroom), .index])) as $fresh
    | if ($fresh | length) > 0 then {fallback: false, profile: clean($fresh[0].profile)}
      else {fallback: true, reason: "no freshly routeable Agent Fleet account pools", profile: clean(.[0].profile)}
      end
  ') || {
    log "Agent Fleet pool summaries could not be evaluated; using first profile"
    first_profile
    exit 0
  }
  if [ "$(printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -r '.fallback')" = true ]; then
    log "$(printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -r '.reason'); using first profile"
  fi
  printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -c '.profile'
  exit 0
fi

if [ -n "$QUOTA_JSON_FILE" ]; then
  if ! quota_json=$("$FM_DISPATCH_CAT_BIN" "$QUOTA_JSON_FILE" 2>/dev/null); then
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

if ! printf '%s\n' "$quota_json" | "$FM_DISPATCH_JQ_BIN" -e 'type == "object" and (.providers | type) == "array"' >/dev/null 2>&1; then
  log "quota-axi returned unparseable JSON; using first profile"
  first_profile
  exit 0
fi

# shellcheck disable=SC2016
selection=$(printf '%s\n' "$quota_json" | "$FM_DISPATCH_JQ_BIN" -ec \
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

if [ "$(printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -r '.fallback')" = true ]; then
  log "$(printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -r '.reason'); using first profile"
fi
printf '%s\n' "$selection" | "$FM_DISPATCH_JQ_BIN" -c '.profile'
