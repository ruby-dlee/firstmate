#!/usr/bin/env bash
# Select and prepare direct Claude or Codex account-directory launches.
# Usage:
#   fm-account-directory.sh select <claude|codex>
#   fm-account-directory.sh check-credential <claude|codex> <account-home>
#   fm-account-directory.sh provider-command claude
#   fm-account-directory.sh install-herdr-hook <claude|codex> <account-home>
#   fm-account-directory.sh prepare <claude|codex>
#
# This header is the single owner of the direct account-directory contract.
# FM_ACCOUNT_DIRECTORY_CUTOVER: direct-observe-passwd-home-v2
# Account homes are discovered under the current passwd user's
# .local/share/agent-fleet/accounts/<vendor>/ tree without fixed counts.
# Codex selection removes that account's quota-axi window cache immediately
# before every read, sets CODEX_HOME plus the account-isolated XDG_CACHE_HOME,
# accepts only a fresh result with at least one numeric five_hour or weekly
# window, and picks the account with the highest minimum remaining percentage.
# A Codex account with no such freshly readable window is skipped as unhealthy.
# Claude authentication is checked with this script's
# `check-credential claude` command.
# That is the one authoritative definition of a usable Claude account directory
# for selection and spawn preflight.
# The check clears ambient provider credentials, sets CLAUDE_CONFIG_DIR, and
# invokes the same passwd-home launcher that a direct crew launch receives:
# ~/.local/bin/claude.
# Using the stable launcher symlink survives native Claude Code upgrades and
# avoids PATH wrappers that unset CLAUDE_CONFIG_DIR.
# A usable directory must make `claude auth status` return valid JSON with
# loggedIn=true before the bounded check expires.
# Claude selection skips unusable directories and chooses the first usable
# directory in stable bytewise sort order.
# Claude quota is still not distinguishable per config directory, so selection
# never treats a missing usage window as account failure.
#
# macOS credential mechanism, verified 2026-07-26 with Claude Code 2.1.220:
# a custom config directory stores OAuth JSON in the login Keychain service
# `Claude Code-credentials-<first 8 hex of sha256 of the literal path>`.
# The incident's broken account homes had service entries whose account
# attribute was the passwd username; a newly authenticated working custom home
# used account `unknown`.
# Both item shapes had the same ACL, and `/usr/bin/security ... -w` could read
# both without prompting, so application ACL or versioned-binary ancestry was
# not the failure.
# The real CLI accepted every broken item's access token through the transient
# CLAUDE_CODE_OAUTH_TOKEN environment, proving the stored payloads were valid;
# it could not discover those same payloads through its native Keychain lookup.
# Updating a stale item during interactive login left its old account attribute
# in place, which explains why that process worked until the next spawn.
#
# `claude setup-token` was also evaluated.
# Claude Code honors its one-year, inference-only token through
# CLAUDE_CODE_OAUTH_TOKEN, but the command prints rather than stores the secret.
# Firstmate does not select that route because persisting and injecting the
# secret would add a second credential store and could expose it through launch
# arguments, environment capture, or account-home files.
# A clean native `claude auth login` is the selected durable mechanism because
# Claude owns storage and refresh, and Firstmate never handles the secret.
#
# Set up a new Claude account home from scratch:
#   account_home="$HOME/.local/share/agent-fleet/accounts/claude/<name>"
#   install -d -m 700 "$account_home"
#   CLAUDE_CONFIG_DIR="$account_home" "$HOME/.local/bin/claude" auth login
#   bin/fm-account-directory.sh check-credential claude "$account_home"
# Repair an existing home whose stale Keychain item has the wrong account
# attribute by resetting only that literal config directory's service first:
#   suffix="$(printf '%s' "$account_home" | shasum -a 256 | cut -c1-8)"
#   service="Claude Code-credentials-$suffix"
#   while security find-generic-password -s "$service" >/dev/null 2>&1; do
#     security delete-generic-password -s "$service" >/dev/null || break
#   done
#   CLAUDE_CONFIG_DIR="$account_home" "$HOME/.local/bin/claude" auth login
#   bin/fm-account-directory.sh check-credential claude "$account_home"
#
# Selection prints only the chosen absolute account home on stdout and logs
# health, fallback, and choice diagnostics on stderr.
# prepare selects the account, verifies a usable credential before endpoint
# creation can begin, and idempotently runs Herdr's own integration installer
# with CODEX_HOME or CLAUDE_CONFIG_DIR set to the chosen home.
# Codex uses a cheap read-only auth.json credential-material check.
# Claude has no sufficient on-disk credential marker on macOS, so it uses the
# CLI's local `auth status --json` check, bounded to 15 seconds and never making
# a model call.
# A failed check names the selected account home and prints the exact scoped
# provider login command a human can run.
# It verifies the installed per-profile hook before printing the chosen home.
#
# Credential state is read-only.
# This script never logs in, imports credentials, or invokes a provider model.
# Test-only command, root, passwd-home, Perl, and timeout overrides require
# FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1.
set -u

