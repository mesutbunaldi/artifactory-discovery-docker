"""
jenkins_scanner.py
Jenkins API'den:
  - Tüm job'ları (folder ve multibranch dahil recursive) çek
  - Her job için config.xml + son başarılı build log'unu çek
  - Build log'undan ansible role çağrılarını ve build komutlarını bul
"""
import re
import json
import base64
import urllib.request
import urllib.error
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Optional, Set


def http_get(url: str, user: str, token: str, timeout: int = 30) -> Optional[bytes]:
    """Basic Auth ile HTTP GET. Hata olursa None döner."""
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
        return None


def list_all_jobs(jenkins_url: str, user: str, token: str) -> List[dict]:
    """
    Tüm job'ları recursive olarak listele.
    Folder, Pipeline, Multibranch — hepsini düz bir listeye çevirir.
    
    Returns: [{"name": "...", "url": "...", "type": "...", "full_name": "team/job"}]
    """
    # Recursive depth-3 query — yeterli pratik için, daha derin folder yapısı varsa artırılır
    api_url = (
        f"{jenkins_url.rstrip('/')}/api/json"
        "?tree=jobs[name,url,_class,"
        "jobs[name,url,_class,"
        "jobs[name,url,_class,"
        "jobs[name,url,_class]]]]"
    )
    
    data = http_get(api_url, user, token)
    if not data:
        return []
    
    try:
        root = json.loads(data)
    except json.JSONDecodeError:
        return []
    
    flat = []
    
    def walk(jobs, prefix=""):
        for job in jobs:
            name = job.get("name", "")
            url = job.get("url", "")
            klass = job.get("_class", "")
            full_name = f"{prefix}/{name}" if prefix else name
            
            # Folder veya Organization Folder ise içine in
            if "Folder" in klass or "OrganizationFolder" in klass:
                if "jobs" in job:
                    walk(job["jobs"], full_name)
            
            # Multibranch — alt branch job'ları içerir
            elif "WorkflowMultiBranchProject" in klass:
                if "jobs" in job:
                    walk(job["jobs"], full_name)
            
            # Asıl job (Pipeline, FreeStyle, vs.)
            else:
                flat.append({
                    "name": name,
                    "full_name": full_name,
                    "url": url,
                    "class": klass,
                })
    
    walk(root.get("jobs", []))
    return flat


def get_job_config_xml(job_url: str, user: str, token: str) -> Optional[str]:
    """Job'un config.xml'ini çek."""
    config_url = f"{job_url.rstrip('/')}/config.xml"
    data = http_get(config_url, user, token)
    if not data:
        return None
    return data.decode("utf-8", errors="ignore")


def parse_config_xml(xml_text: str) -> dict:
    """
    config.xml'den çıkarılacaklar:
      - SCM URL (git repo)
      - Branch
      - Shell adımlarındaki komutlar (FreeStyle job'lar için)
      - Pipeline script (inline) — varsa
      - Pipeline scriptPath (Jenkinsfile yolu)
      - SCM source repo (multibranch için)
    """
    result = {
        "scm_urls": [],
        "branches": [],
        "shell_commands": [],
        "pipeline_script": "",
        "jenkinsfile_path": "",
        "definition_type": "",
    }
    
    if not xml_text:
        return result
    
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return result
    
    # SCM url'leri (hem freestyle hem pipeline için)
    for url_elem in root.iter("url"):
        u = (url_elem.text or "").strip()
        if u and ("git" in u.lower() or "bitbucket" in u.lower() or "gitlab" in u.lower()):
            if u not in result["scm_urls"]:
                result["scm_urls"].append(u)
    
    # Branch'ler
    for br_elem in root.iter("name"):
        # <hudson.plugins.git.BranchSpec> içinde
        parent = br_elem.getparent() if hasattr(br_elem, 'getparent') else None
        text = (br_elem.text or "").strip()
        if text.startswith("*/") or text.startswith("origin/"):
            result["branches"].append(text)
    
    # FreeStyle job — shell builder
    for cmd in root.iter("command"):
        c = (cmd.text or "").strip()
        if c:
            result["shell_commands"].append(c)
    
    # Pipeline tipi
    for definition in root.iter("definition"):
        klass = definition.get("class", "")
        if "CpsFlowDefinition" in klass:
            result["definition_type"] = "Pipeline (inline)"
            for script in definition.iter("script"):
                result["pipeline_script"] = (script.text or "").strip()
                break
        elif "CpsScmFlowDefinition" in klass:
            result["definition_type"] = "Pipeline from SCM"
            for sp in definition.iter("scriptPath"):
                result["jenkinsfile_path"] = (sp.text or "").strip()
                break
    
    return result


