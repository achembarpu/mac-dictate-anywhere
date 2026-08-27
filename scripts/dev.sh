#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Dictate Anywhere.xcodeproj"
SCHEME="Dictate Anywhere"
CONFIGURATION="Debug"
APP_NAME="Dictate Anywhere Dev.app"
DEFAULT_DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DEFAULT_DERIVED_DATA_PATH}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  build   Build the signed Debug app
  launch  Build and launch the canonical Debug app
  test    Build and run the project tests
  check   Validate the Xcode project and Debug scheme
  stop    Stop the running canonical app
  help    Show this help

DerivedData: $DERIVED_DATA_PATH
Override with DERIVED_DATA_PATH, using a stable non-temporary path.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_derived_data_path() {
  case "$DERIVED_DATA_PATH" in
    ""|/*/../*|/*/..|/tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
      fail "DERIVED_DATA_PATH must be an absolute, stable, non-temporary path"
      ;;
    /*) ;;
    *) fail "DERIVED_DATA_PATH must be an absolute, stable, non-temporary path" ;;
  esac
}

xcodebuild_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
)

build() {
  printf 'Building %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" build
}

run_tests() {
  printf 'Testing %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" test
}

check() {
  printf 'Checking %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" -showBuildSettings >/dev/null
  printf 'Project and scheme are valid.\n'
}

launch() {
  build
  [[ -d "$APP_PATH" ]] || fail "Built app not found at: $APP_PATH"
  printf 'Launching %s\n' "$APP_PATH"
  open -n "$APP_PATH"
}

stop() {
  require_command pkill
  if pkill -x "Dictate Anywhere Dev"; then
    printf 'Stopped %s\n' "$APP_NAME"
  else
    printf '%s is not running\n' "$APP_NAME"
  fi
}

command="${1:-help}"
if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
  usage
  exit 0
fi

require_command xcodebuild
validate_derived_data_path

case "$command" in
  build) build ;;
  launch) launch ;;
  test) run_tests ;;
  check) check ;;
  stop) stop ;;
  *) usage >&2; fail "Unknown command: $command" ;;
esac
