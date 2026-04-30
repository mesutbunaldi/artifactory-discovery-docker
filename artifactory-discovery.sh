#!/bin/bash
# artifactory-discovery.sh v2
# Generic repolardaki artifact'leri de teknoloji tespitiyle keşfeder.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/app/config/artifactory-discovery.env}"

if [ ! -f "${ENV_FILE}" ]; then
  echo "❌ HATA: ${ENV_FILE} bulunamadı."
  exit 1
fi

source "${ENV_FILE}"

OUTPUT_DIR="${OUTPUT_DIR:-/app/output}"
DAYS_BACK="${DAYS_BACK:-180}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# Generic repolardaki belirsiz artifact'lerin içine bakılsın mı?
DEEP_INSPECT="${DEEP_INSPECT:-false}"
DEEP_INSPECT_LIMIT="${DEEP_INSPECT_LIMIT:-50}"

for var in ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TOKEN; do
  if [ -z "${!var:-}" ] || [[ "${!var}" == *"your-"* ]]; then
    echo "❌ HATA: ${var} dolu değil."
    exit 1
  fi
done

mkdir -p "${OUTPUT_DIR}"
CUTOFF_DATE=$(date -u -d "${DAYS_BACK} days ago" +"%Y-%m-%dT%H:%M:%SZ")
CURL_OPTS=(-sf -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}")

echo "════════════════════════════════════════════════"
echo "   Artifactory Discovery Pipeline v2"
echo "════════════════════════════════════════════════"
echo "   URL          : ${ARTIFACTORY_URL}"
echo "   Cutoff date  : ${CUTOFF_DATE} (son ${DAYS_BACK} gün)"
echo "   Output dir   : ${OUTPUT_DIR}"
echo "   Deep inspect : ${DEEP_INSPECT} (generic repolar için)"
echo "════════════════════════════════════════════════"
echo ""

# ─── ADIM 1: Local Repolar ─────────────────────────────────────────────
echo "🔍 [1/4] Local repolar listeleniyor..."
curl "${CURL_OPTS[@]}" \
  "${ARTIFACTORY_URL}/api/repositories?type=local" \
  -o "${OUTPUT_DIR}/01-all-local-repos.json"

TOTAL_REPOS=$(jq 'length' "${OUTPUT_DIR}/01-all-local-repos.json")
GENERIC_REPOS=$(jq '[.[] | select((.packageType // "" | ascii_downcase) == "generic")] | length' "${OUTPUT_DIR}/01-all-local-repos.json")
echo "   ${TOTAL_REPOS} local repo (${GENERIC_REPOS} tanesi GENERIC tipinde)"
echo ""
jq -r 'group_by(.packageType) | .[] | "      \(.[0].packageType // "unknown"): \(length)"' \
  "${OUTPUT_DIR}/01-all-local-repos.json" | sort

# ─── ADIM 2: Artifact'ler ──────────────────────────────────────────────
echo ""
echo "🔍 [2/4] Son ${DAYS_BACK} gündeki artifact'leri çekiyor..."

