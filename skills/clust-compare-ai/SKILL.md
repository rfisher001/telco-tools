---
name: clust-compare-ai
description: "Run a telco RDS cluster-compare on an OpenShift must-gather — extract the archive, compare it against the version- and profile-matched telco reference, and produce txt/json/html deviation reports via rds-analyzer. Includes a correlation audit that stops cluster-compare silently dropping CRs whose names differ from the reference. Trigger when asked to cluster-compare, RDS-compare, kube-compare, or analyze deviations for a must-gather."
---

# clust-compare-ai

End-to-end workflow: OpenShift must-gather archive → `cluster-compare` against the telco RDS
reference → `rds-analyzer` deviation report (txt / json / html).

Everything runs **on the machine this skill is invoked from**. No remote host is assumed. If the
must-gather lives on another box, copy it over first (or run the skill there).

> **The most valuable part of this skill is Step 5b.** `cluster-compare` correlates CRs to
> reference templates by *exact name*, and in must-gather mode it **silently discards** anything
> it cannot correlate. Skipping that step routinely produces reports where 30–40% of the
> "Missing CRs" are tooling artifacts and real deviations are invisible. Do not skip it.

---

## Step 0 — Prerequisites

Check what is already present before installing anything:

```bash
for t in oc kubectl podman omc rds-analyzer; do
  printf '%-16s %s\n' "$t" "$(command -v $t || echo MISSING)"
done
oc cluster-compare --help >/dev/null 2>&1 && echo "cluster-compare   OK (oc builtin)" \
  || command -v kubectl-cluster_compare >/dev/null && echo "cluster-compare   OK (plugin)" \
  || echo "cluster-compare   MISSING"
```

| Tool | Required? | Where it comes from |
|---|---|---|
| **cluster-compare** | yes | Ships inside recent `oc` as `oc cluster-compare`. Standalone plugin: `github.com/openshift/kube-compare` (installs as `kubectl-cluster_compare`). |
| **rds-analyzer** | yes | `github.com/openshift-kni/rds-analyzer` |
| **rules files** | yes | `core-rules.yaml`, `hub-rules.yaml`, `ran-du-rules.yaml` — Red Hat internal: `gitlab.cee.redhat.com/rds-analyzer/rules` |
| **podman** | to fetch references | Needed by `scripts/update-telco-reference.sh`; also `podman login registry.redhat.io` |
| **omc** | optional, handy | `github.com/gmeghnag/omc` — browse a must-gather with `oc`-like commands |
| **py7zr** | only for `.7z` | `pip install --user py7zr` |

This skill is written against **cluster-compare v4.21.0** and **rds-analyzer v0.3**. Behaviour
noted below — particularly the correlation rules — was verified on those versions.

### Set your paths once

Every command below uses these. Adjust and export them at the start of a session:

```bash
export CC_WORK="$HOME/must-gather"          # where archives are extracted
export CC_REF="$HOME/telco-references"      # reference root (see Step 0b)
export CC_RULES="$HOME/rds-rules"           # clone of the rules repo
mkdir -p "$CC_WORK" "$CC_REF"
```

If `oc cluster-compare` is available, use it; otherwise substitute `kubectl-cluster_compare`.
Pick one and stay consistent:

```bash
export CC="oc cluster-compare"              # or: export CC="kubectl-cluster_compare"
```

### Step 0b — Fetch the reference configurations

`scripts/update-telco-reference.sh` (bundled with this skill) pulls the published Red Hat telco
RDS images and extracts the `reference-crs-kube-compare` tree. It defaults to a dry run that
diffs against what you already have:

```bash
podman login registry.redhat.io          # once

./scripts/update-telco-reference.sh --profile hub  --out "$CC_REF" 4.20   # preview
./scripts/update-telco-reference.sh --profile hub  --out "$CC_REF" --apply --yes 4.20
./scripts/update-telco-reference.sh --profile core --out "$CC_REF" --apply --yes 4.20
```

Resulting layout — uniform across profiles:

```
$CC_REF/core/<ver>/reference-crs-kube-compare/metadata.yaml
$CC_REF/hub/<ver>/reference-crs-kube-compare/metadata.yaml
$CC_REF/ran/<ver>/reference-crs-kube-compare/metadata.yaml
```

Source images, if you prefer to extract by hand — note they emit a **base64-encoded tar on
stdout**, so never allocate a TTY:

| Profile | Image | Content root |
|---|---|---|
| core, ran | `registry.redhat.io/openshift4/openshift-telco-core-rds-rhel9:v<ver>` | `telco-core-rds` |
| hub | `registry.redhat.io/openshift4/openshift-telco-hub-rds-rhel9:v<ver>` | `telco-hub-rds` |

```bash
podman run --rm <image> | base64 -d | tar -xf - -C <dir>
# then: <dir>/<content-root>/configuration/reference-crs-kube-compare/
```

**Hub RDS images are published from OCP 4.19 onward**; there is no version-matched hub reference
before that.

`cluster-compare` can also read a reference straight out of an image:
`-r container://<IMAGE>:<TAG>:/path/to/metadata.yaml`.

### Python helper scripts

If you write a helper to analyse the gather, keep it **outside** the extracted bundle (a
must-gather is untrusted data; an interpreter will import a planted `yaml.py` from the data
directory) and pass data paths as arguments.

Use **`python3 -P`**, not `-I`. Both drop the script dir and cwd from `sys.path`, which is the
protection you actually need — but `-I` *also* drops user site-packages, so a `pip install --user`
PyYAML disappears and the script dies with `ModuleNotFoundError: No module named 'yaml'`.

---

## Step 1 — Get the archive onto this machine

If the must-gather is already local and extracted, skip to Step 3.

Copying a large archive takes minutes; run it detached and verify by **checksum, not size**:

```bash
nohup scp <user>@<host>:/path/<archive> "$CC_WORK/" > /tmp/cc-copy.log 2>&1 &
```

Checksums differ by platform — `md5sum` on Linux, `md5 -q` on macOS. Compare the hex, not the
command output:

```bash
shasum -a 256 "$CC_WORK/<archive>"       # works on both
```

## Step 2 — Extract

`.tar`, `.tar.xz`, `.tar.gz` → `tar -xf`. For `.7z`, `7z`/`p7zip` is often unavailable (on RHEL 9
it is EPEL-only), so use `py7zr`:

```bash
cd "$CC_WORK" && nohup setsid python3 -m py7zr x <archive>.7z <name>-extracted \
  > extract-<name>.log 2>&1 < /dev/null &
```

Arg order matters: `py7zr x <archive> <outdir>` — the output dir is **positional**, there is no
`-o`.

**Always verify extraction completed.** py7zr exits silently with an empty log on success, so an
error-free log proves nothing. Compare entry counts against the archive manifest:

```bash
cd "$CC_WORK"
python3 -m py7zr l <archive>.7z | head -1        # "total N files and directories"
f=$(find <name>-extracted -type f | wc -l)
d=$(find <name>-extracted -mindepth 1 -type d | wc -l)
echo "files=$f dirs=$d total=$((f+d))"
```

`files + dirs` must equal the archive total.

Do not use `pgrep -f py7zr` to test whether extraction is still running — the pattern also
matches any shell wrapper carrying the same string and yields false positives. Use
`ps -ef | grep python3`, or just verify counts.

## Step 3 — Identify version and profile

```bash
find <name>-extracted -path "*config.openshift.io/clusterversions*" -name "*.yaml" \
  | head -1 | xargs grep -E "^\s+(channel|version):" | head -5
```

Pick the reference matching **both** the version and the profile:

- **core cluster** → `$CC_REF/core/<ver>/reference-crs-kube-compare/metadata.yaml`
- **hub cluster** → `$CC_REF/hub/<ver>/reference-crs-kube-compare/metadata.yaml`
- **RAN DU cluster** → `$CC_REF/ran/<ver>/reference-crs-kube-compare/metadata.yaml`

Picking wrong produces a superficially plausible but meaningless report. **If the profile is not
stated, confirm with the user before running.**

A **hub** is easy to recognise: ACM / MCE / TALM / GitOps subscriptions, and `local-cluster` plus
`open-cluster-management*` namespaces. Its reference parts are `required-{acm,gitops,talm,registry}`
and `optional-{logging,lso,odf-internal}`.

> If you inherited a reference tree laid out some other way, check what you have before trusting a
> path: a directory named for the version alone has in the past held the **RAN DU** reference (its
> part descriptions link to `ran/telco-ran-ref-du-components`) rather than core.

> The hub reference ships **no `comparison-overrides.yaml`** — omit `-p` for hub runs. Only the
> core reference has one.