TEST_LAB_TOKEN=firstmate-account-directory-test-lab-v1

usage() {
  sed -n '2,90p' "$0" | sed 's/^# \{0,1\}//' >&2
}

log() {
  printf 'fm-account-directory: %s\n' "$*" >&2
}

test_lab_enabled() {
  [ "${FM_ACCOUNT_DIRECTORY_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

system_perl() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_PERL_BIN:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_PERL_BIN"
  else
    printf '%s\n' /usr/bin/perl
  fi
}

passwd_home() {
  local home perl_bin
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_PASSWD_HOME:-}" ]; then
    home=$FM_ACCOUNT_DIRECTORY_PASSWD_HOME
  else
    perl_bin=$(system_perl) || return 1
    [ -x /usr/bin/env ] && [ -x "$perl_bin" ] || {
      echo "error: /usr/bin/env and /usr/bin/perl are required to resolve the current passwd home" >&2
      return 1
    }
    # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
    home=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$perl_bin" -e '
      my @p = getpwuid($<);
      exit 1 unless @p && defined $p[7] && $p[7] =~ m{^/};
      exit 1 if $p[7] =~ /[\x00-\x1f\x7f]/;
      print $p[7];
    ' 2>/dev/null) || {
      echo "error: cannot resolve the current passwd home" >&2
      return 1
    }
  fi
  case "$home" in
    *$'\n'*|*$'\r'*)
      echo "error: passwd home contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: passwd home must be absolute: $home" >&2
      return 1
      ;;
  esac
  [ -d "$home" ] && [ ! -L "$home" ] || {
    echo "error: passwd home is not a real directory: $home" >&2
    return 1
  }
  printf '%s\n' "$home"
}

account_root() {
  local root home
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_ROOT:-}" ]; then
    root=$FM_ACCOUNT_DIRECTORY_ROOT
  else
    home=$(passwd_home) || return 1
    root=$home/.local/share/agent-fleet/accounts
  fi
  case "$root" in
    *$'\n'*|*$'\r'*)
      echo "error: account-directory root contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: account-directory root must be absolute: $root" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root"
}

quota_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_QUOTA_AXI:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_QUOTA_AXI"
    return 0
  fi
  command -v quota-axi 2>/dev/null || {
    echo "error: quota-axi is required for fresh Codex account selection" >&2
    return 1
  }
}

herdr_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_HERDR:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_HERDR"
    return 0
  fi
  command -v herdr 2>/dev/null || {
    echo "error: herdr is required to install the selected account's integration hook" >&2
    return 1
  }
}

quota_timeout_seconds() {
  local timeout=15
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS:-}" ]; then
    timeout=$FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS
  fi
  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "error: Codex quota timeout must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$timeout"
}

claude_auth_timeout_seconds() {
  local timeout=15
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_CLAUDE_AUTH_TIMEOUT_SECONDS:-}" ]; then
    timeout=$FM_ACCOUNT_DIRECTORY_CLAUDE_AUTH_TIMEOUT_SECONDS
  fi
  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "error: Claude auth timeout must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$timeout"
}

run_bounded() {
  local timeout=$1 perl_bin
  shift
  perl_bin=$(system_perl) || return 1
  [ -x "$perl_bin" ] || return 127
  # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
  PERL5LIB='' PERL5OPT='' "$perl_bin" -e '
    use POSIX qw(setpgid WNOHANG);
    my ($timeout, @command) = @ARGV;
    my $pid = fork();
    exit 125 unless defined $pid;
    if ($pid == 0) {
      setpgid(0, 0);
      exec {$command[0]} @command;
      exit 127;
    }
    setpgid($pid, $pid);
    my $deadline = time() + $timeout;
    while (1) {
      my $waited = waitpid($pid, WNOHANG);
      if ($waited == $pid) {
        my $status = $?;
        exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
      }
      exit 125 if $waited == -1;
      if (time() >= $deadline) {
        kill "TERM", -$pid;
        for (1 .. 4) {
          select undef, undef, undef, 0.05;
          exit 124 if waitpid($pid, WNOHANG) == $pid;
        }
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit 124;
      }
      select undef, undef, undef, 0.05;
    }
  ' "$timeout" "$@"
}

