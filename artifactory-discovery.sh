#!/bin/bash
# artifactory-discovery.sh
# Docker container içinde çalışacak Artifactory keşif aracı.

set -euo pipefail

# Container içinde mount noktaları
ENV_FILE="${ENV_FILE:-/app/config/artifactory-discovery.env}"

if [ ! -f "${ENV_FILE}" ]; then
  echo "❌ HATA: ${ENV_FILE} bulunamadı."
  echo ""
  echo "   Docker run komutunda env dosyasını mount etmelisiniz:"
  echo "   -v \$(pwd)/artifactory-discovery.env:/app/config/artifactory-discovery.env:ro"
  exit 1
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

OUTPUT_DIR="${OUTPUT_DIR:-/app/output}"
DAYS_BACK="${DAYS_BACK:-180}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

for var in ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TOKEN; do
  if [ -z "${!var:-}" ] || [[ "${!var}" == *"your-"* ]]; then
    echo "❌ HATA: ${var} dolu değil veya placeholder içeriyor."
    echo "   ${ENV_FILE} dosyasını düzenleyin."
    exit 1
  fi
done

mkdir -p "${OUTPUT_DIR}"

CUTOFF_DATE=$(date -u -d "${DAYS_BACK} days ago" +"%Y-%m-%dT%H:%M:%SZ")
CURL_OPTS=(-sf -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}")

echo "════════════════════════════════════════════════"
echo "   Artifactory Discovery Pipeline"
echo "════════════════════════════════════════════════"
echo "   URL          : ${ARTIFACTORY_URL}"
echo "   Cutoff date  : ${CUTOFF_DATE} (son ${DAYS_BACK} gün)"
echo "   Output dir   : ${OUTPUT_DIR}"
echo "════════════════════════════════════════════════"
echo ""

# ─── ADIM 1: Local Repolar ─────────────────────────────────────────────
echo "🔍 [1/4] Artifactory local repolarını listeliyor..."
curl "${CURL_OPTS[@]}" \
  "${ARTIFACTORY_URL}/api/repositories?type=local" \
  -o "${OUTPUT_DIR}/01-all-local-repos.json"

TOTAL_REPOS=$(jq 'length' "${OUTPUT_DIR}/01-all-local-repos.json")
echo "   ${TOTAL_REPOS} local repo bulundu"
echo ""
echo "   📊 Package type bazlı dağılım:"
jq -r 'group_by(.packageType) | .[] | "      \(.[0].packageType // "unknown"): \(length)"' \
  "${OUTPUT_DIR}/01-all-local-repos.json" | sort

# ─── ADIM 2: Artifact'leri AQL ile çek ─────────────────────────────────
echo ""
echo "🔍 [2/4] Son ${DAYS_BACK} gündeki artifact'leri çekiyor (AQL)..."

AQL_QUERY=$(cat <<EOF
items.find({
  "type": "file",
  "created": {"\$gt": "${CUTOFF_DATE}"},
  "repo": {"\$nmatch": "*-cache"}
}).include("repo","path","name","created","created_by","modified","property.*","stat.downloads")
.sort({"\$desc": ["created"]})
.limit(50000)
EOF
)

curl "${CURL_OPTS[@]}" \
  -X POST "${ARTIFACTORY_URL}/api/search/aql" \
  -H "Content-Type: text/plain" \
  -d "${AQL_QUERY}" \
  -o "${OUTPUT_DIR}/02-artifacts-raw.json"

TOTAL_ARTIFACTS=$(jq '.results | length' "${OUTPUT_DIR}/02-artifacts-raw.json")
echo "   ${TOTAL_ARTIFACTS} artifact bulundu"
echo ""
echo "   📊 Top 10 repo (artifact sayısı):"
jq -r '.results | group_by(.repo) | map({repo: .[0].repo, count: length}) | sort_by(-.count) | .[:10] | .[] | "      \(.count)\t\(.repo)"' \
  "${OUTPUT_DIR}/02-artifacts-raw.json"

