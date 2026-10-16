#!/usr/bin/env bash
#
# rds-must-gather.sh — produce a must-gather that actually contains every operator CR,
# shaped for `kubectl cluster-compare` (telco RDS references). OCP 4.18 - 4.21.
#
# Why this exists: the stock `oc adm must-gather` collects only a FIXED list of resource
# types per namespace (core, apps, batch, route, monitoring, operators.coreos.com, ...).
# Custom resources from installed operators — StorageCluster, CephCluster, PerformanceProfile,
# SriovNetworkNodePolicy, NMState, IPAddressPool, NUMAResourcesOperator, Tuned ... — are NOT
# collected, so cluster-compare reports them as "missing" even though they exist.
#
# This runs the stock gather and then additionally inspects EVERY CRD-backed type on the
# cluster (discovered at runtime, so no need to know which operators are installed).
#
# Subcommands:
#   print   Print a single self-contained command to hand to whoever has cluster access
#   run     Run it here against the current kubeconfig context
#   local   Client-side only: no must-gather pod, uses `oc adm inspect` directly
#   show-script  Print the in-pod gather script in plain text (for review)
#
set -euo pipefail

IMAGE=""
TIMEOUT="30m"
DEST=""
CHUNK=20
EXTRA_EXCLUDE=""
SUBCMD="${1:-print}"
[[ $# -gt 0 ]] && shift || true

# Types that are CRDs but are pure noise or huge; never worth collecting for a comparison.
#   apirequestcounts  - one object per API resource (hundreds), rotated hourly stats
#   packagemanifests  - the whole catalog contents, thousands of objects
DEFAULT_EXCLUDE='^(apirequestcounts\.apiserver\.openshift\.io|packagemanifests\.packages\.operators\.coreos\.com)$'

usage() {
  cat <<'USAGE'
rds-must-gather.sh — must-gather with all operator CRs, for cluster-compare (OCP 4.18-4.21)

  ./rds-must-gather.sh print [options]    # emit the command to send to the cluster owner
  ./rds-must-gather.sh run   [options]    # run it here (needs cluster-admin kubeconfig)
  ./rds-must-gather.sh local [options]    # no pod: client-side `oc adm inspect` only
  ./rds-must-gather.sh show-script        # the gather script the command base64-encodes

Options:
  --image REF        must-gather image (default: the cluster's own payload image)
  --timeout DUR      must-gather timeout (default: 30m — the stock 10m is too short)
  --dest-dir DIR     output directory (default: ./must-gather.local.<rand>)
  --chunk N          resource types per inspect call (default: 20)
  --exclude REGEX    extra egrep pattern of <plural>.<group> types to skip
  -h, --help         this text

The gathered tree is normal must-gather layout, so it feeds straight into:
  ./mg-compare.sh -p core <archive>
USAGE
}

# accept both --opt value and --opt=value
ARGS=()
for a in "$@"; do
  case "$a" in
    --image=*|--timeout=*|--dest-dir=*|--chunk=*|--exclude=*)
      ARGS+=("${a%%=*}" "${a#*=}") ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}

while (( $# )); do
  case "$1" in
    --image)    IMAGE="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --dest-dir) DEST="$2"; shift 2 ;;
    --chunk)    CHUNK="$2"; shift 2 ;;
    --exclude)  EXTRA_EXCLUDE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

EXCLUDE_RE="$DEFAULT_EXCLUDE"
[[ -z "$EXTRA_EXCLUDE" ]] || EXCLUDE_RE="${DEFAULT_EXCLUDE%\$)*}|${EXTRA_EXCLUDE})$"

# ---------------------------------------------------------------------------
# The in-pod gather script.
#
# MUST NOT CONTAIN SINGLE QUOTES — it is embedded in `-- bash -c '...'` so the
# whole thing can be pasted as one command. The generator checks this below.
# ---------------------------------------------------------------------------
read -r -d '' GATHER_SCRIPT <<GATHER || true
set -u
BASE=\${BASE:-/must-gather}
CHUNK=$CHUNK
EXCLUDE_RE="$EXCLUDE_RE"
mkdir -p \$BASE
LOG=\$BASE/gather-all-crs.log
say() { echo "[all-crs] \$*" | tee -a \$LOG; }
TMP=\$(mktemp -d 2>/dev/null || echo \$BASE/.tmp); mkdir -p \$TMP