# Console log'da bulunacak pattern'ler
LOG_PATTERNS = [
    # (regex, build_tool, language)
    (r"\bmvn\b\s+(?:[\w:.-]+\s+)*(?:clean\s+)?(?:deploy|package|install)\b",
     "Maven", "Java/Kotlin"),
    (r"\./mvnw\b", "Maven Wrapper", "Java/Kotlin"),
    (r"\bgradle\b\s+(?:[\w:-]+\s+)*(?:build|publish|assemble)\b",
     "Gradle", "Java/Kotlin"),
    (r"\./gradlew\b", "Gradle Wrapper", "Java/Kotlin"),
    (r"\bdotnet\s+(?:build|pack|publish|restore)\b", "dotnet CLI", ".NET"),
    (r"\bnuget\s+pack\b", "NuGet (legacy)", ".NET"),
    (r"\bnuget\s+push\b", "NuGet push", ".NET"),
    (r"\bnpm\s+(?:run\s+)?(?:build|publish|pack|ci|install)\b", "npm", "Node.js"),
    (r"\byarn\s+(?:build|publish|install)\b", "Yarn", "Node.js"),
    (r"\bpnpm\s+(?:build|publish|install)\b", "pnpm", "Node.js"),
    (r"\bpython\s+setup\.py\s+(?:bdist_wheel|sdist|build)\b", "setuptools", "Python"),
    (r"\bpoetry\s+(?:build|publish)\b", "Poetry", "Python"),
    (r"\btwine\s+upload\b", "twine", "Python"),
    (r"\bdocker\s+build\b", "Docker build", "Container"),
    (r"\bdocker\s+push\b", "Docker push", "Container"),
    (r"\bhelm\s+(?:package|push|cm-push)\b", "Helm", "K8s Chart"),
    (r"\bgo\s+build\b", "go build", "Go"),
    (r"\bcargo\s+(?:build|publish)\b", "Cargo", "Rust"),
    (r"\bjfrog\s+rt\s+(?:upload|deploy|u\b)", "JFrog CLI", "Generic publish"),
]

# Ansible role çağrı pattern'leri
ANSIBLE_PATTERNS = [
    # ansible-playbook çağrıları
    re.compile(r"ansible-playbook\s+[\w./\-]+\.ya?ml(?:\s+[\w\-=,/.{}]+)*", re.IGNORECASE),
    # 'roles:' bloğu altındaki rol adları
    re.compile(r"-\s+role:\s+[\"']?([\w\-]+)[\"']?", re.IGNORECASE),
    # 'roles:\n  - name'
    re.compile(r"^\s*-\s+([\w\-]+)\s*$", re.MULTILINE),
]

# Console log'unda "PLAY [...]" veya "TASK [role: ...]" görüntüleri
ROLE_INVOCATION_PATTERN = re.compile(
    r"TASK\s+\[([\w\-]+)\s*:", re.IGNORECASE
)


def get_last_successful_build_log(job_url: str, user: str, token: str,
                                   max_log_size: int = 500_000) -> Optional[str]:
    """
    Son başarılı build'in console log'unu çek.
    Çok büyükse ilk N byte ile sınırla.
    """
    # Önce son başarılı build numarasını öğren
    api_url = f"{job_url.rstrip('/')}/lastSuccessfulBuild/api/json?tree=number,timestamp"
    data = http_get(api_url, user, token)
    if not data:
        return None
    try:
        info = json.loads(data)
        build_num = info.get("number")
    except json.JSONDecodeError:
        return None
    
    if not build_num:
        return None
    
    log_url = f"{job_url.rstrip('/')}/{build_num}/consoleText"
    log_data = http_get(log_url, user, token, timeout=60)
    if not log_data:
        return None
    
    log_text = log_data.decode("utf-8", errors="ignore")
    if len(log_text) > max_log_size:
        # Başını ve sonunu al — build komutları başta, publish sonda olur
        half = max_log_size // 2
        log_text = log_text[:half] + "\n...[TRUNCATED]...\n" + log_text[-half:]
    return log_text


def analyze_log(log_text: str) -> dict:
    """Log'dan build tool'ları, ansible rolleri çıkar."""
    found_tools = set()
    found_languages = set()
    role_invocations = set()
    
    for pattern, tool, lang in LOG_PATTERNS:
        if re.search(pattern, log_text, re.IGNORECASE):
            found_tools.add(tool)
            found_languages.add(lang)
    
    # Ansible role TASK'larından
    for match in ROLE_INVOCATION_PATTERN.finditer(log_text):
        role_invocations.add(match.group(1))
    
    return {
        "tools": found_tools,
        "languages": found_languages,
        "ansible_roles": role_invocations,
    }


