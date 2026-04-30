#!/usr/bin/env python3
"""
discovery.py v4 — Cross-Reference + Servis Repo Manifest Tarama

Pipeline:
  1. ansible-roles repo'sunu klonla → her rolün build tool'unu çıkar
  2. Jenkins API → tüm job'lar
  3. Servis repolarını API ile tara (manifest + Jenkinsfile)
  4. Cross-reference + Excel
"""
import os
import sys
import json
from pathlib import Path

import ansible_scanner
import jenkins_scanner
import repo_scanner
import correlator


def env(name: str, default: str = "") -> str:
    val = os.environ.get(name, default)
    if val and val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val


def env_bool(name: str, default: bool = False) -> bool:
    val = env(name, "").lower()
    if val in ("true", "1", "yes", "y"): return True
    if val in ("false", "0", "no", "n"): return False
    return default


def env_int(name: str, default: int) -> int:
    try:
        return int(env(name, str(default)))
    except ValueError:
        return default


def serializable(obj):
    """JSON-serializable hale getir (set'leri list'e çevir)."""
    if isinstance(obj, set):
        return sorted(obj)
    if isinstance(obj, dict):
        return {k: serializable(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [serializable(x) for x in obj]
    return obj


def main():
    # ─── Config ────────────────────────────────────────────────────────
    output_dir = Path(env("OUTPUT_DIR", "/app/output"))
    output_dir.mkdir(parents=True, exist_ok=True)
    
    ansible_repo_url = env("ANSIBLE_ROLES_REPO_URL")
    ansible_repo_branch = env("ANSIBLE_ROLES_BRANCH", "dev")
    
    bb_user = env("BITBUCKET_USER")
    bb_token = env("BITBUCKET_TOKEN")
    
    gl_token = env("GITLAB_TOKEN")
    
    jenkins_url = env("JENKINS_URL")
    jenkins_user = env("JENKINS_USER")
    jenkins_token = env("JENKINS_TOKEN")
    
    fetch_logs = env_bool("FETCH_BUILD_LOGS", True)
    parallel_jobs = env_int("PARALLEL_JOBS", 4)
    parallel_repos = env_int("PARALLEL_REPOS", 6)
    skip_repo_scan = env_bool("SKIP_REPO_SCAN", False)
    
    artifactory_url = env("ARTIFACTORY_URL")
    artifactory_user = env("ARTIFACTORY_USER")
    artifactory_token = env("ARTIFACTORY_TOKEN")
    
    # Validate
    missing = []
    if not ansible_repo_url: missing.append("ANSIBLE_ROLES_REPO_URL")
    if not jenkins_url: missing.append("JENKINS_URL")
    if not jenkins_user: missing.append("JENKINS_USER")
    if not jenkins_token: missing.append("JENKINS_TOKEN")
    if not skip_repo_scan:
        if not bb_user: missing.append("BITBUCKET_USER")
        if not bb_token: missing.append("BITBUCKET_TOKEN")
        if not gl_token: missing.append("GITLAB_TOKEN")
    
    if missing:
        print(f"❌ Eksik env variables: {', '.join(missing)}")
        sys.exit(1)
    
    print("═" * 60)
    print("  Discovery v4 — Cross-Reference Pipeline")
    print("═" * 60)
    print(f"  Ansible roles : {ansible_repo_url} (branch: {ansible_repo_branch})")
    print(f"  Jenkins       : {jenkins_url}")
    print(f"  Skip repo scan: {skip_repo_scan}")
    print(f"  Output dir    : {output_dir}")
    print(f"  Fetch logs    : {fetch_logs}")
    print(f"  Parallel      : jobs={parallel_jobs} repos={parallel_repos}")
    print("═" * 60)
    
    # ─── ADIM 1: ansible-roles ─────────────────────────────────────────
    print("\n🔍 [1/5] ansible-roles repo'su klonlanıp taranıyor...")
    
    roles_clone_dir = output_dir / "ansible-roles-clone"
    try:
        ansible_scanner.clone_or_update_repo(
            ansible_repo_url, ansible_repo_branch, roles_clone_dir,
            user=bb_user, token=bb_token,
        )
    except Exception as e:
        print(f"❌ Repo klonlanamadı: {e}")
        sys.exit(1)
    
    roles_data = ansible_scanner.scan_all_roles(roles_clone_dir)
    build_roles_count = sum(1 for r in roles_data.values() if r.get("is_build_role"))
    print(f"  📋 {len(roles_data)} rol bulundu ({build_roles_count} build rolü)")
    
    (output_dir / "01-ansible-roles.json").write_text(
        json.dumps(serializable(roles_data), indent=2, ensure_ascii=False)
    )
    
    # ─── ADIM 2: Jenkins Jobs ──────────────────────────────────────────
    print(f"\n🔍 [2/5] Jenkins job'ları taranıyor...")
    
    jobs_data = jenkins_scanner.scan_all_jobs(
        jenkins_url, jenkins_user, jenkins_token,
        fetch_logs=fetch_logs, max_workers=parallel_jobs,
    )
    
    (output_dir / "02-jenkins-jobs.json").write_text(
        json.dumps([serializable(j) for j in jobs_data], indent=2, ensure_ascii=False)
    )
    
    # ─── ADIM 3: Servis Repolar (manifest + Jenkinsfile) ───────────────
    repos_data = {}
    if skip_repo_scan:
        print(f"\n⏭️  [3/5] Servis repo taraması atlandı (SKIP_REPO_SCAN=true)")
    else:
        print(f"\n🔍 [3/5] Servis repolarından manifest dosyaları çekiliyor...")
        
        # Job'lardan SCM URL'lerini topla
        scm_urls = []
        for job in jobs_data:
            scm = job.get("primary_scm_url", "")
            branches = job.get("branches", [])
            branch = branches[0] if branches else ""
            if scm:
                scm_urls.append((scm, branch))
        
        repos_data = repo_scanner.scan_all_repos(
            scm_urls=scm_urls,
            bb_user=bb_user, bb_token=bb_token,
            gl_token=gl_token,
            max_workers=parallel_repos,
        )
        
        # İstatistik
        with_manifest = sum(1 for r in repos_data.values() if r.get("build_tools_from_manifest"))
        with_jenkinsfile = sum(1 for r in repos_data.values() if r.get("has_jenkinsfile"))
        with_errors = sum(1 for r in repos_data.values() if r.get("errors"))
        print(f"  📋 {len(repos_data)} repo tarandı")
        print(f"     - {with_manifest} reposunda manifest dosyası bulundu")
        print(f"     - {with_jenkinsfile} reposunda Jenkinsfile bulundu")
        print(f"     - {with_errors} reposunda hata")
        
        (output_dir / "03-service-repos.json").write_text(
            json.dumps(serializable(repos_data), indent=2, ensure_ascii=False)
        )
    
    # ─── ADIM 4: Artifactory (opsiyonel, henüz uygulanmadı) ────────────
    artifactory_data = None
    if artifactory_url and artifactory_user and artifactory_token:
        print(f"\n⏭️  [4/5] Artifactory cross-ref atlandı (henüz uygulanmadı)")
    else:
        print(f"\n⏭️  [4/5] Artifactory atlandı (env yok)")
    
    # ─── ADIM 5: Cross-reference + Excel ───────────────────────────────
    print(f"\n🔍 [5/5] Verileri birleştirip Excel oluşturuluyor...")
    
    correlated = correlator.correlate(jobs_data, roles_data, repos_data, artifactory_data)
    output_xlsx = output_dir / "discovery-report.xlsx"
    correlator.write_excel(output_xlsx, correlated, roles_data, jobs_data, repos_data)
    
    # Özet
    print()
    print("═" * 60)
    print("✅ TAMAMLANDI")
    print("═" * 60)
    print(f"  📁 Excel    : {output_xlsx}")
    print(f"  📊 Servisler: {len(correlated)}")
    
    from collections import Counter
    conf_dist = Counter(r["confidence"] for r in correlated)
    print(f"  🎯 Confidence: ", end="")
    for conf in ["high", "medium", "conflict", "low", "no-data"]:
        if conf in conf_dist:
            print(f"{conf}={conf_dist[conf]}  ", end="")
    print()
    
    # Conflict varsa öne çıkar
    conflicts = [r for r in correlated if r["confidence"] == "conflict"]
    if conflicts:
        print(f"\n  ⚠️  {len(conflicts)} CONFLICT tespit edildi — Sheet 3'ü incele!")
        print("     Bunlar manifest ile CI'nın uyuşmadığı yerler")
    
    print("═" * 60)


if __name__ == "__main__":
    main()
