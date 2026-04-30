"""
repo_scanner.py
Servis repolarından (Bitbucket Server / GitLab) manifest dosyalarını ve
Jenkinsfile'ı API üzerinden çeker (klonlamadan).

Tespit edilen build tool'lar manifest dosyasından gelir → en güçlü kanıt.
"""
import re
import base64
import urllib.request
import urllib.error
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Optional, Tuple

# Aranacak dosyalar (öncelik sırasıyla)
MANIFEST_FILES = [
    "Jenkinsfile",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "package.json",
    "requirements.txt",
    "pyproject.toml",
    "setup.py",
    "go.mod",
    "Cargo.toml",
    "composer.json",
    "Gemfile",
    "Dockerfile",
    "Chart.yaml",
    ".gitlab-ci.yml",
    "bitbucket-pipelines.yml",
]

# .NET için: csproj/sln dosyaları repo dizininde değişken adda olur
# Onlar için tree API kullanmak gerekiyor (ayrı handle ediyoruz)


def http_get(url: str, headers: dict, timeout: int = 15) -> Tuple[Optional[bytes], int]:
    """HTTP GET. (data, status_code) döner. 404 normal (dosya yok)."""
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read(), resp.status
    except urllib.error.HTTPError as e:
        return None, e.code
    except (urllib.error.URLError, TimeoutError):
        return None, 0


def detect_repo_platform(scm_url: str) -> str:
    """SCM URL'sinden Bitbucket mı GitLab mı?"""
    u = (scm_url or "").lower()
    if "bitbucket" in u: return "bitbucket"
    if "gitlab" in u: return "gitlab"
    if "github" in u: return "github"
    return "unknown"


def parse_bitbucket_url(scm_url: str) -> Optional[Tuple[str, str, str]]:
    """
    Bitbucket Server URL'sinden (host, project_key, repo_slug) çıkar.
    
    Örnek inputlar:
    - https://bitbucket.sirket.com/scm/proj/repo            → (host, "proj", "repo")
    - https://bitbucket.sirket.com/scm/proj/repo.git        → (host, "proj", "repo")
    - https://bitbucket.sirket.com/projects/proj/repos/repo → (host, "proj", "repo")
    """
    if not scm_url: return None
    
    # /scm/ formatı
    m = re.match(r"^https?://([^/]+)/scm/([^/]+)/([^/.]+?)(?:\.git)?/?$", scm_url, re.IGNORECASE)
    if m:
        return (m.group(1), m.group(2), m.group(3))
    
    # /projects/ formatı (UI URL'si)
    m = re.match(r"^https?://([^/]+)/projects/([^/]+)/repos/([^/.]+)", scm_url, re.IGNORECASE)
    if m:
        return (m.group(1), m.group(2), m.group(3))
    
    return None


def parse_gitlab_url(scm_url: str) -> Optional[Tuple[str, str]]:
    """
    GitLab URL'sinden (host, project_path) çıkar.
    project_path = "group/subgroup/project" şeklinde olabilir.
    
    Örnek:
    - https://gitlab.sirket.com/finance/billing-service.git → (host, "finance/billing-service")
    """
    if not scm_url: return None
    
    m = re.match(r"^https?://([^/]+)/(.+?)(?:\.git)?/?$", scm_url, re.IGNORECASE)
    if m:
        return (m.group(1), m.group(2))
    
    return None


def fetch_bitbucket_file(host: str, project_key: str, repo_slug: str,
                         file_path: str, branch: str,
                         user: str, token: str) -> Optional[str]:
    """Bitbucket Server'dan tek dosya çek."""
    # https://docs.atlassian.com/bitbucket-server/rest/...
    # Endpoint: /rest/api/1.0/projects/{key}/repos/{slug}/raw/{path}?at={branch}
    url = (
        f"https://{host}/rest/api/1.0/projects/{project_key}/repos/{repo_slug}"
        f"/raw/{urllib.parse.quote(file_path)}"
    )
    if branch:
        url += f"?at={urllib.parse.quote(branch)}"
    
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}"}
    
    data, status = http_get(url, headers)
    if status == 200 and data:
        return data.decode("utf-8", errors="ignore")
    return None


def list_bitbucket_files(host: str, project_key: str, repo_slug: str,
                         branch: str, user: str, token: str) -> List[str]:
    """Bitbucket Server'dan repo'nun root dizinindeki dosya listesi."""
    url = f"https://{host}/rest/api/1.0/projects/{project_key}/repos/{repo_slug}/files"
    if branch:
        url += f"?at={urllib.parse.quote(branch)}&limit=200"
    else:
        url += "?limit=200"
    
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}"}
    
    data, status = http_get(url, headers)
    if status != 200 or not data:
        return []
    
    try:
        import json
        info = json.loads(data)
        return info.get("values", [])
    except Exception:
        return []