say "start: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. stock OCP gather (core cluster data: nodes, clusteroperators, all namespaces, logs)
if [ -x /usr/bin/gather ]; then
  say "running stock /usr/bin/gather"
  /usr/bin/gather
  say "stock gather finished (rc=\$?)"
else
  say "no /usr/bin/gather here - client-side mode, collecting built-ins too"
fi

# 2. discover every CRD-backed type on the cluster (no need to know the operators)
oc get crd --no-headers -o custom-columns=P:.spec.names.plural,G:.spec.group,S:.spec.scope > \$TMP/crd.txt 2>>\$LOG
: > \$TMP/all.raw
while read -r plural group scope; do
  [ -z "\$plural" ] && continue
  echo \$plural.\$group >> \$TMP/all.raw
done < \$TMP/crd.txt

# serviceaccounts are referenced by the RDS refs but are not in the stock per-namespace set
echo serviceaccounts >> \$TMP/all.raw
if [ ! -x /usr/bin/gather ]; then
  # client-side mode: no stock gather, so pick up the built-ins it would have collected
  # NB: not "namespaces" - inspecting a Namespace object pulls the whole namespace,
  # pod logs included. The Namespace objects themselves are written directly below.
  for b in nodes persistentvolumes persistentvolumeclaims configmaps secrets \\
           storageclasses.storage.k8s.io clusterrolebindings.rbac.authorization.k8s.io; do
    echo \$b >> \$TMP/all.raw
  done
fi
# clusteroperators: the stock gather already inspects them, and inspect follows a
# ClusterOperator to its related objects - pod logs included - which is the single most
# expensive part of any gather. Never do it twice, and skip it entirely client-side.
EXCLUDE_RE="\$EXCLUDE_RE|^clusteroperators\.config\.openshift\.io\$"
sort -u \$TMP/all.raw | grep -Ev "\$EXCLUDE_RE" > \$TMP/types.list || true
say "CRDs on cluster: \$(wc -l < \$TMP/crd.txt), resource types to inspect: \$(wc -l < \$TMP/types.list)"

# 3. inspect them.
# Types must be passed COMMA-separated: space-separated args are parsed as object NAMES.
# A nonzero exit is normal (inspect follows related objects and reports missing ones), so
# the real signals are the "Wrote inspect data" line and the unknown-type error.
run_inspect() {
  out=\$(oc adm inspect --dest-dir=\$BASE -A \$1 2>&1)
  echo "\$out" >> \$LOG
  case \$out in
    *"have a resource type"*) return 2 ;;   # a type in this batch is not served
  esac
  case \$out in
    *"Wrote inspect data"*) return 0 ;;
  esac
  return 1
}