valid_account_home() { # <vendor-dir> <candidate>
  local vendor_dir=$1 candidate=$2 name
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  case "$candidate" in
    "$vendor_dir"/*) ;;
    *) return 1 ;;
  esac
  name=${candidate##*/}
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

provider_binary() { # <vendor> [account-home]
  local vendor=$1 account_home=${2:-} override manifest binary install_path home perl_bin
  if test_lab_enabled; then
    case "$vendor" in
      claude) override=${FM_ACCOUNT_DIRECTORY_CLAUDE_BIN:-} ;;
      codex) override=${FM_ACCOUNT_DIRECTORY_CODEX_BIN:-} ;;
      *) return 1 ;;
    esac
    if [ -n "$override" ]; then
      [ -f "$override" ] && [ ! -L "$override" ] && [ -x "$override" ] || {
        echo "error: test $vendor provider binary is not a real executable: $override" >&2
        return 1
      }
      printf '%s\n' "$override"
      return 0
    fi
  fi
  home=$(passwd_home) || return 1
  install_path=$home/.local/bin/$vendor
  if [ "$vendor" = claude ]; then
    case "$install_path" in
      *$'\n'*|*$'\r'*)
        echo "error: Claude launcher path contains a line break" >&2
        return 1
        ;;
      /*) ;;
      *)
        echo "error: Claude launcher path must be absolute: $install_path" >&2
        return 1
        ;;
    esac
    [ -f "$install_path" ] && [ -x "$install_path" ] || {
      echo "error: Claude's stable native launcher is not executable: $install_path" >&2
      return 1
    }
    printf '%s\n' "$install_path"
    return 0
  fi
  manifest=$account_home/.agent-fleet-provider-binary.json
  if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
    binary=$(jq -er '.binary.resolved_path | select(type == "string" and startswith("/"))' "$manifest" 2>/dev/null) || binary=
    if [ -n "$binary" ] && [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ]; then
      printf '%s\n' "$binary"
      return 0
    fi
  fi
  perl_bin=$(system_perl) || return 1
  # shellcheck disable=SC2016 # Perl source is intentionally single-quoted.
  binary=$("$perl_bin" -MCwd=realpath -e '
    my $path = realpath($ARGV[0]);
    exit 1 unless defined $path && $path =~ m{^/} && $path !~ /[\x00-\x1f\x7f]/;
    print $path;
  ' "$install_path" 2>/dev/null) || binary=
  if [ -n "$binary" ] && [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ]; then
    printf '%s\n' "$binary"
    return 0
  fi
  echo "error: cannot resolve the $vendor provider binary for account credential verification at $account_home" >&2
  return 1
}

credential_login_command() { # <vendor> <account-home> [provider-binary]
  local vendor=$1 account_home=$2 provider_bin=${3:-$1}
  case "$vendor" in
    codex)
      printf 'CODEX_HOME=%s %s login' "$(shell_quote "$account_home")" "$(shell_quote "$provider_bin")"
      ;;
    claude)
      printf 'CLAUDE_CONFIG_DIR=%s %s auth login' "$(shell_quote "$account_home")" "$(shell_quote "$provider_bin")"
      ;;
  esac
}

check_codex_credential() { # <account-home>
  local account_home=$1 credential provider_bin login
  credential=$account_home/auth.json
  provider_bin=$(provider_binary codex "$account_home" 2>/dev/null || printf 'codex')
  login=$(credential_login_command codex "$account_home" "$provider_bin")
  if [ ! -f "$credential" ] || [ -L "$credential" ] || ! jq -e '
    ((.tokens.access_token? | type) == "string" and (.tokens.access_token | length) > 0
      and (.tokens.refresh_token? | type) == "string" and (.tokens.refresh_token | length) > 0)
    or ((.OPENAI_API_KEY? | type) == "string" and (.OPENAI_API_KEY | length) > 0)
  ' "$credential" >/dev/null 2>&1; then
    echo "error: selected codex account directory '$account_home' has no usable on-disk credential; run: $login" >&2
    return 1
  fi
}

fresh_claude_auth_json() { # <account-home> <provider-binary>
  local account_home=$1 provider_bin=$2 timeout status environment_name
  timeout=$(claude_auth_timeout_seconds) || return 1
  (
    while IFS='=' read -r environment_name _; do
      case "$environment_name" in
        ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|\
        CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_OAUTH_REFRESH_TOKEN|\
        CLAUDE_CODE_OAUTH_SCOPES|CLAUDE_CODE_USE_BEDROCK|\
        CLAUDE_CODE_USE_FOUNDRY|CLAUDE_CODE_USE_VERTEX)
          unset "$environment_name"
          ;;
      esac
    done < <(/usr/bin/env)
    CLAUDE_CONFIG_DIR=$account_home
    export CLAUDE_CONFIG_DIR
    if run_bounded "$timeout" "$provider_bin" auth status --json 2>/dev/null; then
      return 0
    else
      status=$?
    fi
    if [ "$status" -eq 124 ]; then
      log "claude account $account_home unusable: auth check timed out after ${timeout}s"
    fi
    return "$status"
  )
}

check_claude_credential() { # <account-home>
  local account_home=$1 provider_bin status_json login
  provider_bin=$(provider_binary claude "$account_home") || return 1
  login=$(credential_login_command claude "$account_home" "$provider_bin")
  status_json=$(fresh_claude_auth_json "$account_home" "$provider_bin") || status_json=
  if ! jq -e '.loggedIn == true' >/dev/null 2>&1 <<EOF
$status_json
EOF
  then
    echo "error: selected claude account directory '$account_home' has no usable credential; run: $login" >&2
    return 1
  fi
}

check_credential() { # <vendor> <account-home>
  local vendor=$1 account_home=$2 root vendor_dir
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  valid_account_home "$vendor_dir" "$account_home" || {
    echo "error: unsafe $vendor account home for credential verification: $account_home" >&2
    return 1
  }
  case "$vendor" in
    codex) check_codex_credential "$account_home" ;;
    claude) check_claude_credential "$account_home" ;;
    *)
      echo "error: account credential verification supports only claude or codex, not '$vendor'" >&2
      return 1
      ;;
  esac
}

first_account_home() { # <vendor>
  local vendor=$1 root vendor_dir candidate
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for $vendor at $vendor_dir" >&2
    return 1
  }
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  echo "error: no account directories found for $vendor under $vendor_dir" >&2
  return 1
}

fresh_codex_usage_json() { # <account-home> <quota-command>
  local account_home=$1 quota_bin=$2 cache_home cache_file environment_name timeout status
  timeout=$(quota_timeout_seconds) || return 1
  cache_home=$account_home/.agent-fleet-quota-cache
  cache_file=$cache_home/quota-axi/quotas.json
  if { [ -e "$cache_home" ] || [ -L "$cache_home" ]; } \
    && { [ ! -d "$cache_home" ] || [ -L "$cache_home" ]; }; then
    log "codex account $account_home skipped: its quota cache root is not a real directory"
    return 1
  fi
  if { [ -e "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; } \
    && { [ ! -d "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; }; then
    log "codex account $account_home skipped: its quota-axi cache directory is not a real directory"
    return 1
  fi
  if [ -e "$cache_file" ] || [ -L "$cache_file" ]; then
    rm -f "$cache_file" || {
      log "codex account $account_home skipped: could not clear its quota cache for a fresh health read"
      return 1
    }
  fi
  (
    while IFS='=' read -r environment_name _; do
      case "$environment_name" in
        XDG_*|QUOTA_AXI_*|AGENT_FLEET_*) unset "$environment_name" ;;
      esac
    done < <(/usr/bin/env)
    CODEX_HOME=$account_home
    XDG_CACHE_HOME=$cache_home
    export CODEX_HOME XDG_CACHE_HOME
    if run_bounded "$timeout" "$quota_bin" --provider codex --json 2>/dev/null; then
      return 0
    else
      status=$?
    fi
    if [ "$status" -eq 124 ]; then
      log "codex account $account_home skipped: quota read timed out after ${timeout}s"
    fi
    return "$status"
  )
}

codex_score() { # <quota-json>
  jq -er '
    [.providers[]?
      | select(.provider == "codex" and .state.status == "fresh")
      | (.windows // [])[]?
      | select((.id == "five_hour" or .id == "weekly")
          and (.kind // "") != "model"
          and (.percentRemaining | type) == "number")
      | .percentRemaining]
    | if length == 0 then empty else min end
  ' 2>/dev/null <<EOF
$1
EOF
}

select_codex() {
  local root vendor_dir quota_bin candidate usage score
  local best_home='' best_score=''
  root=$(account_root) || return 1
  vendor_dir=$root/codex
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for codex at $vendor_dir" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for Codex account usage selection" >&2
    return 1
  }
  quota_bin=$(quota_command) || return 1
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    usage=$(fresh_codex_usage_json "$candidate" "$quota_bin") || usage=
    score=$(codex_score "$usage") || score=
    if [ -z "$score" ]; then
      log "codex account $candidate skipped: no freshly readable usage window"
      continue
    fi
    log "codex account $candidate fresh remaining score=$score"
    if [ -z "$best_home" ] || awk -v candidate_score="$score" -v current_score="$best_score" \
      'BEGIN { exit !(candidate_score > current_score) }'; then
      best_home=$candidate
      best_score=$score
    fi
  done
  [ -n "$best_home" ] || {
    echo "error: no healthy Codex account has a freshly readable usage window" >&2
    return 1
  }
  log "selected codex account $best_home with fresh remaining score=$best_score"
  printf '%s\n' "$best_home"
}

select_claude() {
  local root vendor_dir candidate
  root=$(account_root) || return 1
  vendor_dir=$root/claude
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for claude at $vendor_dir" >&2
    return 1
  }
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    check_credential claude "$candidate" || continue
    log "claude account $candidate usable: native subscription credential is readable"
    log "CLAUDE USAGE UNREADABLE: authenticated account $candidate has no config-directory-specific quota read; selecting the first usable account by stable sort"
    printf '%s\n' "$candidate"
    return 0
  done
  echo "error: no usable Claude account has a readable native subscription credential" >&2
  return 1
}

select_account() { # <vendor>
  case "$1" in
    codex) select_codex ;;
    claude) select_claude ;;
    *)
      echo "error: direct account-directory selection supports only claude or codex, not '$1'" >&2
      return 1
      ;;
  esac
}

install_herdr_hook() { # <vendor> <account-home>
  local vendor=$1 account_home=$2 root vendor_dir herdr_bin expected_hook
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  valid_account_home "$vendor_dir" "$account_home" || {
    echo "error: unsafe $vendor account home for Herdr hook installation: $account_home" >&2
    return 1
  }
  herdr_bin=$(herdr_command) || return 1
  case "$vendor" in
    codex)
      CODEX_HOME=$account_home "$herdr_bin" integration install codex >/dev/null || {
        echo "error: Herdr Codex integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/herdr-agent-state.sh
      ;;
    claude)
      CLAUDE_CONFIG_DIR=$account_home "$herdr_bin" integration install claude >/dev/null || {
        echo "error: Herdr Claude integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/hooks/herdr-agent-state.sh
      ;;
    *)
      echo "error: Herdr account hook installation supports only claude or codex, not '$vendor'" >&2
      return 1
      ;;
  esac
  [ -f "$expected_hook" ] && [ ! -L "$expected_hook" ] || {
    echo "error: Herdr installer did not create the expected $vendor hook at $expected_hook" >&2
    return 1
  }
  log "Herdr $vendor hook ready at $expected_hook"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  select)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    select_account "$2"
    ;;
  check-credential)
    [ "$#" -eq 3 ] || { usage; exit 2; }
    check_credential "$2" "$3"
    ;;
  provider-command)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    [ "$2" = claude ] || {
      echo "error: provider-command currently supports only claude, not '$2'" >&2
      exit 1
    }
    provider_binary claude
    ;;
  install-herdr-hook)
    [ "$#" -eq 3 ] || { usage; exit 2; }
    install_herdr_hook "$2" "$3"
    ;;
  prepare)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    selected_home=$(select_account "$2") || exit 1
    check_credential "$2" "$selected_home" || exit 1
    install_herdr_hook "$2" "$selected_home" || exit 1
    printf '%s\n' "$selected_home"
    ;;
  *)
    usage
    exit 2
    ;;
esac
