#!/usr/bin/env bash
# Shared, side-effect-free harness prompt classifiers and operator-command
# formatters for fm-spawn.sh and fm-watch.sh.
#
# Startup trust dialogs and mid-run permission grants are deliberately exposed
# through separate functions.
# A caller must never reuse fm_startup_trust_dialog_kind after it has positive
# evidence that the current launch processed its brief.
# Exact harness evidence and acceptance policy live in
# .agents/skills/harness-adapters/SKILL.md.

FM_HARNESS_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

fm_harness_prompt_tail() {  # <tail40>
  printf '%s\n' "$1" | tail -16
}

fm_pane_has_verified_busy_signature() {  # <tail40>
  printf '%s\n' "$1" \
    | grep -v '^[[:space:]]*$' \
    | tail -6 \
    | grep -qiE "$FM_HARNESS_BUSY_REGEX_DEFAULT"
}

# Print exactly one recognized startup kind, or return nonzero.
# A title fragment, a partial shape, a wrong-harness shape, two complete shapes,
# or a pane that also carries a verified busy footer is not a startup match.
fm_startup_trust_dialog_kind() {  # <harness> <tail40>
  local harness=$1 tail40=$2 prompt_tail matches=0 result=
  fm_pane_has_verified_busy_signature "$tail40" && return 1
  prompt_tail=$(fm_harness_prompt_tail "$tail40")

  case "$harness" in
    claude|claude:*)
      if printf '%s\n' "$prompt_tail" | grep -Fq 'Quick safety check: Is this a project you created or one you trust?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, I trust this folder' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, exit' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Enter to confirm.*Esc to cancel'; then
        matches=$((matches + 1))
        result=claude-workspace-trust
      fi
      if printf '%s\n' "$prompt_tail" | grep -Fq 'Hooks need review' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Trust all on first launch' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Review hooks' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Exit' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Enter to confirm.*Esc to cancel'; then
        matches=$((matches + 1))
        result=claude-hook-trust
      fi
      ;;
    codex|codex:*)
      if printf '%s\n' "$prompt_tail" | grep -Fq 'Do you trust the contents of this directory?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, continue' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, quit'; then
        matches=$((matches + 1))
        result=codex-directory-trust
      fi
      ;;
  esac

  [ "$matches" -eq 1 ] || return 1
  printf '%s' "$result"
}

# Print one protected mid-run grant kind, or return nonzero.
# Directory trust is considered mid-run only when the caller passes a positive
# current-generation processing verdict as the third argument.
fm_midrun_permission_prompt_kind() {  # <harness> <tail40> <allow-directory-trust>
  local harness=$1 tail40=$2 allow_directory_trust=${3:-0} prompt_tail
  fm_pane_has_verified_busy_signature "$tail40" && return 1
  prompt_tail=$(fm_harness_prompt_tail "$tail40")
  case "$harness" in
    claude|claude:*|unknown)
      if printf '%s\n' "$tail40" | grep -Fq 'Do you want to proceed?' \
        && printf '%s\n' "$prompt_tail" | grep -Eq '1\. Yes' \
        && printf '%s\n' "$prompt_tail" | grep -Eq '3\. No' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Esc to cancel.*Tab to amend'; then
        printf 'command/tool permission'
        return 0
      fi
      if [ "$allow_directory_trust" = 1 ] \
        && printf '%s\n' "$tail40" | grep -Fq 'Quick safety check: Is this a project you created or one you trust?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, I trust this folder' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, exit' \
        && printf '%s\n' "$prompt_tail" | grep -Eq 'Enter to confirm.*Esc to cancel'; then
        printf 'directory trust'
        return 0
      fi
      ;;
  esac
  case "$harness" in
    codex|codex:*|unknown)
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to run the following command?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, proceed' \
        && printf '%s\n' "$prompt_tail" | grep -Eq "No, (continue without running it|and tell Codex what to do differently)" \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'command/tool permission'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to grant these permissions?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, grant these permissions for this turn' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, continue without permissions' \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'permission profile'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Fq 'Would you like to make the following edits?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, proceed' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, and tell Codex what to do differently' \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'file edit permission'
        return 0
      fi
      if printf '%s\n' "$tail40" | grep -Eq 'Do you want to approve network access to ".+"\?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, just this once' \
        && printf '%s\n' "$prompt_tail" | grep -Eq "No, (continue without running it|and tell Codex what to do differently|and block this host in the future)" \
        && printf '%s\n' "$prompt_tail" | grep -Fqi 'Press enter to confirm or esc to cancel'; then
        printf 'network access'
        return 0
      fi
      if [ "$allow_directory_trust" = 1 ] \
        && printf '%s\n' "$tail40" | grep -Fq 'Do you trust the contents of this directory?' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'Yes, continue' \
        && printf '%s\n' "$prompt_tail" | grep -Fq 'No, quit'; then
        printf 'directory trust'
        return 0
      fi
      ;;
  esac
  return 1
}

fm_startup_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_startup_accept_command() {  # <bin-dir> <firstmate-home> <task-id>
  printf 'FM_HOME=%s %s %s --key Enter' \
    "$(fm_startup_shell_quote "$2")" \
    "$(fm_startup_shell_quote "$1/fm-send.sh")" \
    "$(fm_startup_shell_quote "$3")"
}

fm_startup_peek_command() {  # <bin-dir> <firstmate-home> <task-id>
  printf 'FM_HOME=%s %s %s' \
    "$(fm_startup_shell_quote "$2")" \
    "$(fm_startup_shell_quote "$1/fm-peek.sh")" \
    "$(fm_startup_shell_quote "$3")"
}