def analyze_config_shell_commands(config: dict) -> dict:
    """
    config.xml'den çıkarılan shell komutlarını + pipeline script'i analiz et.
    """
    text_blob = "\n".join(config.get("shell_commands", []))
    text_blob += "\n" + config.get("pipeline_script", "")
    
    found_tools = set()
    found_languages = set()
    ansible_roles_called = set()
    
    for pattern, tool, lang in LOG_PATTERNS:
        if re.search(pattern, text_blob, re.IGNORECASE):
            found_tools.add(tool)
            found_languages.add(lang)
    
    # Ansible playbook çağrıları
    for pat in ANSIBLE_PATTERNS:
        for match in pat.finditer(text_blob):
            try:
                ansible_roles_called.add(match.group(1))
            except (IndexError, AttributeError):
                pass
    
    return {
        "tools": found_tools,
        "languages": found_languages,
        "ansible_roles": ansible_roles_called,
        "uses_ansible": "ansible-playbook" in text_blob.lower() or "ansible.builtin" in text_blob.lower(),
    }


def normalize_git_url(url: str) -> str:
    """Git URL'yi normalize et (SSH→HTTPS, .git temizle)."""
    if not url:
        return ""
    url = url.strip().rstrip("/")
    m = re.match(r"^(?:ssh://)?git@([^:/]+)[:/](.+?)(?:\.git)?$", url)
    if m:
        return f"https://{m.group(1)}/{m.group(2)}"
    if url.endswith(".git"):
        url = url[:-4]
    return url


def scan_job(job: dict, jenkins_user: str, jenkins_token: str,
             fetch_log: bool = True) -> dict:
    """
    Tek bir job'ı tarar:
      1. config.xml çek + analiz
      2. Son başarılı build log'unu çek + analiz
    """
    result = {
        "job_full_name": job["full_name"],
        "job_url": job["url"],
        "job_class": job["class"],
        "scm_urls": [],
        "primary_scm_url": "",
        "branches": [],
        "definition_type": "",
        "uses_ansible": False,
        "ansible_roles_invoked": set(),
        "build_tools_from_config": set(),
        "build_tools_from_log": set(),
        "languages_from_config": set(),
        "languages_from_log": set(),
        "log_fetched": False,
        "config_fetched": False,
    }
    
    # 1. Config XML
    config_xml = get_job_config_xml(job["url"], jenkins_user, jenkins_token)
    if config_xml:
        result["config_fetched"] = True
        config = parse_config_xml(config_xml)
        result["scm_urls"] = [normalize_git_url(u) for u in config["scm_urls"]]
        result["primary_scm_url"] = result["scm_urls"][0] if result["scm_urls"] else ""
        result["branches"] = config["branches"]
        result["definition_type"] = config["definition_type"]
        
        config_analysis = analyze_config_shell_commands(config)
        result["build_tools_from_config"] = config_analysis["tools"]
        result["languages_from_config"] = config_analysis["languages"]
        result["uses_ansible"] = config_analysis["uses_ansible"]
        result["ansible_roles_invoked"].update(config_analysis["ansible_roles"])
    
    # 2. Build log (opsiyonel — yavaş ama doğrulayıcı)
    if fetch_log:
        log = get_last_successful_build_log(job["url"], jenkins_user, jenkins_token)
        if log:
            result["log_fetched"] = True
            log_analysis = analyze_log(log)
            result["build_tools_from_log"] = log_analysis["tools"]
            result["languages_from_log"] = log_analysis["languages"]
            result["ansible_roles_invoked"].update(log_analysis["ansible_roles"])
    
    return result


def scan_all_jobs(jenkins_url: str, user: str, token: str,
                  fetch_logs: bool = True, max_workers: int = 4) -> List[dict]:
    """Tüm job'ları paralel tara."""
    jobs = list_all_jobs(jenkins_url, user, token)
    print(f"  📋 {len(jobs)} job bulundu")
    
    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(scan_job, j, user, token, fetch_logs): j for j in jobs}
        for i, future in enumerate(as_completed(futures), 1):
            try:
                result = future.result()
                results.append(result)
                if i % 10 == 0:
                    print(f"  Taranan: {i}/{len(jobs)}")
            except Exception as e:
                print(f"  ⚠️  Job tarama hatası: {e}")
    
    return results
