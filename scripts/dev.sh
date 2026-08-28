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
SIGNING_CONFIG_PATH="${SIGNING_CONFIG_PATH:-$ROOT_DIR/Config/Signing.local.xcconfig}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  build   Build the signed Debug app with automatic signing
  launch  Build and launch the canonical Debug app
  test    Build and run the project tests
  check   Validate the Xcode project and Debug scheme
  stop    Stop the running canonical app
  signing [TEAM_ID]
           Create the local Debug signing configuration with a Team ID
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

if [[ -f "$SIGNING_CONFIG_PATH" ]]; then
  xcodebuild_args+=( -xcconfig "$SIGNING_CONFIG_PATH" )
fi

build() {
  printf 'Building %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" -allowProvisioningUpdates build
}

run_tests() {
  printf 'Testing %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" -allowProvisioningUpdates test
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

signing() {
  local signing_config="$SIGNING_CONFIG_PATH"
  local requested_team_id="${1:-}"
  local team_id
  local identity_output
  local team_ids
  local team_id_count

  [[ "$#" -le 1 ]] || fail "Usage: $(basename "$0") signing [TEAM_ID]"

  [[ ! -e "$signing_config" ]] || fail "Signing configuration already exists: $signing_config"

  if [[ -n "$requested_team_id" ]]; then
    [[ "$requested_team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "TEAM_ID must be a 10-character uppercase alphanumeric Team ID"
    team_id="$requested_team_id"
  else
    require_command security
    identity_output="$({ security find-identity -v -p codesigning 2>/dev/null || true; })"
    team_ids="$(printf '%s\n' "$identity_output" \
      | awk -F'[()]' '/"(Mac|Apple) Development:/ {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$/) print $i
          }
        }' \
      | sort -u)"
    team_id_count="$(printf '%s\n' "$team_ids" | awk 'NF { count++ } END { print count + 0 }')"
    case "$team_id_count" in
      0)
        fail "No Apple Development or Mac Development identity with a Team ID is installed. Add a matching development certificate and private key to the current Xcode account/keychain, then retry. The script cannot create certificates."
        ;;
      1)
        team_id="$team_ids"
        ;;
      *)
        fail "Multiple Team IDs are present in Apple Development or Mac Development identities: $(printf '%s' "$team_ids" | tr '\n' ' '). Pass one explicitly: $(basename "$0") signing TEAM_ID"
        ;;
    esac
  fi

  mkdir -p "$(dirname "$signing_config")"
  if ! (set -C; printf 'DEVELOPMENT_TEAM = %s\n' "$team_id" > "$signing_config"); then
    fail "Could not create signing configuration: $signing_config"
  fi

  case "$signing_config" in
    "$ROOT_DIR"/*)
      if command -v git >/dev/null 2>&1 && ! git -C "$ROOT_DIR" check-ignore -q -- "$signing_config"; then
        printf 'Warning: Git does not ignore %s; remove it from tracking before committing.\n' "$signing_config" >&2
      fi
      ;;
    *)
      printf 'Warning: %s is outside the repository and is not covered by its .gitignore.\n' "$signing_config" >&2
      ;;
  esac
  printf 'Created local Debug signing configuration: %s\n' "$signing_config"
}

command="${1:-help}"
if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$command" == "signing" ]]; then
  signing "${@:2}"
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
