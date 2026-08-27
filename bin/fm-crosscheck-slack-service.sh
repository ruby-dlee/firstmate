#!/usr/bin/env bash
# Install and operate the central macOS Crosscheck Slack listener.
#
# Usage: fm-crosscheck-slack-service.sh install|start|stop|restart|status|uninstall
#
# The launch agent stores only executable paths, FM_HOME, and the config path.
# Slack and GitHub credentials stay in the environment or the macOS Keychain
# services named by config/crosscheck-slack.json.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CROSSCHECK_SLACK_CONFIG:-$FM_HOME/config/crosscheck-slack.json}"
LABEL=com.firstmate.crosscheck-slack
DOMAIN="gui/$(id -u)"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
LOG_DIR="$FM_HOME/logs"
STDOUT_LOG="$LOG_DIR/crosscheck-slack.log"
STDERR_LOG="$LOG_DIR/crosscheck-slack.error.log"
WRAPPER="$FM_ROOT/bin/fm-crosscheck-slack.sh"

usage() {
  echo "usage: $0 install|start|stop|restart|status|uninstall" >&2
  exit 2
}

write_plist() {
  mkdir -p "$AGENT_DIR" "$LOG_DIR"
  temporary=$(mktemp "$AGENT_DIR/.$LABEL.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  plutil -create xml1 "$temporary"
  plutil -insert Label -string "$LABEL" "$temporary"
  plutil -insert ProgramArguments -array "$temporary"
  plutil -insert ProgramArguments.0 -string "$WRAPPER" "$temporary"
  plutil -insert ProgramArguments.1 -string run "$temporary"
  plutil -insert ProgramArguments.2 -string --config "$temporary"
  plutil -insert ProgramArguments.3 -string "$CONFIG" "$temporary"
  plutil -insert EnvironmentVariables -dictionary "$temporary"
  plutil -insert EnvironmentVariables.FM_HOME -string "$FM_HOME" "$temporary"
  plutil -insert EnvironmentVariables.FM_CROSSCHECK_SLACK_CONFIG \
    -string "$CONFIG" "$temporary"
  plutil -insert RunAtLoad -bool true "$temporary"
  plutil -insert KeepAlive -bool true "$temporary"
  plutil -insert ThrottleInterval -integer 10 "$temporary"
  plutil -insert StandardOutPath -string "$STDOUT_LOG" "$temporary"
  plutil -insert StandardErrorPath -string "$STDERR_LOG" "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$PLIST"
  trap - EXIT
}

loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

stop_service() {
  if loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
  fi
}

case "${1:-}" in
  install)
    [ -x "$WRAPPER" ] || {
      echo "error: Crosscheck Slack wrapper is not executable at $WRAPPER" >&2
      exit 1
    }
    "$WRAPPER" --selftest "$CONFIG"
    write_plist
    echo "installed: $PLIST"
    echo "listener remains stopped until '$0 start' passes credential preflight"
    ;;
  start)
    [ -f "$PLIST" ] || {
      echo "error: service is not installed at $PLIST" >&2
      exit 1
    }
    "$WRAPPER" preflight --config "$CONFIG"
    stop_service
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl enable "$DOMAIN/$LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "started: $LABEL"
    ;;
  stop)
    stop_service
    echo "stopped: $LABEL"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    if loaded; then
      launchctl print "$DOMAIN/$LABEL"
    else
      echo "stopped: $LABEL"
      exit 3
    fi
    ;;
  uninstall)
    stop_service
    if [ -f "$PLIST" ]; then
      rm "$PLIST"
    fi
    echo "uninstalled: $LABEL (logs and durable review state retained)"
    ;;
  *) usage ;;
esac