def fetch_gitlab_file(host: str, project_path: str, file_path: str,
                      branch: str, token: str) -> Optional[str]:
    """GitLab'dan tek dosya çek."""
    # https://docs.gitlab.com/ee/api/repository_files.html
    # Endpoint: /api/v4/projects/{url-encoded-path}/repository/files/{file_path}/raw?ref={branch}
    project_id = urllib.parse.quote(project_path, safe="")
    file_enc = urllib.parse.quote(file_path, safe="")
    url = (
        f"https://{host}/api/v4/projects/{project_id}/repository/files/{file_enc}/raw"
    )
    if branch:
        url += f"?ref={urllib.parse.quote(branch)}"
    
    headers = {"PRIVATE-TOKEN": token} if token else {}
    
    data, status = http_get(url, headers)
    if status == 200 and data:
        return data.decode("utf-8", errors="ignore")
    return None


def list_gitlab_files(host: str, project_path: str, branch: str,
                      token: str) -> List[str]:
    """GitLab'dan repo root dosya listesi."""
    project_id = urllib.parse.quote(project_path, safe="")
    url = f"https://{host}/api/v4/projects/{project_id}/repository/tree?per_page=100"
    if branch:
        url += f"&ref={urllib.parse.quote(branch)}"
    
    headers = {"PRIVATE-TOKEN": token} if token else {}
    
    data, status = http_get(url, headers)
    if status != 200 or not data:
        return []
    
    try:
        import json
        items = json.loads(data)
        return [item.get("name", "") for item in items if item.get("type") == "blob"]
    except Exception:
        return []


# ─── Manifest İçerik Analizi ───────────────────────────────────────────

# Build tool tespit kuralları (manifest dosya adı → language, build_tool)
MANIFEST_RULES = {
    "pom.xml":              ("Java/Kotlin", "Maven"),
    "build.gradle":         ("Java/Kotlin", "Gradle"),
    "build.gradle.kts":     ("Java/Kotlin", "Gradle (Kotlin DSL)"),
    "settings.gradle":      ("Java/Kotlin", "Gradle"),
    "package.json":         ("Node.js", "npm/yarn"),
    "requirements.txt":     ("Python", "pip"),
    "pyproject.toml":       ("Python", "Poetry/pip"),
    "setup.py":             ("Python", "setuptools"),
    "go.mod":               ("Go", "go modules"),
    "Cargo.toml":           ("Rust", "Cargo"),
    "composer.json":        ("PHP", "Composer"),
    "Gemfile":              ("Ruby", "Bundler"),
    "Dockerfile":           ("Container", "Docker"),
    "Chart.yaml":           ("K8s Chart", "Helm"),
}

# Jenkinsfile içindeki shell komutu pattern'leri (jenkins_scanner ile aynı)
JENKINSFILE_PATTERNS = [
    (r"\bmvn\b\s+(?:[\w:.-]+\s+)*(?:clean\s+)?(?:deploy|package|install)\b", "Maven", "Java/Kotlin"),
    (r"\./mvnw\b", "Maven Wrapper", "Java/Kotlin"),
    (r"\bgradle\b\s+(?:[\w:-]+\s+)*(?:build|publish)\b", "Gradle", "Java/Kotlin"),
    (r"\./gradlew\b", "Gradle Wrapper", "Java/Kotlin"),
    (r"\bdotnet\s+(?:build|pack|publish|restore)\b", "dotnet CLI", ".NET"),
    (r"\bnuget\s+(?:pack|push)\b", "NuGet", ".NET"),
    (r"\bnpm\s+(?:run\s+)?(?:build|publish|pack|ci|install)\b", "npm", "Node.js"),
    (r"\byarn\s+(?:build|publish|install)\b", "Yarn", "Node.js"),
    (r"\bpoetry\s+(?:build|publish)\b", "Poetry", "Python"),
    (r"\bpython\s+setup\.py\b", "setuptools", "Python"),
    (r"\btwine\s+upload\b", "twine", "Python"),
    (r"\bdocker\s+(?:build|push)\b", "Docker", "Container"),
    (r"\bhelm\s+(?:package|push|cm-push)\b", "Helm", "K8s Chart"),
    (r"\bgo\s+build\b", "go build", "Go"),
    (r"\bcargo\s+(?:build|publish)\b", "Cargo", "Rust"),
    (r"\bjfrog\s+rt\s+(?:upload|deploy|u\b)", "JFrog CLI", "Generic publish"),
    (r"\bansiblePlaybook\b", "Ansible (Jenkins step)", "Wrapper"),
    (r"\bansible-playbook\b", "Ansible", "Wrapper"),
]