## Step 4 — Validate the gather is actually usable

A bundle contains one gather dir per `--image`. The core OCP one is
`quay-io-openshift-release-dev-*`; a hub bundle commonly adds ACM, MCE, ODF, LSO, GitOps,
cluster-logging, OADP and site-specific images. List them first — they matter for scoping (5a):

```bash
ls <name>-extracted/*/must-gather.local.*/
```

**Confirm the core OCP dir has real content:**

```bash
ls <name>-extracted/*/quay-io-openshift-release-dev-*/
```

It must contain `cluster-scoped-resources/` and `namespaces/`. If it contains only `gather.logs`,
the core data never made it into the archive and **no meaningful comparison is possible** — the
reference will report ~90% of CRs "missing" as a pure collection artifact. Check `gather.logs`: if
it shows "Gathering data for ns/…" and "Wrote inspect data to must-gather", collection succeeded
and the archive was built from an incomplete directory. Report that and ask for a re-collected
must-gather rather than shipping a misleading report.

### Shallow-collected namespaces

Even a healthy gather collects some namespaces only partially. A **fully** collected namespace has
its own Namespace object at `namespaces/<ns>/<ns>.yaml`; a **shallow** one has a few API-group
subdirs and no Namespace object. Count them up front — it pre-explains a batch of false
"Missing CRs":

```bash
B=<core-gather-dir>
for d in "$B"/namespaces/*/; do ns=$(basename "$d")
  [ -f "$d/$ns.yaml" ] || echo "shallow: $ns"
done
```

On one production hub, 26 of 105 namespaces were shallow — including `openshift-logging`,
`openshift-local-storage` and `openshift-operators`. That alone made `lsoNS.yaml` and
`clusterLogNS.yaml` report as missing when both namespaces plainly existed. **Never report a
missing `*NS.yaml` without checking this first.**

Conversely, if a namespace has **no directory at all** while ~100 others do, the namespace really
does not exist on the cluster — a genuine finding, not a gap.

## Step 5 — Run cluster-compare

```bash
cd "$CC_WORK/<name>-extracted"
REF="$CC_REF/core/<ver>/reference-crs-kube-compare"
SCOPE="must-gather.local.*/quay-io-openshift-release-dev-*/cluster-scoped-resources,must-gather.local.*/quay-io-openshift-release-dev-*/namespaces"

$CC -r "$REF/metadata.yaml" -p "$REF/comparison-overrides.yaml" -f "$SCOPE" -R \
  > "$CC_WORK/cc-<name>-<ver>.txt"
$CC -r "$REF/metadata.yaml" -p "$REF/comparison-overrides.yaml" -f "$SCOPE" -R -o json \
  > "$CC_WORK/cc-<name>-<ver>.json"
```

- Pass `-p <ref>/comparison-overrides.yaml` **for core runs** — it ships with the reference and
  nulls `ClusterVersion.status` for the version check. Benign and intended. The hub reference has
  no such file; omit the flag there.
- **Exit code 1 means "differences found" and is the normal outcome.** Only `>1` is a real error.
  Check stderr, not the exit code.
- Run txt and json as separate invocations; there is no way to emit both at once.

### Step 5a — Scope `-f` across every usable gather dir

The core gather does **not** contain operator-owned CRs such as `MultiClusterHub`,
`MultiClusterEngine`, `AgentServiceConfig`, `StorageCluster`, `LocalVolumeSet` or Argo
`AppProject`. Those live in their own gather dirs. Scoping to the core gather alone reports all of
them as "Missing CRs" — pure scope artifacts.

Build the scope from every gather dir present, `cluster-scoped-resources` + `namespaces` for each:

```bash
cd "$CC_WORK/<name>-extracted/.../"          # dir holding must-gather.local.*
G="must-gather.local.*"; SCOPE=""
for g in $(ls -d $G/*/ | xargs -n1 basename); do
  SCOPE="$SCOPE$G/$g/cluster-scoped-resources,$G/$g/namespaces,"
done
SCOPE=${SCOPE%,}; echo "$SCOPE" > /tmp/cc-scope.txt
```

Only add `cluster-scoped-resources` and `namespaces` — never a whole gather dir. That keeps
`oc_output/`, `ceph/`, `cache-dir/` and other non-CR payloads out.