AQL_QUERY=$(cat <<EOF
items.find({
  "type": "file",
  "created": {"\$gt": "${CUTOFF_DATE}"},
  "repo": {"\$nmatch": "*-cache"}
}).include("repo","path","name","created","created_by","modified","property.*","stat.downloads","actual_md5")
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
echo "🔍 [3/4] Build-info çekiliyor..."

curl "${CURL_OPTS[@]}" \
  "${ARTIFACTORY_URL}/api/build" \
  -o "${OUTPUT_DIR}/03-builds-list.json" 2>/dev/null || echo '{"builds":[]}' > "${OUTPUT_DIR}/03-builds-list.json"

BUILD_COUNT=$(jq '.builds // [] | length' "${OUTPUT_DIR}/03-builds-list.json" 2>/dev/null || echo 0)
echo "   ${BUILD_COUNT} build name bulundu"

mkdir -p "${OUTPUT_DIR}/builds"

fetch_build() {
  local build_name="$1"
  local safe_name; safe_name=$(echo "${build_name}" | tr '/' '_' | tr ' ' '_')
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
echo "   ${BUILD_FILES_COUNT} build detayı"

if [ "${BUILD_FILES_COUNT}" -gt 0 ]; then
  for build_file in "${OUTPUT_DIR}"/builds/*.json; do
    [ -f "${build_file}" ] || continue
    jq -r '
      .buildInfo // {} |
      {
        build_name: (.name // ""), build_number: (.number // ""),
        started: (.started // ""), vcs_url: (.vcs[0].url // .vcsUrl // ""),
        vcs_revision: (.vcs[0].revision // .vcsRevision // ""),
        vcs_branch: (.vcs[0].branch // ""), ci_url: (.url // ""),
        agent_name: (.agent.name // ""), agent_version: (.agent.version // ""),
        build_agent_name: (.buildAgent.name // ""),
        modules: ([.modules[]?.id] // [])
      }' "${build_file}" 2>/dev/null
  done | jq -s '.' > "${OUTPUT_DIR}/03-builds-vcs.json"
else
  echo "[]" > "${OUTPUT_DIR}/03-builds-vcs.json"
fi

# ─── ADIM 4: Excel + Generic Detection ─────────────────────────────────
echo ""
echo "🔍 [4/4] Generic repolar dahil teknoloji tespiti + Excel..."

python3 - "${OUTPUT_DIR}" "${ARTIFACTORY_URL}" "${ARTIFACTORY_USER}" "${ARTIFACTORY_TOKEN}" "${DEEP_INSPECT}" "${DEEP_INSPECT_LIMIT}" <<'PYEOF'
import sys, json, re, base64, urllib.request, zipfile, io, tarfile
from pathlib import Path
from collections import Counter
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

OUT = Path(sys.argv[1])
ART_URL = sys.argv[2]; ART_USER = sys.argv[3]; ART_TOKEN = sys.argv[4]
DEEP_INSPECT = sys.argv[5].lower() == "true"
DEEP_INSPECT_LIMIT = int(sys.argv[6])

PACKAGE_TYPE_MAP = {
    "maven": ("Java/Kotlin", "Maven/Gradle"),
    "gradle": ("Java/Kotlin", "Gradle"),
    "nuget": (".NET", "MSBuild/dotnet"),
    "npm": ("Node.js", "npm/yarn"),
    "pypi": ("Python", "pip/poetry"),
    "docker": ("Container", "Docker"),
    "helm": ("K8s Chart", "Helm"),
    "go": ("Go", "go modules"),
    "rpm": ("Linux pkg", "rpmbuild"),
    "debian": ("Linux pkg", "dpkg"),
    "conan": ("C/C++", "Conan"),
    "composer": ("PHP", "Composer"),
    "gems": ("Ruby", "Bundler"),
    "cargo": ("Rust", "Cargo"),
}

EXTENSION_RULES = [
    (".jar", "Java/Kotlin", "Maven/Gradle", "high"),
    (".war", "Java/Kotlin", "Maven/Gradle", "high"),
    (".ear", "Java/Kotlin", "Maven/Gradle", "high"),
    (".pom", "Java/Kotlin", "Maven", "high"),
    (".aar", "Android", "Gradle", "high"),
    (".nupkg", ".NET", "MSBuild/dotnet", "high"),
    (".snupkg", ".NET", "MSBuild/dotnet", "high"),
    (".whl", "Python", "pip/poetry", "high"),
    (".egg", "Python", "setuptools", "high"),
    (".gem", "Ruby", "Bundler", "high"),
    (".phar", "PHP", "Composer", "high"),
    (".crate", "Rust", "Cargo", "high"),
    (".rpm", "Linux pkg", "rpmbuild", "high"),
    (".deb", "Linux pkg", "dpkg", "high"),
    (".dll", ".NET binary", "?", "medium"),
    (".so", "Native lib", "?", "medium"),
]

PATH_RULES = [
    (r"/charts?/.+\.tgz$", "K8s Chart", "Helm", "high"),
    (r"-py\d+-none-any\.whl$", "Python", "pip", "high"),
    (r"manifest\.json$", "Container", "Docker", "medium"),
    (r"^[a-z0-9._-]+/[a-z0-9._-]+/\d+\.", "Java/Kotlin", "Maven layout", "medium"),
]

def detect_tech(repo_pkg, path, name):
    repo_pkg = (repo_pkg or "").lower()
    if repo_pkg and repo_pkg != "generic" and repo_pkg in PACKAGE_TYPE_MAP:
        lang, tool = PACKAGE_TYPE_MAP[repo_pkg]
        return (lang, tool, "high", "package-type")
    
    full = f"{path}/{name}".lower()
    name_lower = name.lower()
    
    for pat, lang, tool, conf in PATH_RULES:
        if re.search(pat, full, re.IGNORECASE):
            return (lang, tool, conf, "path-pattern")
    
    if name_lower.endswith(".tar.gz") or name_lower.endswith(".tgz"):
        if "chart" in full or "/helm/" in full:
            return ("K8s Chart", "Helm", "high", "filename+path")
        if "/-/" in full or name_lower.startswith("@"):
            return ("Node.js", "npm", "high", "filename+path")
        return ("Unknown archive", "?", "low", "filename")
    
    for ext, lang, tool, conf in EXTENSION_RULES:
        if name_lower.endswith(ext):
            return (lang, tool, conf, "extension")
    
    return ("Unknown", "?", "none", "no-match")


def deep_inspect_artifact(repo, path, name):
    name_lower = name.lower()
    if not (name_lower.endswith(".zip") or name_lower.endswith(".tar.gz") or 
            name_lower.endswith(".tgz") or name_lower.endswith(".jar")):
        return None
    url = f"{ART_URL}/{repo}/{path}/{name}".replace(" ", "%20")
    auth = base64.b64encode(f"{ART_USER}:{ART_TOKEN}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}", "Range": "bytes=0-1048576"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = resp.read()
        if name_lower.endswith(".zip") or name_lower.endswith(".jar"):
            try:
                with zipfile.ZipFile(io.BytesIO(data)) as z:
                    names = z.namelist()
                    if "META-INF/MANIFEST.MF" in names:
                        return ("Java/Kotlin", "Maven/Gradle", "high", "content-jar")
                    if any(n.endswith(".nuspec") for n in names):
                        return (".NET", "NuGet", "high", "content-nuspec")
                    if "package.json" in names:
                        return ("Node.js", "npm", "high", "content-package.json")
                    if any(n.endswith("Chart.yaml") for n in names):
                        return ("K8s Chart", "Helm", "high", "content-chart")
            except zipfile.BadZipFile:
                pass
        if name_lower.endswith(".tar.gz") or name_lower.endswith(".tgz"):
            try:
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
                    names = t.getnames()
                    if any(n.endswith("Chart.yaml") for n in names):
                        return ("K8s Chart", "Helm", "high", "content-chart")
                    if any("package.json" in n for n in names):
                        return ("Node.js", "npm", "high", "content-npm")
                    if any(n.endswith("PKG-INFO") or n.endswith("setup.py") for n in names):
                        return ("Python", "setuptools", "high", "content-python")
            except (tarfile.TarError, EOFError):
                pass
    except Exception:
        return None
    return None


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

# ─── Yükle ─────────────────────────────────────────────────────────────
repos_data = json.loads((OUT / "01-all-local-repos.json").read_text()) if (OUT / "01-all-local-repos.json").exists() else []
artifacts_df = pd.read_csv(OUT / "02-artifacts.tsv", sep="\t", dtype=str).fillna("") if (OUT / "02-artifacts.tsv").exists() else pd.DataFrame()
builds_data = json.loads((OUT / "03-builds-vcs.json").read_text()) if (OUT / "03-builds-vcs.json").exists() else []

print(f"   Repolar: {len(repos_data)}, Artifact'ler: {len(artifacts_df)}, Build kayıtları: {len(builds_data)}")
repo_pkg = {r["key"]: (r.get("packageType") or "").lower() for r in repos_data}

# ─── Teknoloji tespiti ─────────────────────────────────────────────────
print("   🔬 Her artifact için teknoloji tespiti...")

deep_done = 0
detection_stats = Counter()
artifact_tech = []

for _, r in artifacts_df.iterrows():
    pkg = repo_pkg.get(r["repo"], "unknown")
    lang, tool, conf, source = detect_tech(pkg, r["path"], r["name"])
    if (DEEP_INSPECT and pkg == "generic" and conf in ("low", "none") 
        and deep_done < DEEP_INSPECT_LIMIT):
        result = deep_inspect_artifact(r["repo"], r["path"], r["name"])
        if result:
            lang, tool, conf, source = result
        deep_done += 1
    detection_stats[source] += 1
    artifact_tech.append({"language": lang, "build_tool": tool,
                          "confidence": conf, "detection_source": source})

print(f"   📊 Tespit kaynakları:")
for src, cnt in detection_stats.most_common():
    print(f"      {src}: {cnt}")
if DEEP_INSPECT:
    print(f"   🔍 {deep_done} artifact'in içine bakıldı")

tech_extra = pd.DataFrame(artifact_tech)
artifacts_df = pd.concat([artifacts_df.reset_index(drop=True), tech_extra.reset_index(drop=True)], axis=1)

# ─── Sheet 1: Servisler ────────────────────────────────────────────────
service_rows = []
seen_combos = set()
for _, r in artifacts_df.iterrows():
    vcs = normalize_repo_url(r["vcs_url"])
    repo_key = r["repo"]
    combo = (vcs, repo_key) if vcs else (repo_key, r["path"])
    if combo in seen_combos:
        continue
    seen_combos.add(combo)
    service_rows.append({
        "vcs_url": vcs, "platform": detect_platform(vcs),
        "language": r["language"], "build_tool": r["build_tool"],
        "confidence": r["confidence"], "detection_source": r["detection_source"],
        "artifactory_repo": repo_key,
        "repo_package_type": repo_pkg.get(repo_key, "unknown"),
        "sample_artifact": r["name"], "ci_tool": "",
        "build_name": r["build_name"], "build_number": r["build_number"],
        "last_publish": r["created"], "downloads": r["downloads"],
        "source": "artifact-property" if vcs else "no-vcs-info",
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
            if row["language"] == "Unknown" and bt:
                row["build_tool"] = bt
            matched = True
    if matched: continue
    service_rows.append({
        "vcs_url": vcs, "platform": detect_platform(vcs),
        "language": "?", "build_tool": bt or "?",
        "confidence": "build-info", "detection_source": "build-info",
        "artifactory_repo": "", "repo_package_type": "",
        "sample_artifact": "", "ci_tool": ci,
        "build_name": b.get("build_name", ""), "build_number": b.get("build_number", ""),
        "last_publish": b.get("started", ""), "downloads": "0",
        "source": "build-info-only",
    })

services_df = pd.DataFrame(service_rows)

# ─── Sheet 2: Generic Repo Breakdown ───────────────────────────────────
generic_repos = [k for k, v in repo_pkg.items() if v == "generic"]
generic_artifacts = artifacts_df[artifacts_df["repo"].isin(generic_repos)] if not artifacts_df.empty else pd.DataFrame()
if not generic_artifacts.empty:
    generic_breakdown = (generic_artifacts.groupby(["repo", "language", "build_tool", "confidence"])
                         .size().reset_index(name="count").sort_values("count", ascending=False))
else:
    generic_breakdown = pd.DataFrame()

# ─── Sheet 3: Repo Özeti ───────────────────────────────────────────────
if not artifacts_df.empty:
    repo_summary = (artifacts_df.groupby("repo").agg(
        artifact_count=("name", "count"),
        unique_paths=("path", "nunique"),
        total_downloads=("downloads", lambda x: pd.to_numeric(x, errors="coerce").fillna(0).sum()),
        last_publish=("created", "max"),
        primary_language=("language", lambda x: x.mode().iloc[0] if not x.mode().empty else "?"),
    ).reset_index())
    repo_summary["package_type"] = repo_summary["repo"].map(repo_pkg).fillna("unknown")
    repo_summary = repo_summary.sort_values("artifact_count", ascending=False)
else:
    repo_summary = pd.DataFrame()

# ─── Sheet 4: Teknoloji Dağılımı ───────────────────────────────────────
tech_counter = Counter(row["language"] for row in service_rows if row["language"] not in ("?", "Unknown"))
tech_df = pd.DataFrame([{"language": k, "service_count": v} for k, v in tech_counter.most_common()])

# ─── Sheet 5: Yeni Repo Önerileri ──────────────────────────────────────
LANG_TO_PKG = {
    "Java/Kotlin": "maven", "Android": "gradle",
    ".NET": "nuget", ".NET binary": "nuget",
    "Node.js": "npm", "Python": "pypi",
    "Container": "docker", "K8s Chart": "helm",
    "Go": "go", "Ruby": "gems", "PHP": "composer",
    "Rust": "cargo", "Linux pkg": "generic", "C/C++": "conan",
}
detected_langs = {row["language"] for row in service_rows 
                  if row["language"] not in ("Unknown", "?", "Unknown archive", "Native lib")}

suggestions = []; suggested_pkgs = set()
for lang in sorted(detected_langs):
    pkg = LANG_TO_PKG.get(lang)
    if not pkg or pkg in suggested_pkgs: continue
    suggested_pkgs.add(pkg)
    suggestions.append({
        "package_type": pkg, "language": lang,
        "release_repo": f"{pkg}-release-local",
        "snapshot_repo": f"{pkg}-snapshot-local" if pkg in ("maven", "gradle") else "(N/A)",
        "remote_repo": f"{pkg}-remote", "virtual_repo": f"{pkg}-virtual",
        "notes": "Snapshot only for Maven/Gradle" if pkg in ("maven", "gradle") else "",
    })
suggestions_df = pd.DataFrame(suggestions)

# ─── Sheet 6: Aktif Olmayan ────────────────────────────────────────────
all_keys = set(repo_pkg.keys())
active_keys = set(artifacts_df["repo"].unique()) if not artifacts_df.empty else set()
inactive_df = pd.DataFrame([
    {"repo_key": k, "package_type": repo_pkg.get(k, ""), "status": "no recent publishes"}
    for k in sorted(all_keys - active_keys)])

# ─── Sheet 7: Belirsiz Artifact'ler (manuel inceleme) ──────────────────
if not artifacts_df.empty:
    unknowns = artifacts_df[artifacts_df["language"].isin(["Unknown", "Unknown archive"])]
    unknowns_summary = unknowns[["repo", "path", "name", "vcs_url", "created", "confidence"]].copy() if not unknowns.empty else pd.DataFrame()
else:
    unknowns_summary = pd.DataFrame()

# ─── Excel ─────────────────────────────────────────────────────────────
out_file = OUT / "artifactory-discovery-report.xlsx"
wb = Workbook(); wb.remove(wb.active)

def write_df(name, df):
    ws = wb.create_sheet(name)
    if df.empty:
        ws["A1"] = "(boş)"; return
    header_font = Font(bold=True, color="FFFFFF", name="Arial")
    header_fill = PatternFill("solid", start_color="1F4E78")
    border = Border(left=Side(style="thin", color="CCCCCC"),
                    right=Side(style="thin", color="CCCCCC"),
                    top=Side(style="thin", color="CCCCCC"),
                    bottom=Side(style="thin", color="CCCCCC"))
    for ci, cn in enumerate(df.columns, 1):
        c = ws.cell(row=1, column=ci, value=cn)
        c.font = header_font; c.fill = header_fill
        c.alignment = Alignment(horizontal="center", vertical="center"); c.border = border
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
write_df("2. Generic Repolar", generic_breakdown)
write_df("3. Artifactory Repo Özeti", repo_summary)
write_df("4. Teknoloji Dağılımı", tech_df)
write_df("5. Yeni Repo Önerileri", suggestions_df)
write_df("6. Aktif Olmayan Repolar", inactive_df)
write_df("7. Belirsiz Artifact'ler", unknowns_summary)
wb.save(out_file)

print(f"   ✅ Excel: {out_file}")
print(f"      - {len(services_df)} servis kaydı")
print(f"      - {len(generic_breakdown)} generic repo breakdown")
print(f"      - {len(unknowns_summary)} belirsiz artifact (manuel inceleme için)")
PYEOF

echo ""
echo "════════════════════════════════════════════════"
echo "✅ TAMAMLANDI"
echo "   📁 ${OUTPUT_DIR}/artifactory-discovery-report.xlsx"
echo "════════════════════════════════════════════════"