types=()
while read -r t; do [ -n "\$t" ] && types+=(\$t); done < \$TMP/types.list
total=\${#types[@]}
i=0; bad=0
while [ \$i -lt \$total ]; do
  chunk=(\${types[@]:\$i:\$CHUNK})
  batch=\$(IFS=,; echo "\${chunk[*]}")
  if ! run_inspect \$batch; then
    # one unservable type fails the whole batch and writes nothing - retry individually
    for t in \${chunk[@]}; do
      run_inspect \$t || { say "  unavailable: \$t"; bad=\$((bad+1)); }
    done
  fi
  i=\$((i+CHUNK))
  [ \$i -gt \$total ] && i=\$total
  say "inspected \$i/\$total types"
done
say "resource inspection done (\$bad types unavailable)"

# 3b. client-side mode: write the Namespace objects where the stock gather puts them
if [ ! -x /usr/bin/gather ]; then
  say "writing namespace objects"
  for n in \$(oc get namespaces -o custom-columns=N:.metadata.name --no-headers); do
    mkdir -p \$BASE/namespaces/\$n
    oc get namespace \$n -o yaml > \$BASE/namespaces/\$n/\$n.yaml 2>>\$LOG
  done
fi

# 4. plain-text inventory so the analyst knows what was installed
{
  echo "# collected \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## clusterversion"
  oc get clusterversion -o custom-columns=NAME:.metadata.name,VERSION:.status.desired.version,CHANNEL:.spec.channel --no-headers
  echo
  echo "## clusterserviceversions"
  oc get clusterserviceversions.operators.coreos.com -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase
  echo
  echo "## subscriptions"
  oc get subscriptions.operators.coreos.com -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CHANNEL:.spec.channel,SOURCE:.spec.source
  echo
  echo "## catalogsources"
  oc get catalogsources.operators.coreos.com -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DISPLAY:.spec.displayName
  echo
  echo "## crds (plural group scope)"
  cat \$TMP/crd.txt
} > \$BASE/operator-inventory.txt 2>>\$LOG

rm -rf \$TMP
say "done: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GATHER

# `oc adm must-gather -- bash -c <script>` runs the command through an extra expansion
# inside the pod: every $var in a plain script is substituted away before bash ever sees
# it (verified - a script that sets X and echoes $X prints an empty value). Passing the
# script base64-encoded is the only form that survives, so there is nothing left to quote.
B64="$(printf '%s\n' "$GATHER_SCRIPT" | base64 | tr -d '\n')"
# Decode to a file and run THAT: piping the script straight into bash loses the tail of
# it, because /usr/bin/gather consumes the same stdin the script is being read from.
# Keep this string free of $ and backticks - the pod wrapper expands it once more.
# The single quotes below must reach `oc` LITERALLY: oc joins everything after `--` into
# one string that the pod re-parses, so an unquoted payload gets split at the first pipe
# (`bash -c echo <b64>` then an empty file, which is why a plain payload silently no-ops).
PAYLOAD="echo $B64 | base64 -d > /tmp/rds-gather.sh; bash /tmp/rds-gather.sh"

TAR_SRC="must-gather.local.*"
[[ -z "$DEST" ]] || TAR_SRC="$DEST"
MG_ARGS="--timeout=$TIMEOUT"
[[ -z "$IMAGE" ]] || MG_ARGS="$MG_ARGS --image=$IMAGE"
[[ -z "$DEST"  ]] || MG_ARGS="$MG_ARGS --dest-dir=$DEST"

case "$SUBCMD" in
  print)
    cat <<EOF
# Run as cluster-admin on the target cluster (OCP 4.18-4.21), then send the tarball.
#
# Collects the normal must-gather PLUS every custom resource of every installed operator
# (discovered from the cluster's CRDs, so nothing needs to be listed up front).
# Read-only. Secret values are redacted by oc adm inspect ("<n> bytes long").
#
# The payload is base64 only because oc adm must-gather mangles \$variables in a plain
# inline script. To read exactly what will run:
#     echo <the base64 string below> | base64 -d
# or ask for the source: ./rds-must-gather.sh show-script

mkdir -p ~/rds-must-gather && cd ~/rds-must-gather

oc adm must-gather $MG_ARGS -- bash -c "'$PAYLOAD'"

tar -caf rds-must-gather-\$(date +%Y%m%d).tar.gz $TAR_SRC
EOF
    ;;
  show-script)
    printf '%s\n' "$GATHER_SCRIPT"
    ;;
  run)
    command -v oc >/dev/null || { echo "oc not found" >&2; exit 1; }
    oc whoami >/dev/null || { echo "not logged in" >&2; exit 1; }
    echo "==> oc adm must-gather $MG_ARGS -- bash -c <all-crs gather, base64>"
    # shellcheck disable=SC2086
    oc adm must-gather $MG_ARGS -- bash -c "'$PAYLOAD'"
    ;;
  local)
    command -v oc >/dev/null || { echo "oc not found" >&2; exit 1; }
    BASE="${DEST:-$PWD/inspect.local.$RANDOM}"
    echo "==> client-side gather into $BASE (no must-gather pod; no node/pod-log data)"
    BASE="$BASE" bash -c "$GATHER_SCRIPT"
    ;;
  -h|--help|help) usage ;;
  *) echo "unknown subcommand: $SUBCMD" >&2; usage >&2; exit 1 ;;
esac