Non-resource JSON/YAML inside a gather produces a **skip warning**, not a fatal error:

```
W… Skipping ".../openshift-storage/oc_output/external_cluster_details.json": … 'Kind' is missing.
```

That is safe to ignore — include the ODF gather, it is the only source of `StorageCluster`. (Older
cluster-compare builds aborted outright on that file; if yours does, drop just that one gather
dir.)

On one hub this step alone took Missing CRs from 35 → 30.

### Step 5b — Audit name correlation (do this on every run)

**This is the single biggest source of false findings.** `cluster-compare` correlates a cluster CR
to a template on the exact 4-tuple `apiVersion_kind_namespace_name`. There is **no fallback** to
group+kind+namespace. Any name difference produces a *double* false positive:

1. the template is listed under **Missing CRs**, and
2. the real CR is **silently discarded** — in must-gather (local) mode uncorrelated CRs are only
   listed when you pass `-A`. Without it they never appear, and the report ends with the
   reassuring lie `No CRs are unmatched to reference CRs`.

So a user reporting *"the CRs are there but cluster-compare doesn't see them"* is almost always
hitting this.

**Diagnose with `-A`.** Re-run adding `-A`, then grep the unmatched list for the kinds the
reference expects:

```bash
$CC -r "$REF/metadata.yaml" -f "$SCOPE" -R -A > /tmp/cc-A.txt
awk '/Cluster CRs unmatched/,0' /tmp/cc-A.txt | grep -E "_(Subscription|OperatorGroup|CatalogSource)_"
```

`-A` is a diagnostic only — it dumps thousands of CRs. **Do not ship a report generated with it.**

**Then audit each Missing CR.** For every template reported missing, read its
`apiVersion/kind/namespace/name` and ask whether the same kind exists in the same namespace under
a different name:

```bash
awk '/Missing CRs:/,0' <report>.txt | grep -oE '^    - (required|optional)/[^ ]+\.yaml' \
  | sed 's/^    - //' | sort -u > /tmp/cc-missing.txt
```

Classify each into **NAME_MISMATCH** (fixable here), **OUT_OF_SCOPE** (fix in 5a), **COLLECTION**
(shallow namespace / kind never collected), or **ABSENT** (real finding).

#### Recurring name-mismatch classes

These all appeared on a single hub cluster and are worth checking by default:

| Class | Reference name | Real cluster name | How to confirm |
|---|---|---|---|
| **Subscription** | `open-cluster-management-subscription` | `advanced-cluster-management` | `spec.name` (the package) matches the reference |
| **Subscription** | `openshift-topology-aware-lifecycle-manager-subscription` | `topology-aware-lifecycle-manager` | same |
| **OperatorGroup** | `<component>-group` | `<namespace>-xxxxx` | OLM auto-names OGs created by console/OLM rather than GitOps; exactly one OG per namespace ⇒ unambiguous |
| **CatalogSource** | `redhat-operators-disconnected` | `cs-redhat-operator-index-v4-NN-<site>` | oc-mirror v2 naming |
| **ConfigMap** (registry CA) | `registry-ca` in `openshift-config` | e.g. `custom-ca` | `Image/cluster.spec.additionalTrustedCA.name` points at it |
| **ImageDigestMirrorSet** | `idms-release-0` | e.g. `image-digest-mirror` | its `spec` mirrors `quay.io/openshift-release-dev/{ocp-release,ocp-v4.0-art-dev}` |
| **ConfigMap** (assisted mirror) | `mirror-registry-config` in `multicluster-engine` | e.g. `assisted-installer-mirror-config` | `AgentServiceConfig.spec.mirrorRegistryRef.name` points at it; same `app: assisted-service` label and `ca-bundle.crt` / `registries.conf` data keys |

Note the pattern in the last three: **the cluster tells you the real name.** Follow the reference
from the CR that *consumes* the object rather than guessing from the name.

#### Write the user config

