#!/usr/bin/env bash
# fm-launch-pinned.sh - start a crewmate's launch command with a project's proven
# runtime pin ahead of PATH, WITHOUT that pin ever reaching the PATH that
# resolved the command.
#
# Usage:
#   fm-launch-pinned.sh <path-prepend> [NAME=VALUE ...] <command> [arg ...]
#
# WHY THIS EXISTS
#   Worktree provisioning can prove a project's runtime and hand back the
#   directory that must lead PATH for the project's own tools. Putting that
#   directory on the PATH the pane shell uses to evaluate firstmate's typed
#   launch line would let a manifest decide which binary EVERY bare word in that
#   line means: the harness name, a wrapper, that wrapper's target, an
#   interpreter carrying a continuation prompt. Those were found and pinned one
#   word at a time across five review rounds, which is a search that does not
#   converge - the next launch shape adds the next word.
#
#   This closes it as a class instead. The crewmate PATH firstmate exports
#   carries no manifest-supplied entry, so the whole launch line resolves from
#   firstmate's own resolution order whatever words it happens to contain, and
#   the pin is applied HERE, after the command has been resolved, to the
#   environment the agent and every one of its children inherit. Moving WHERE the
#   pin applies is the point: the project's own tools still resolve it first.
#
# CONTRACT
#   - <path-prepend> is a colon-joined list of directories, already validated by
#     fm-provision.sh (each exists and carries no space, quote, or colon).
#   - Leading NAME=VALUE arguments are the launch line's own environment prefix.
#     They are consumed here rather than by the pane shell so that a launch line
#     can be handed over whole, and they are applied to the command only.
#   - The command word is resolved with `type -P`, a PATH-only lookup, against
#     the PATH this process INHERITED - the un-pinned crewmate PATH. A shell
#     function or alias of the same name cannot answer for it, and neither can
#     the pin, which is not exported until after the lookup.
#   - A command word that already carries a slash is not PATH-resolved at all.
#   - An unresolvable command exits 127 with a reason, the same way a shell
#     reports a command it cannot find, rather than launching something else.
set -u

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

die() {
  printf 'fm-launch-pinned: %s\n' "$*" >&2
  exit 2
}

[ "$#" -ge 2 ] || die "usage: fm-launch-pinned.sh <path-prepend> [NAME=VALUE ...] <command> [arg ...]"

PREPEND=$1
shift
[ -n "$PREPEND" ] || die "the path prefix to apply is empty"

ASSIGNMENTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    [A-Za-z_]*=*)
      ASSIGNMENTS[${#ASSIGNMENTS[@]}]=$1
      shift
      ;;
    *) break ;;
  esac
done

[ "$#" -gt 0 ] || die "no command to run after the environment prefix"

TARGET=$1
shift

case "$TARGET" in
  */*) RESOLVED=$TARGET ;;
  *) RESOLVED=$(type -P -- "$TARGET" 2>/dev/null) || RESOLVED= ;;
esac

if [ -z "$RESOLVED" ] || [ ! -x "$RESOLVED" ]; then
  printf 'fm-launch-pinned: %s\n' \
    "'$TARGET' is not an executable on this PATH, so there is nothing to launch" >&2
  exit 127
fi

# Only now, with the command already resolved, does the manifest's directory
# reach PATH. Everything below inherits it; nothing above it ever saw it.
PATH="$PREPEND:$PATH"
export PATH

exec /usr/bin/env ${ASSIGNMENTS[@]+"${ASSIGNMENTS[@]}"} "$RESOLVED" "$@"