def analyze_manifest_content(filename: str, content: str) -> dict:
    """
    Manifest dosyasının içeriğinden ek metadata çıkar.
    pom.xml → groupId, artifactId, packaging
    package.json → name, version, scripts
    """
    info = {}
    
    if filename == "pom.xml":
        # Çok hızlı regex parse — XML parser kullanmaya gerek yok
        for tag in ["groupId", "artifactId", "version", "packaging"]:
            m = re.search(f"<{tag}>([^<]+)</{tag}>", content)
            if m:
                info[tag] = m.group(1).strip()
        # Multi-module mu?
        modules = re.findall(r"<module>([^<]+)</module>", content)
        if modules:
            info["modules"] = modules[:10]
            info["is_multi_module"] = True
    
    elif filename == "package.json":
        try:
            import json
            data = json.loads(content)
            info["name"] = data.get("name", "")
            info["version"] = data.get("version", "")
            info["private"] = data.get("private", False)
            scripts = data.get("scripts", {})
            info["has_publish_script"] = "publish" in scripts or "release" in scripts
        except Exception:
            pass
    
    elif filename == "Chart.yaml":
        m = re.search(r"^name:\s*(.+)$", content, re.MULTILINE)
        if m: info["name"] = m.group(1).strip()
        m = re.search(r"^version:\s*(.+)$", content, re.MULTILINE)
        if m: info["version"] = m.group(1).strip()
    
    elif filename == "go.mod":
        m = re.search(r"^module\s+(.+)$", content, re.MULTILINE)
        if m: info["module"] = m.group(1).strip()
    
    return info


def analyze_jenkinsfile(content: str) -> dict:
    """Jenkinsfile içindeki build komutlarını çıkar."""
    if not content:
        return {"tools": set(), "languages": set(), "uses_ansible": False}
    
    found_tools = set()
    found_languages = set()
    
    for pattern, tool, lang in JENKINSFILE_PATTERNS:
        if re.search(pattern, content, re.IGNORECASE):
            found_tools.add(tool)
            found_languages.add(lang)
    
    return {
        "tools": found_tools,
        "languages": found_languages,
        "uses_ansible": "ansible-playbook" in content.lower() or "ansibleplaybook" in content.lower(),
    }


def find_csproj_files(file_list: List[str]) -> List[str]:
    """Dosya listesinden .csproj/.sln dosyalarını ayıkla."""
    return [f for f in file_list if f.endswith((".csproj", ".sln", ".fsproj", ".vbproj"))]


# ─── Ana Tarayıcı Fonksiyonu ───────────────────────────────────────────

