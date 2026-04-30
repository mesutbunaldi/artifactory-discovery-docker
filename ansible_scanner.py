"""
ansible_scanner.py
ansible-roles repo'sunu klonlayıp her rolün tasks/*.yml dosyalarını tarar.
Her rol için: hangi build tool komutlarını çağırıyor → eşleme tablosu.
"""
import os
import re
import subprocess
import shutil
from pathlib import Path
from typing import Dict, List, Tuple

# Build tool tespit pattern'leri (regex, build_tool, language)
BUILD_PATTERNS = [
    # Maven
    (r"\bmvn\b\s+(?:[\w:-]+\s+)*(?:clean\s+)?(?:deploy|package|install|verify)\b",
     "Maven", "Java/Kotlin"),
    (r"\./mvnw\b\s+(?:clean\s+)?(?:deploy|package|install)\b",
     "Maven Wrapper", "Java/Kotlin"),
    
    # Gradle
    (r"\bgradle\b\s+(?:[\w:-]+\s+)*(?:build|publish|assemble|bootJar)\b",
     "Gradle", "Java/Kotlin"),
    (r"\./gradlew\b\s+(?:[\w:-]+\s+)*(?:build|publish|assemble|bootJar)\b",
     "Gradle Wrapper", "Java/Kotlin"),
    
    # .NET
    (r"\bdotnet\b\s+(?:build|pack|publish|restore)\b",
     "dotnet CLI", ".NET"),
    (r"\bmsbuild\b\s+", "MSBuild", ".NET"),
    (r"\bnuget\b\s+pack\b", "NuGet (legacy)", ".NET"),
    (r"\bnuget\b\s+push\b", "NuGet push", ".NET"),
    
    # Node.js
    (r"\bnpm\b\s+(?:run\s+)?(?:build|publish|pack|ci|install)\b",
     "npm", "Node.js"),
    (r"\byarn\b\s+(?:build|publish|pack|install)\b",
     "Yarn", "Node.js"),
    (r"\bpnpm\b\s+(?:build|publish|pack|install)\b",
     "pnpm", "Node.js"),
    
    # Python
    (r"\bpython\s+setup\.py\s+(?:bdist_wheel|sdist|build|install|upload)\b",
     "setuptools", "Python"),
    (r"\bpoetry\b\s+(?:build|publish|install)\b",
     "Poetry", "Python"),
    (r"\btwine\b\s+upload\b", "twine", "Python"),
    (r"\bpip\b\s+install\b.*-e\b", "pip (editable)", "Python"),
    
    # Docker
    (r"\bdocker\b\s+build\b", "Docker build", "Container"),
    (r"\bdocker\b\s+push\b", "Docker push", "Container"),
    (r"\bdocker-compose\b\s+build\b", "Docker Compose", "Container"),
    
    # Helm
    (r"\bhelm\b\s+(?:package|push|cm-push)\b", "Helm", "K8s Chart"),
    
    # Go
    (r"\bgo\s+build\b", "go build", "Go"),
    (r"\bgo\s+mod\b", "go modules", "Go"),
    
    # Rust
    (r"\bcargo\b\s+(?:build|publish|install)\b", "Cargo", "Rust"),
    
    # PHP
    (r"\bcomposer\b\s+(?:install|update|require|build)\b", "Composer", "PHP"),
    
    # Ruby
    (r"\b(?:bundle|gem)\b\s+(?:install|build|push)\b", "Bundler", "Ruby"),
    
    # Generic publish (yedek)
    (r"\bjfrog\b\s+rt\s+(?:upload|deploy|u\b)", "JFrog CLI", "Unknown (publish)"),
    (r"\bcurl\b\s+.*-T\s+.+/artifactory/", "curl upload", "Unknown (publish)"),
]


