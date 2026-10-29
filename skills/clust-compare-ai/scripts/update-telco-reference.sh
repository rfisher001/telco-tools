#!/usr/bin/env bash
# Refresh oc cluster-compare reference configurations from Red Hat telco RDS images.
# Usage: ./update-telco-core-reference.sh [--apply] [--yes] [--out DIR] [--profile PROFILE] VERSION [VERSION ...]
# Example: ./update-telco-core-reference.sh 4.21
#          ./update-telco-core-reference.sh --apply 4.20 4.21
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
OUT_DIR="out"
PROFILE="core"
APPLY=0
ASSUME_YES=0
VERSIONS=()

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options] VERSION [VERSION ...]

Refresh telco RDS cluster-compare reference files for one or more OpenShift versions.

Options:
  --apply       Install downloaded reference files (default is preview/dry-run).
  --yes, -y     Do not prompt when used with --apply.
  --out DIR     Output root directory (default: ./out).
  --profile, -p PROFILE
                Reference profile: core, hub, or ran (default: core).
                Hub RDS images are published beginning with OCP 4.19.
  -h, --help    Show this help.

Examples:
  $SCRIPT_NAME 4.21
  $SCRIPT_NAME --profile hub --apply 4.21
  $SCRIPT_NAME -p ran --apply --yes --out ./out 4.20 4.21

Output layout (uniform across profiles):
  Core: DIR/core/VERSION/reference-crs-kube-compare/metadata.yaml
  Hub:  DIR/hub/VERSION/reference-crs-kube-compare/metadata.yaml
  RAN:  DIR/ran/VERSION/reference-crs-kube-compare/metadata.yaml

Requires: podman, tar, base64, diff, and (for applying) cp/mv.
Registry access may require: podman login registry.redhat.io
USAGE
}

while (($#)); do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --out)
      [[ $# -ge 2 ]] || { echo "ERROR: --out requires a directory" >&2; exit 2; }
      OUT_DIR=$2; shift 2 ;;
    --profile|-p)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires core, hub, or ran" >&2; exit 2; }
      PROFILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while (($#)); do VERSIONS+=("$1"); shift; done ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) VERSIONS+=("$1"); shift ;;
  esac
done

if ((${#VERSIONS[@]} == 0)); then
  echo "ERROR: specify at least one OpenShift version (for example, 4.21)." >&2
  usage >&2
  exit 2
fi

case "$PROFILE" in
  core)
    IMAGE_REPOSITORY="registry.redhat.io/openshift4/openshift-telco-core-rds-rhel9"
    IMAGE_CONTENT_ROOT="telco-core-rds"
    PROFILE_OUT_DIR="$OUT_DIR/core"
    ;;
  ran)
    IMAGE_REPOSITORY="registry.redhat.io/openshift4/openshift-telco-core-rds-rhel9"
    IMAGE_CONTENT_ROOT="telco-core-rds"
    PROFILE_OUT_DIR="$OUT_DIR/ran"
    ;;
  hub)
    IMAGE_REPOSITORY="registry.redhat.io/openshift4/openshift-telco-hub-rds-rhel9"
    IMAGE_CONTENT_ROOT="telco-hub-rds"
    PROFILE_OUT_DIR="$OUT_DIR/hub"
    ;;
  *)
    echo "ERROR: invalid profile '$PROFILE'; expected core, hub, or ran." >&2
    exit 2
    ;;
esac

command -v podman >/dev/null || { echo "ERROR: podman is required." >&2; exit 1; }
command -v tar >/dev/null || { echo "ERROR: tar is required." >&2; exit 1; }
command -v base64 >/dev/null || { echo "ERROR: base64 is required." >&2; exit 1; }

# macOS ships BSD base64 (-D); Linux commonly uses GNU base64 (-d).
if base64 --help 2>&1 | grep -q -- '--decode'; then
  BASE64_DECODE=(base64 --decode)
else
  BASE64_DECODE=(base64 -D)
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/telco-${PROFILE}-reference.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for version in "${VERSIONS[@]}"; do
  if [[ ! "$version" =~ ^4\.[0-9]+$ ]]; then
    echo "ERROR: invalid version '$version'; expected format like 4.21." >&2
    exit 2
  fi
  if [[ "$PROFILE" == "hub" ]] && (( ${version#4.} < 19 )); then
    echo "ERROR: no telco hub RDS image is published for OpenShift $version." >&2
    echo "Hub RDS images begin at 4.19; a version-matched hub reference is unavailable for $version." >&2
    exit 2
  fi
  image="$IMAGE_REPOSITORY:v${version}"
  version_work="$WORK_DIR/$version"
  extracted="$version_work/extracted"
  staged="$version_work/reference-crs-kube-compare"
  target="$PROFILE_OUT_DIR/$version/reference-crs-kube-compare"
  mkdir -p "$extracted"

  echo
  echo "== OpenShift $version =="
  echo "Image:  $image"
  echo "Target: $target"
  echo "Pulling image..."
  podman pull "$image"

  echo "Extracting reference configuration..."
  # The image emits a base64-encoded tar archive; do not allocate a TTY.
  podman run --rm "$image" | "${BASE64_DECODE[@]}" | tar -xf - -C "$extracted"

  source_dir="$extracted/$IMAGE_CONTENT_ROOT/configuration/reference-crs-kube-compare"
  if [[ ! -f "$source_dir/metadata.yaml" ]]; then
    echo "ERROR: expected metadata.yaml not found in image $image." >&2
    echo "The image contents or layout may have changed; existing files were not touched." >&2
    exit 1
  fi
  cp -R "$source_dir" "$staged"

  if [[ -d "$target" ]]; then
    echo "Changes (existing reference -> downloaded reference):"
    # diff returns 1 when differences are found; that is not a script failure.
    set +e
    diff -ru "$target" "$staged"
    diff_status=$?
    set -e
    if ((diff_status > 1)); then
      echo "ERROR: diff failed for $target" >&2
      exit "$diff_status"
    elif ((diff_status == 0)); then
      echo "No file differences found."
    else
      echo "Differences found (diff exit status $diff_status)."
    fi
  else
    echo "No existing reference directory; this will create a new one."
  fi

  if ((APPLY == 0)); then
    echo "DRY RUN: no files changed. Re-run with --apply to install this version."
    continue
  fi

  if ((ASSUME_YES == 0)); then
    read -r -p "Install the downloaded reference for $version? [y/N] " answer
    case "$answer" in [yY]|[yY][eE][sS]) ;; *) echo "Skipped $version."; continue ;; esac
  fi

  mkdir -p "$(dirname "$target")"
  if [[ -d "$target" ]]; then
    backup_root="$PROFILE_OUT_DIR/.backups"
    timestamp=$(date '+%Y%m%d-%H%M%S')
    backup="$backup_root/$PROFILE-$version-$timestamp"
    mkdir -p "$backup_root"
    echo "Backing up current reference to $backup"
    mv "$target" "$backup"
  fi
  # staged is on the same filesystem only sometimes; mv still safely handles cross-filesystem moves.
  mv "$staged" "$target"
  echo "Updated: $target"
done

echo
echo "Finished."