```yaml
# cc-user-config-<name>.yaml
correlationSettings:
  manualCorrelation:
    correlationPairs:
      operators.coreos.com/v1alpha1_Subscription_open-cluster-management_advanced-cluster-management: "required/acm/acmSubscription.yaml"
      operators.coreos.com/v1alpha1_Subscription_openshift-operators_topology-aware-lifecycle-manager: "required/talm/talmSubscription.yaml"
      operators.coreos.com/v1_OperatorGroup_open-cluster-management_open-cluster-management-v9ctf: "required/acm/acmOperGroup.yaml"
      operators.coreos.com/v1alpha1_CatalogSource_openshift-marketplace_cs-redhat-operator-index-v4-20-hub: "required/registry/catalog-source.yaml"
      operators.coreos.com/v1alpha1_CatalogSource_openshift-marketplace_cs-redhat-operator-index-v4-20-bastion: "required/registry/catalog-source.yaml"
      v1_ConfigMap_openshift-config_custom-ca: "required/registry/registry-ca.yaml"
      config.openshift.io/v1_ImageDigestMirrorSet_image-digest-mirror: "required/registry/idms-release.yaml"
      v1_ConfigMap_multicluster-engine_assisted-installer-mirror-config: "required/acm/acmMirrorRegistryCM.yaml"
```

Pass it with `-c <path>/cc-user-config-<name>.yaml`. Cluster-scoped resources use the 3-part form
`apiVersion_kind_name`. **Multiple CRs may map to the same template** — that is how you cover two
Red Hat catalogs.

Comment every pair with the evidence that justifies it. The config is the audit trail for why a
"missing" CR was reclassified.

A complete, fully annotated worked example — all 11 pairs from a hub 4.20 run — is in
`examples/cc-user-config-hub-4.20.yaml` next to this file. Start from it for any hub cluster; the
OperatorGroup suffixes and catalog/CA names are site-specific and must be re-derived, but the
classes and the justifying evidence carry over.

**Be conservative — only map objects that are unambiguously the same thing under a different
name.** Do not force-correlate a structural difference; that hides a real finding:

- Argo `AppProject` named `draproject` is **not** the reference's `infra`. Different GitOps
  structure → report it.
- LSO `LocalVolumeSet` is **not** `LocalVolume`. Different *kind* → correlation cannot bridge it
  and shouldn't; it is a genuine architectural deviation.
- The logging `collector` ServiceAccount is created *by* a `ClusterLogForwarder`. No CLF ⇒ no SA.
  Report the cause, don't map the symptom.

A good outcome: on one hub, 11 pairs plus the wider scope moved Missing CRs 43 → 27, correlated
CRs 16 → 33, and unmatched to 0 — and exposed a TALM Subscription on channel `"4.20"` instead of
`stable` that the straight run had hidden completely.

#### CatalogSource specifics (expect this on every disconnected cluster)

The template name is `redhat-operators-disconnected` — `required/other/catalog-source.yaml` in the
core reference, `required/registry/catalog-source.yaml` in the hub one. Left uncorrelated it also
produces a spurious `C001-catalog-source` "No CatalogSource configured" from rds-analyzer, on a
cluster with perfectly working catalogs.

```bash
ls <gather>/namespaces/openshift-marketplace/operators.coreos.com/catalogsources/
```

Map only the **Red Hat** index catalogs. Do **not** map `cs-community-operator-index-*` — it is
not a Red Hat catalog and the reference template does not describe it. Mapping correctly clears
C001 and converts the catalogs into real diffs that usually reveal empty `displayName` /
`publisher` vs the reference.

Mapping *all* the Red Hat catalogs can legitimately trip a count rule — on one hub,
`HUB-C-002-catalogsource` ("at most one CatalogSource") fired for a hub + bastion pair. That
violation was real (the cluster had four CatalogSources); the correlation merely made it visible.
Report it as a finding, and say that it surfaced because of the mapping.

#### Verify the mapping was right

A correct pair produces a **tiny diff** — just the name line:

```
-  name: idms-release-0
+  name: image-digest-mirror
```

A large unexpected diff means you mapped the wrong object. Back it out.

## Step 6 — Generate the deviation report

```bash
rds-analyzer -i "$CC_WORK/cc-<name>-<ver>.json" \
  -r "$CC_RULES/core-rules.yaml" -t <ver> -o html \
  > "$CC_WORK/cc-<name>-<ver>.html"
```

- Omit `-o html` for the terminal text view; `-m reporting` gives an LLM-oriented split into
  "must be addressed" / "required guidance". `-o json` is also available.
- Use the rules file matching the profile: `core-rules.yaml`, `hub-rules.yaml`, `ran-du-rules.yaml`.
  **Never analyze a core cluster with the RAN DU rules** — RAN-specific rules mis-classify core
  config, and unmatched deviations collapse into `NeedsReview` (default_impact), badly
  understating the report.