def scan_repo(scm_url: str, branch: str,
              bb_user: str, bb_token: str,
              gl_token: str) -> dict:
    """
    Bir servis reposunu tara — manifest + Jenkinsfile API üzerinden çek.
    
    Returns:
      {
        "scm_url": str,
        "platform": "bitbucket" | "gitlab" | "unknown",
        "manifests_found": [...],
        "build_tools_from_manifest": set,
        "languages_from_manifest": set,
        "build_tools_from_jenkinsfile": set,
        "languages_from_jenkinsfile": set,
        "has_jenkinsfile": bool,
        "jenkinsfile_uses_ansible": bool,
        "manifest_metadata": dict,
        "errors": [...],
      }
    """
    result = {
        "scm_url": scm_url,
        "platform": detect_repo_platform(scm_url),
        "manifests_found": [],
        "build_tools_from_manifest": set(),
        "languages_from_manifest": set(),
        "build_tools_from_jenkinsfile": set(),
        "languages_from_jenkinsfile": set(),
        "has_jenkinsfile": False,
        "jenkinsfile_uses_ansible": False,
        "manifest_metadata": {},
        "errors": [],
    }
    
    if not scm_url:
        result["errors"].append("Empty SCM URL")
        return result
    
    platform = result["platform"]
    
    # Branch tahmini — yoksa main/master/dev sırasıyla dene
    if not branch:
        branch_candidates = ["main", "master", "dev", "develop"]
    else:
        # Branch path'i temizle: */main → main, refs/heads/main → main
        clean = branch.replace("*/", "").replace("refs/heads/", "")
        branch_candidates = [clean, "main", "master", "dev"]
        # Tekrarları kaldır, sırayı koru
        seen = set()
        branch_candidates = [b for b in branch_candidates if not (b in seen or seen.add(b))]
    
    file_list = []
    
    if platform == "bitbucket":
        parsed = parse_bitbucket_url(scm_url)
        if not parsed:
            result["errors"].append("Bitbucket URL parse edilemedi")
            return result
        host, project_key, repo_slug = parsed
        
        # Önce dosya listesini al (.csproj gibi değişken adlı dosyaları yakalamak için)
        for br in branch_candidates:
            file_list = list_bitbucket_files(host, project_key, repo_slug, br, bb_user, bb_token)
            if file_list:
                branch = br
                break
        
        # Manifest dosyalarını çek
        for fname in MANIFEST_FILES:
            content = fetch_bitbucket_file(host, project_key, repo_slug, fname, branch, bb_user, bb_token)
            if content:
                result["manifests_found"].append(fname)
                if fname == "Jenkinsfile":
                    result["has_jenkinsfile"] = True
                    jf = analyze_jenkinsfile(content)
                    result["build_tools_from_jenkinsfile"] = jf["tools"]
                    result["languages_from_jenkinsfile"] = jf["languages"]
                    result["jenkinsfile_uses_ansible"] = jf["uses_ansible"]
                else:
                    if fname in MANIFEST_RULES:
                        lang, tool = MANIFEST_RULES[fname]
                        result["build_tools_from_manifest"].add(tool)
                        result["languages_from_manifest"].add(lang)
                    meta = analyze_manifest_content(fname, content)
                    if meta:
                        result["manifest_metadata"][fname] = meta
        
        # .csproj/.sln dosyaları — file_list'ten ayıkla
        csproj_files = find_csproj_files(file_list)
        if csproj_files:
            result["manifests_found"].extend(csproj_files)
            result["build_tools_from_manifest"].add("MSBuild/dotnet")
            result["languages_from_manifest"].add(".NET")
    
    elif platform == "gitlab":
        parsed = parse_gitlab_url(scm_url)
        if not parsed:
            result["errors"].append("GitLab URL parse edilemedi")
            return result
        host, project_path = parsed
        
        # File list (csproj için)
        for br in branch_candidates:
            file_list = list_gitlab_files(host, project_path, br, gl_token)
            if file_list:
                branch = br
                break
        
        for fname in MANIFEST_FILES:
            content = fetch_gitlab_file(host, project_path, fname, branch, gl_token)
            if content:
                result["manifests_found"].append(fname)
                if fname == "Jenkinsfile":
                    result["has_jenkinsfile"] = True
                    jf = analyze_jenkinsfile(content)
                    result["build_tools_from_jenkinsfile"] = jf["tools"]
                    result["languages_from_jenkinsfile"] = jf["languages"]
                    result["jenkinsfile_uses_ansible"] = jf["uses_ansible"]
                else:
                    if fname in MANIFEST_RULES:
                        lang, tool = MANIFEST_RULES[fname]
                        result["build_tools_from_manifest"].add(tool)
                        result["languages_from_manifest"].add(lang)
                    meta = analyze_manifest_content(fname, content)
                    if meta:
                        result["manifest_metadata"][fname] = meta
        
        csproj_files = find_csproj_files(file_list)
        if csproj_files:
            result["manifests_found"].extend(csproj_files)
            result["build_tools_from_manifest"].add("MSBuild/dotnet")
            result["languages_from_manifest"].add(".NET")
    
    else:
        result["errors"].append(f"Desteklenmeyen platform: {platform}")
    
    return result


def scan_all_repos(scm_urls: List[Tuple[str, str]],
                   bb_user: str, bb_token: str,
                   gl_token: str,
                   max_workers: int = 6) -> Dict[str, dict]:
    """
    Çoklu repo paralel tarama.
    Input: [(scm_url, branch), ...]
    Output: {scm_url: result_dict}
    """
    results = {}
    
    # Tekrar eden URL'leri dedupe et
    unique_urls = {}
    for url, branch in scm_urls:
        if url and url not in unique_urls:
            unique_urls[url] = branch
    
    print(f"  📋 {len(unique_urls)} eşsiz repo taranacak")
    
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {
            executor.submit(scan_repo, url, branch, bb_user, bb_token, gl_token): url
            for url, branch in unique_urls.items()
        }
        
        for i, future in enumerate(as_completed(futures), 1):
            url = futures[future]
            try:
                results[url] = future.result()
                if i % 10 == 0:
                    print(f"  Taranan: {i}/{len(unique_urls)}")
            except Exception as e:
                results[url] = {"scm_url": url, "errors": [str(e)]}
    
    return results