{
  printf "repo\tpath\tname\tcreated\tcreated_by\tdownloads\tvcs_url\tvcs_revision\tbuild_name\tbuild_number\n"
  jq -r '
    .results[] |
    {
      repo, path, name, created, created_by,
      downloads: (.stats[0].downloads // 0),
      properties: (.properties // [] | map({(.key): .value}) | add // {})
    } |
    [
      .repo, .path, .name, .created, .created_by,
      (.downloads | tostring),
      (.properties["vcs.url"] // .properties["build.url"] // .properties["git.url"] // ""),
      (.properties["vcs.revision"] // .properties["git.commit"] // ""),
      (.properties["build.name"] // ""),
      (.properties["build.number"] // "")
    ] | @tsv
  ' "${OUTPUT_DIR}/02-artifacts-raw.json"
} > "${OUTPUT_DIR}/02-artifacts.tsv"

# ─── ADIM 3: Build-Info ────────────────────────────────────────────────
echo ""
echo "🔍 [3/4] Build-info'lardan VCS metadata'sı çekiliyor..."

curl "${CURL_OPTS[@]}" \
  "${ARTIFACTORY_URL}/api/build" \
  -o "${OUTPUT_DIR}/03-builds-list.json" 2>/dev/null || echo '{"builds":[]}' > "${OUTPUT_DIR}/03-builds-list.json"

BUILD_COUNT=$(jq '.builds // [] | length' "${OUTPUT_DIR}/03-builds-list.json" 2>/dev/null || echo 0)
echo "   ${BUILD_COUNT} build name bulundu"

mkdir -p "${OUTPUT_DIR}/builds"

fetch_build() {
  local build_name="$1"
  local safe_name
  safe_name=$(echo "${build_name}" | tr '/' '_' | tr ' ' '_')
  local out_file="${OUTPUT_DIR}/builds/${safe_name}.json"
  local latest
  latest=$(curl -sf -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
    "${ARTIFACTORY_URL}/api/build/${build_name}" 2>/dev/null | \
    jq -r '.buildsNumbers // [] | sort_by(.started) | last.uri // empty' 2>/dev/null | tr -d '/')
  [ -z "${latest}" ] && return
  curl -sf -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
    "${ARTIFACTORY_URL}/api/build/${build_name}/${latest}" \
    -o "${out_file}" 2>/dev/null || true
}
export -f fetch_build
export ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TOKEN OUTPUT_DIR

if [ "${BUILD_COUNT}" -gt 0 ]; then
  jq -r '.builds[]?.uri' "${OUTPUT_DIR}/03-builds-list.json" 2>/dev/null | tr -d '/' | \
    xargs -I {} -P "${PARALLEL_JOBS}" bash -c 'fetch_build "$@"' _ {} || true
fi

BUILD_FILES_COUNT=$(find "${OUTPUT_DIR}/builds" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "   ${BUILD_FILES_COUNT} build detayı çekildi"

if [ "${BUILD_FILES_COUNT}" -gt 0 ]; then
  for build_file in "${OUTPUT_DIR}"/builds/*.json; do
    [ -f "${build_file}" ] || continue
    jq -r '
      .buildInfo // {} |
      {
        build_name: (.name // ""),
        build_number: (.number // ""),
        started: (.started // ""),
        vcs_url: (.vcs[0].url // .vcsUrl // ""),
        vcs_revision: (.vcs[0].revision // .vcsRevision // ""),
        vcs_branch: (.vcs[0].branch // ""),
        ci_url: (.url // ""),
        agent_name: (.agent.name // ""),
        agent_version: (.agent.version // ""),
        build_agent_name: (.buildAgent.name // ""),
        modules: ([.modules[]?.id] // [])
      }
    ' "${build_file}" 2>/dev/null
  done | jq -s '.' > "${OUTPUT_DIR}/03-builds-vcs.json"
else
  echo "[]" > "${OUTPUT_DIR}/03-builds-vcs.json"
fi

VCS_COUNT=$(jq '[.[] | select(.vcs_url != "")] | length' "${OUTPUT_DIR}/03-builds-vcs.json")
echo "   ${VCS_COUNT} build için VCS URL'si bulundu"

# ─── ADIM 4: Excel Rapor ───────────────────────────────────────────────
echo ""
echo "🔍 [4/4] Excel rapor oluşturuluyor..."

python3 - "${OUTPUT_DIR}" <<'PYEOF'
import sys, json, re
from pathlib import Path
from collections import Counter
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

OUT = Path(sys.argv[1])

PACKAGE_TYPE_MAP = {
    "maven":    {"build_tool": "Maven/Gradle",   "lang": "Java/Kotlin"},
    "gradle":   {"build_tool": "Gradle",         "lang": "Java/Kotlin"},
    "nuget":    {"build_tool": "MSBuild/dotnet", "lang": ".NET"},
    "npm":      {"build_tool": "npm/yarn",       "lang": "Node.js"},
    "pypi":     {"build_tool": "pip/poetry",     "lang": "Python"},
    "docker":   {"build_tool": "Docker",         "lang": "Container"},
    "helm":     {"build_tool": "Helm",           "lang": "K8s Chart"},
    "go":       {"build_tool": "go modules",     "lang": "Go"},
    "generic":  {"build_tool": "Generic",        "lang": "Mixed"},
    "rpm":      {"build_tool": "rpmbuild",       "lang": "Linux pkg"},
    "debian":   {"build_tool": "dpkg",           "lang": "Linux pkg"},
    "conan":    {"build_tool": "Conan",          "lang": "C/C++"},
    "composer": {"build_tool": "Composer",       "lang": "PHP"},
    "gems":     {"build_tool": "Bundler",        "lang": "Ruby"},
    "cargo":    {"build_tool": "Cargo",          "lang": "Rust"},
}

def detect_ci_tool(agent_name, ci_url):
    a = (agent_name or "").lower(); u = (ci_url or "").lower()
    if "jenkins" in a or "jenkins" in u: return "Jenkins"
    if "gitlab" in a or "gitlab" in u: return "GitLab CI"
    if "bitbucket" in a or "bitbucket" in u: return "Bitbucket Pipelines"
    if "github" in a or "github" in u: return "GitHub Actions"
    if "azure" in a or "dev.azure" in u: return "Azure DevOps"
    if "teamcity" in a: return "TeamCity"
    return agent_name or "Unknown"

def normalize_repo_url(url):
    if not url: return ""
    url = url.strip().rstrip("/")
    m = re.match(r"^(?:ssh://)?git@([^:/]+)[:/](.+?)(?:\.git)?$", url)
    if m: return f"https://{m.group(1)}/{m.group(2)}"
    if url.endswith(".git"): url = url[:-4]
    return url

def detect_platform(url):
    u = (url or "").lower()
    if "bitbucket" in u: return "Bitbucket"
    if "gitlab" in u: return "GitLab"
    if "github" in u: return "GitHub"
    if "azure" in u or "visualstudio" in u: return "Azure Repos"
    return "Unknown"

repos_data = json.loads((OUT / "01-all-local-repos.json").read_text()) if (OUT / "01-all-local-repos.json").exists() else []
artifacts_df = pd.read_csv(OUT / "02-artifacts.tsv", sep="\t", dtype=str).fillna("") if (OUT / "02-artifacts.tsv").exists() else pd.DataFrame()
builds_data = json.loads((OUT / "03-builds-vcs.json").read_text()) if (OUT / "03-builds-vcs.json").exists() else []

print(f"   Repolar: {len(repos_data)}, Artifact'ler: {len(artifacts_df)}, Build kayıtları: {len(builds_data)}")

repo_pkg = {r["key"]: (r.get("packageType") or "").lower() for r in repos_data}

service_rows = []; seen = set()
for _, r in artifacts_df.iterrows():
    vcs = normalize_repo_url(r["vcs_url"])
    repo_key = r["repo"]
    pkg = repo_pkg.get(repo_key, "unknown")
    info = PACKAGE_TYPE_MAP.get(pkg, {"build_tool": "?", "lang": "?"})
    key = (vcs, repo_key)
    if vcs and key in seen: continue
    seen.add(key)
    service_rows.append({
        "vcs_url": vcs, "platform": detect_platform(vcs),
        "language": info["lang"], "build_tool": info["build_tool"],
        "artifact_type": pkg, "ci_tool": "",
        "build_name": r["build_name"], "build_number": r["build_number"],
        "artifactory_repo": repo_key, "last_publish": r["created"],
        "downloads": r["downloads"], "source": "artifact-property",
    })

for b in builds_data:
    vcs = normalize_repo_url(b.get("vcs_url", ""))
    if not vcs: continue
    ci = detect_ci_tool(b.get("agent_name", ""), b.get("ci_url", ""))
    bt = b.get("build_agent_name", "")
    matched = False
    for row in service_rows:
        if row["vcs_url"] == vcs:
            if not row["ci_tool"]: row["ci_tool"] = ci
            matched = True
    if matched: continue
    service_rows.append({
        "vcs_url": vcs, "platform": detect_platform(vcs),
        "language": "?", "build_tool": bt or "?",
        "artifact_type": "?", "ci_tool": ci,
        "build_name": b.get("build_name", ""), "build_number": b.get("build_number", ""),
        "artifactory_repo": "", "last_publish": b.get("started", ""),
        "downloads": "0", "source": "build-info",
    })

services_df = pd.DataFrame(service_rows)

if not artifacts_df.empty:
    repo_summary = (artifacts_df.groupby("repo").agg(
        artifact_count=("name", "count"),
        unique_paths=("path", "nunique"),
        total_downloads=("downloads", lambda x: pd.to_numeric(x, errors="coerce").fillna(0).sum()),
        last_publish=("created", "max")).reset_index())
    repo_summary["package_type"] = repo_summary["repo"].map(repo_pkg).fillna("unknown")
    repo_summary = repo_summary.sort_values("artifact_count", ascending=False)
else:
    repo_summary = pd.DataFrame()

tech_counter = Counter(row["language"] for row in service_rows)
tech_df = pd.DataFrame([{"language": k, "service_count": v} for k, v in tech_counter.most_common()])

suggestions = []
for pt in sorted(set(repo_pkg.values()) - {"", "unknown"}):
    info = PACKAGE_TYPE_MAP.get(pt, {})
    suggestions.append({
        "package_type": pt, "language": info.get("lang", "?"),
        "release_repo": f"{pt}-release-local",
        "snapshot_repo": f"{pt}-snapshot-local" if pt in ("maven", "gradle") else "(N/A)",
        "remote_repo": f"{pt}-remote", "virtual_repo": f"{pt}-virtual",
        "notes": "Snapshot only for Maven/Gradle" if pt in ("maven", "gradle") else "",
    })
suggestions_df = pd.DataFrame(suggestions)

all_keys = set(repo_pkg.keys())
active_keys = set(artifacts_df["repo"].unique()) if not artifacts_df.empty else set()
inactive_df = pd.DataFrame([
    {"repo_key": k, "package_type": repo_pkg.get(k, ""), "status": "no recent publishes"}
    for k in sorted(all_keys - active_keys)])

out_file = OUT / "artifactory-discovery-report.xlsx"
wb = Workbook()
wb.remove(wb.active)

def write_df(name, df):
    ws = wb.create_sheet(name)
    if df.empty:
        ws["A1"] = "(boş)"; return
    header_font = Font(bold=True, color="FFFFFF", name="Arial")
    header_fill = PatternFill("solid", start_color="1F4E78")
    border = Border(
        left=Side(style="thin", color="CCCCCC"),
        right=Side(style="thin", color="CCCCCC"),
        top=Side(style="thin", color="CCCCCC"),
        bottom=Side(style="thin", color="CCCCCC"))
    for ci, cn in enumerate(df.columns, 1):
        c = ws.cell(row=1, column=ci, value=cn)
        c.font = header_font; c.fill = header_fill
        c.alignment = Alignment(horizontal="center", vertical="center")
        c.border = border
    for ri, row in enumerate(df.itertuples(index=False), 2):
        for ci, val in enumerate(row, 1):
            c = ws.cell(row=ri, column=ci, value=val)
            c.font = Font(name="Arial", size=10); c.border = border
            c.alignment = Alignment(vertical="center")
    for ci, cn in enumerate(df.columns, 1):
        max_len = max([len(str(cn))] + [len(str(v)) for v in df.iloc[:, ci-1].astype(str).tolist()[:200]])
        ws.column_dimensions[get_column_letter(ci)].width = min(max_len + 2, 60)
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions

write_df("1. Publish Eden Servisler", services_df)
write_df("2. Artifactory Repo Özeti", repo_summary)
write_df("3. Teknoloji Dağılımı", tech_df)
write_df("4. Yeni Repo Önerileri", suggestions_df)
write_df("5. Aktif Olmayan Repolar", inactive_df)
wb.save(out_file)

print(f"   ✅ Excel: {out_file}")
print(f"      - {len(services_df)} servis kaydı")
print(f"      - {len(repo_summary)} aktif repo")
print(f"      - {len(tech_df)} farklı teknoloji")
print(f"      - {len(suggestions_df)} repo önerisi")
print(f"      - {len(inactive_df)} aktif olmayan repo")
PYEOF

echo ""
echo "════════════════════════════════════════════════"
echo "✅ TAMAMLANDI"
echo "════════════════════════════════════════════════"
echo "   📁 Çıktı: ${OUTPUT_DIR}/artifactory-discovery-report.xlsx"
echo "════════════════════════════════════════════════"