- `-t <ver>` selects the OCP version whose impacts to apply; without it the analyzer uses the
  highest version present in the rules file. Historically these rules keyed impacts only under the
  newest release, so older `-t` values produced identical output — pass it anyway for clarity, and
  check the rules file if the target matters.
- `rds-analyzer -r <rules> --validate-rules-only` checks a rules file's regexes without any input.

## Step 7 — Deliver

The HTML is self-contained; hand back its path. If the user is remote, copy it to them and verify
by checksum on both ends.

Hand back the `cc-user-config-<name>.yaml` alongside the HTML — it is reusable for the next
must-gather from the same cluster, and it documents every reclassification.

## Interpreting results — known artifacts

Always separate genuine deviations from collection and tooling artifacts before reporting. Every
"Missing CR" falls into one of four buckets — classify all of them before writing anything:

| Bucket | Meaning | Fix |
|---|---|---|
| **NAME_MISMATCH** | same kind + namespace, different `metadata.name` | manual correlation (5b) |
| **OUT_OF_SCOPE** | CR exists, but in a gather dir not passed to `-f` | widen scope (5a) |
| **COLLECTION** | namespace shallow-collected, or kind never collected anywhere | discount it, say so |
| **ABSENT** | genuinely not on the cluster | real finding |

- **Missing CRs impact split is trustworthy.** It derives from the reference's own
  required/optional designation, not from the rules file.
- **`No CRs are unmatched to reference CRs` is not reassurance.** In local mode that line is
  printed whenever `-A` is absent, however many CRs failed to correlate. Never cite it as evidence
  that everything matched.
- **Aggregated `List` files hide CRs from naive greps.** Much of
  `cluster-scoped-resources/<group>/<plural>.yaml` is a single `…List` object whose `kind:` key can
  sit megabytes after the `items:`. `grep '^kind: ImageDigestMirrorSet$'` finds nothing while three
  of them exist. cluster-compare handles these correctly; *your* helper scripts must expand
  `items:` and must not parse only the first few KB of a file.
- **ODF `StorageCluster` is routinely absent from the *core* gather** even on clusters plainly
  running ODF. Check the ODF gather dir first (5a) — that is usually where it is. Only if
  `grep -rl "^kind: StorageCluster" <name>-extracted/` finds nothing bundle-wide while
  `ocs-external-storagecluster-*` storageclasses exist is it a real collection gap.
- **`LocalVolumeSet` vs `LocalVolume`.** The reference's `lsoLocalVolume.yaml` expects kind
  `LocalVolume`. A cluster using dynamic disk discovery has `localvolumesets/` instead. Different
  kind, so correlation cannot bridge it — report it as a genuine architectural deviation rather
  than a tooling artifact.
- **MCH component toggles are worth reading.** On one hub the `MultiClusterHub` diff showed
  `siteconfig` and `cluster-backup` disabled where the reference enables them — significant on a
  ZTP hub and easy to skim past in a long diff.
- **`startingCSV` on Subscriptions is benign noise.** OLM writes it; the reference never sets it.
  Channel differences in the same diff are the real signal.
- **`Namespace/openshift-nmstate` Impacting is legitimate** — core rules flag
  `openshift.io/cluster-monitoring: "true"` and `workload.openshift.io/allowed: management` as not
  RDS-aligned.
- **MetalLB `IPAddressPool` diffs are expected noise.** Site-specific addressing always differs
  from the reference; they typically dominate the diff count on core clusters.
- A **rules-file bug** worth re-checking in any fresh clone: `C001-catalog-source` and
  `R001-catalogsource` once matched `templateFileName: "DefaultCatsrc.yaml"` (a RAN DU template
  name) instead of `catalog-source.yaml`, so both silently never matched on core clusters. Verify
  against your rules checkout and upstream a fix if it is still present.

## Reporting to the user

State the reference and rules file used, the version detected, the impact summary, and — most
importantly — call out which findings are artifacts rather than real deviations. A raw
"N Impacting" headline is misleading on its own. If any part of the bundle was unusable, say
exactly what was excluded and why.

Also report the **before/after** of the correlation work: baseline Missing CRs vs corrected, and
which real deviations only became visible once correlation was fixed. That is usually the most
valuable part of the analysis, and it shows the headline number was earned rather than copied out
of the tool.