def clone_or_update_repo(repo_url: str, branch: str, dest: Path,
                         user: str = None, token: str = None) -> bool:
    """ansible-roles reposunu klonla (yoksa) veya güncelle (varsa)."""
    if user and token:
        # https://user:token@host/path formatına çevir
        if repo_url.startswith("https://"):
            authed_url = repo_url.replace("https://", f"https://{user}:{token}@")
        else:
            authed_url = repo_url
    else:
        authed_url = repo_url
    
    # SSL bypass için git env
    git_env = os.environ.copy()
    if os.environ.get("VERIFY_SSL", "true").lower() in ("false", "0", "no", "n"):
        git_env["GIT_SSL_NO_VERIFY"] = "true"
    
    if dest.exists() and (dest / ".git").exists():
        # Mevcut repo - güncelle
        subprocess.run(["git", "-C", str(dest), "fetch", "origin", branch],
                       check=True, capture_output=True, env=git_env)
        subprocess.run(["git", "-C", str(dest), "checkout", branch],
                       check=True, capture_output=True, env=git_env)
        subprocess.run(["git", "-C", str(dest), "reset", "--hard", f"origin/{branch}"],
                       check=True, capture_output=True, env=git_env)
    else:
        # Yeni klon - sadece dev branch, shallow
        if dest.exists():
            shutil.rmtree(dest)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", branch,
                        authed_url, str(dest)],
                       check=True, capture_output=True, env=git_env)
    return True


def scan_role_for_build_tools(role_dir: Path) -> List[Tuple[str, str, str]]:
    """
    Bir rolün tasks/*.yml ve defaults/*.yml dosyalarını tara.
    Her bulunan build komutunu döndür.
    Returns: List of (build_tool, language, snippet)
    """
    findings = []
    
    # Taranacak dosya pattern'leri
    yml_patterns = [
        "tasks/*.yml", "tasks/*.yaml",
        "tasks/**/*.yml", "tasks/**/*.yaml",
        "defaults/*.yml", "vars/*.yml",
        "handlers/*.yml",
    ]
    
    files_to_scan = []
    for pat in yml_patterns:
        files_to_scan.extend(role_dir.glob(pat))
    
    # README'leri de tara — bazen örnek komutlar var
    files_to_scan.extend(role_dir.glob("README*"))
    files_to_scan.extend(role_dir.glob("readme*"))
    
    for fpath in files_to_scan:
        if not fpath.is_file():
            continue
        try:
            content = fpath.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        
        for pattern, tool, lang in BUILD_PATTERNS:
            for match in re.finditer(pattern, content, re.IGNORECASE):
                # Match'in olduğu satırı çek (kontekst için)
                start = content.rfind("\n", 0, match.start()) + 1
                end = content.find("\n", match.end())
                if end == -1:
                    end = len(content)
                snippet = content[start:end].strip()[:200]
                findings.append((tool, lang, snippet))
    
    return findings


def scan_all_roles(roles_dir: Path) -> Dict[str, dict]:
    """
    ansible-roles/roles/ klasöründeki tüm rolleri tara.
    Returns: {role_name: {"build_tools": set, "languages": set, "snippets": list}}
    """
    result = {}
    
    # Standart Ansible role klasör yapıları:
    # - roles/<role-name>/tasks/main.yml
    # - <role-name>/tasks/main.yml
    
    candidates = []
    
    # roles/ alt klasörü varsa onu tercih et
    if (roles_dir / "roles").is_dir():
        candidates = [d for d in (roles_dir / "roles").iterdir() if d.is_dir()]
    
    # Yoksa root altındaki "tasks/" klasörü olan her şeyi rol say
    if not candidates:
        for d in roles_dir.iterdir():
            if d.is_dir() and (d / "tasks").is_dir():
                candidates.append(d)
    
    for role_dir in candidates:
        role_name = role_dir.name
        if role_name.startswith("."):
            continue
        
        findings = scan_role_for_build_tools(role_dir)
        if not findings:
            # Hiç build tool yok — muhtemelen pure-deploy/config rolü
            result[role_name] = {
                "build_tools": set(),
                "languages": set(),
                "snippets": [],
                "is_build_role": False,
            }
            continue
        
        tools = {f[0] for f in findings}
        langs = {f[1] for f in findings}
        snippets = [f[2] for f in findings[:5]]  # ilk 5 snippet
        
        result[role_name] = {
            "build_tools": tools,
            "languages": langs,
            "snippets": snippets,
            "is_build_role": True,
        }
    
    return result


# Test
if __name__ == "__main__":
    import sys, json
    if len(sys.argv) < 2:
        print("Usage: ansible_scanner.py <roles-repo-path>")
        sys.exit(1)
    result = scan_all_roles(Path(sys.argv[1]))
    for name, info in result.items():
        if info["is_build_role"]:
            print(f"  {name}:")
            print(f"    Tools: {info['build_tools']}")
            print(f"    Langs: {info['languages']}")
