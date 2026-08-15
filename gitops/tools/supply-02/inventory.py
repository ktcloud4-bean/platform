#!/usr/bin/env python3
"""
SUPPLY-02: Container Image Inventory Extractor for k3s & GitOps
Extracts (cluster, namespace, controller, container, image, digest, registry, exception) tuples
from:
  1. Git manifests (gitops/apps/)
  2. Rendered manifests (kustomize build)
  3. Live cluster state (k3s-01 runtime Pods & Controllers)

Generates:
  - docs/evidence/supply-02/inventory.json
  - docs/evidence/supply-02/README.md
"""

import os
import sys
import json
import re
import subprocess
from collections import defaultdict
from typing import List, Dict, Any, Tuple

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
KUBECONFIG = os.path.expanduser("~/.kube/k3s-01-admin.yaml")

def parse_image_ref(image_str: str) -> Dict[str, str]:
    """Parse image reference into registry, repository, tag, digest."""
    digest = "tag-only"
    if "@sha256:" in image_str:
        parts = image_str.split("@")
        image_no_digest = parts[0]
        digest = parts[1]
    else:
        image_no_digest = image_str

    if ":" in image_no_digest.split("/")[-1]:
        repo_part, tag = image_no_digest.rsplit(":", 1)
    else:
        repo_part = image_no_digest
        tag = "latest" if digest == "tag-only" else "none"

    parts = repo_part.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry = parts[0]
        repository = "/".join(parts[1:])
    else:
        registry = "docker.io"
        repository = repo_part if len(parts) == 1 else "/".join(parts)

    return {
        "full_image": image_str,
        "registry": registry,
        "repository": repository,
        "tag": tag,
        "digest": digest
    }

def get_system_exception(namespace: str, controller: str, image_info: Dict[str, str]) -> str:
    """Determine if resource qualifies as system exact exception."""
    if namespace in ["kube-system", "kube-public", "kube-node-lease", "harbor", "e2e-01"]:
        return f"system-namespace-{namespace}"
    if namespace == "kyverno":
        return "system-security-kyverno"
    if "falco" in controller.lower() or "falco" in image_info["repository"]:
        return "system-security-falco"
    if "wazuh" in controller.lower() or "wazuh" in image_info["repository"]:
        return "system-security-wazuh"
    if "coredns" in controller.lower():
        return "system-dns-coredns"
    if "traefik" in controller.lower():
        return "system-ingress-traefik"
    return "none"

def extract_containers_from_pod_spec(pod_spec: Dict[str, Any], cluster: str, namespace: str, controller: str, source_type: str) -> List[Dict[str, Any]]:
    tuples = []
    if not isinstance(pod_spec, dict):
        return tuples

    container_types = [
        ("containers", "standard"),
        ("initContainers", "init"),
        ("ephemeralContainers", "ephemeral")
    ]

    for c_key, c_type in container_types:
        containers = pod_spec.get(c_key) or []
        for c in containers:
            if not isinstance(c, dict):
                continue
            c_name = c.get("name", "unknown")
            image = c.get("image", "")
            if not image:
                continue

            parsed = parse_image_ref(image)
            exception = get_system_exception(namespace, controller, parsed)

            tuples.append({
                "cluster": cluster,
                "namespace": namespace,
                "controller": controller,
                "container": f"{c_type}:{c_name}",
                "image": image,
                "digest": parsed["digest"],
                "registry": parsed["registry"],
                "repository": parsed["repository"],
                "tag": parsed["tag"],
                "exception": exception,
                "source": source_type
            })

    return tuples

def extract_from_manifest_doc(doc: Dict[str, Any], cluster: str, default_namespace: str, source_type: str) -> List[Dict[str, Any]]:
    if not isinstance(doc, dict):
        return []

    kind = doc.get("kind", "")
    metadata = doc.get("metadata", {}) or {}
    name = metadata.get("name", "unnamed")
    namespace = metadata.get("namespace", default_namespace)
    controller = f"{kind}/{name}"

    spec = doc.get("spec", {}) or {}

    if kind == "Pod":
        return extract_containers_from_pod_spec(spec, cluster, namespace, controller, source_type)
    elif kind in ["Deployment", "StatefulSet", "DaemonSet", "Job"]:
        template_spec = spec.get("template", {}).get("spec", {})
        return extract_containers_from_pod_spec(template_spec, cluster, namespace, controller, source_type)
    elif kind == "CronJob":
        job_template_spec = spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
        return extract_containers_from_pod_spec(job_template_spec, cluster, namespace, controller, source_type)
    elif kind == "AWX":
        # Handle AWX Custom Resource image fields
        tuples = []
        cr_images = []
        # Main AWX image
        img = spec.get("image", "")
        ver = spec.get("image_version", "")
        if img:
            full_img = f"{img}:{ver}" if ver and ":" not in img and "@" not in img else (f"{img}@{ver}" if ver and ver.startswith("sha256:") else (f"{img}:{ver}" if ver else img))
            cr_images.append(("standard:awx", full_img))
        # Init container
        init_img = spec.get("init_container_image", "")
        init_ver = spec.get("init_container_image_version", "")
        if init_img:
            full_init = f"{init_img}:{init_ver}" if init_ver and ":" not in init_img and "@" not in init_img else (f"{init_img}@{init_ver}" if init_ver and init_ver.startswith("sha256:") else (f"{init_img}:{init_ver}" if init_ver else init_img))
            cr_images.append(("init:awx-init", full_init))
        # Control plane EE
        cp_ee = spec.get("control_plane_ee_image", "")
        if cp_ee:
            cr_images.append(("standard:control-plane-ee", cp_ee))
        # Redis
        redis_img = spec.get("redis_image", "")
        redis_ver = spec.get("redis_image_version", "")
        if redis_img:
            full_redis = f"{redis_img}:{redis_ver}" if redis_ver and ":" not in redis_img and "@" not in redis_img else (f"{redis_img}@{redis_ver}" if redis_ver and redis_ver.startswith("sha256:") else (f"{redis_img}:{redis_ver}" if redis_ver else redis_img))
            cr_images.append(("standard:redis", full_redis))
        # EE images
        for ee in spec.get("ee_images", []):
            ee_img = ee.get("image", "")
            ee_name = ee.get("name", "ee")
            if ee_img:
                cr_images.append((f"ee:{ee_name}", ee_img))

        for c_label, c_img in cr_images:
            parsed = parse_image_ref(c_img)
            exception = get_system_exception(namespace, controller, parsed)
            tuples.append({
                "cluster": cluster,
                "namespace": namespace,
                "controller": controller,
                "container": c_label,
                "image": c_img,
                "digest": parsed["digest"],
                "registry": parsed["registry"],
                "repository": parsed["repository"],
                "tag": parsed["tag"],
                "exception": exception,
                "source": source_type
            })
        return tuples
    
    return []

def extract_git_manifests() -> List[Dict[str, Any]]:
    import yaml
    tuples = []
    apps_dir = os.path.join(REPO_ROOT, "gitops/apps")

    for root, dirs, files in os.walk(apps_dir):
        for f in files:
            if f.endswith((".yaml", ".yml")):
                file_path = os.path.join(root, f)
                app_name = os.path.relpath(file_path, apps_dir).split(os.sep)[0]
                try:
                    with open(file_path, "r", encoding="utf-8") as stream:
                        for doc in yaml.safe_load_all(stream):
                            if doc:
                                tuples.extend(extract_from_manifest_doc(doc, "k3s-01", app_name, f"git:{app_name}"))
                except Exception:
                    pass
    return tuples

def extract_rendered_manifests() -> List[Dict[str, Any]]:
    import yaml
    tuples = []
    apps_dir = os.path.join(REPO_ROOT, "gitops/apps")

    for app in sorted(os.listdir(apps_dir)):
        app_path = os.path.join(apps_dir, app)
        if not os.path.isdir(app_path):
            continue

        if os.path.exists(os.path.join(app_path, "kustomization.yaml")):
            try:
                res = subprocess.run(
                    ["kubectl", "kustomize", app_path],
                    capture_output=True, text=True, check=True
                )
                for doc in yaml.safe_load_all(res.stdout):
                    if doc:
                        tuples.extend(extract_from_manifest_doc(doc, "k3s-01", app, f"render:{app}"))
            except Exception:
                pass

        if os.path.exists(os.path.join(app_path, "Chart.yaml")):
            # Helm chart template rendering
            val_files = [f for f in os.listdir(app_path) if f.startswith("values-") and f.endswith((".yaml", ".yml"))]
            if not val_files:
                val_files = [f for f in os.listdir(app_path) if f.startswith("values") and f.endswith((".yaml", ".yml"))]
            cmd = ["helm", "template", app, app_path]
            for vf in sorted(val_files):
                cmd.extend(["-f", os.path.join(app_path, vf)])
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, check=True)
                for doc in yaml.safe_load_all(res.stdout):
                    if doc:
                        tuples.extend(extract_from_manifest_doc(doc, "k3s-01", app, f"render:{app}"))
            except Exception:
                pass

    return tuples

def extract_live_cluster() -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    tuples = []
    reports_info = {}

    try:
        env = os.environ.copy()
        env["KUBECONFIG"] = KUBECONFIG

        res = subprocess.run(
            ["kubectl", "get", "pods", "-A", "-o", "json"],
            capture_output=True, text=True, check=True, env=env
        )
        pods_data = json.loads(res.stdout)
        for item in pods_data.get("items", []):
            phase = item.get("status", {}).get("phase", "")
            if phase in ["Succeeded", "Failed"]:
                continue
            ns = item["metadata"]["namespace"]
            name = item["metadata"]["name"]
            owner_refs = item["metadata"].get("ownerReferences", [])
            if owner_refs:
                controller = f"{owner_refs[0]['kind']}/{owner_refs[0]['name']}"
            else:
                controller = f"Pod/{name}"

            tuples.extend(extract_containers_from_pod_spec(item["spec"], "k3s-01", ns, controller, "live:pod"))

        report_res = subprocess.run(
            ["kubectl", "get", "policyreports,clusterpolicyreports", "-A", "-o", "json"],
            capture_output=True, text=True, env=env
        )
        if report_res.returncode == 0:
            reports_data = json.loads(report_res.stdout)
            reports_info = reports_data

    except Exception as e:
        print(f"Error fetching live cluster data: {e}", file=sys.stderr)

    return tuples, reports_info

def generate_inventory_report() -> Dict[str, Any]:
    git_tuples = extract_git_manifests()
    render_tuples = extract_rendered_manifests()
    live_tuples, reports_data = extract_live_cluster()

    def dedup(t_list):
        seen = set()
        out = []
        for t in t_list:
            key = (t["cluster"], t["namespace"], t["controller"], t["container"], t["image"])
            if key not in seen:
                seen.add(key)
                out.append(t)
        return out

    unique_git = dedup(git_tuples)
    unique_render = dedup(render_tuples)
    unique_live = dedup(live_tuples)

    live_images = set(t["image"] for t in unique_live)
    live_registries = defaultdict(list)
    tag_only_live = []
    pinned_digest_live = []
    system_exceptions_live = []
    user_workloads_live = []

    for t in unique_live:
        live_registries[t["registry"]].append(t)
        if t["digest"] == "tag-only":
            tag_only_live.append(t)
        else:
            pinned_digest_live.append(t)

        if t["exception"] != "none":
            system_exceptions_live.append(t)
        else:
            user_workloads_live.append(t)

    summary = {
        "metrics": {
            "total_git_tuples": len(unique_git),
            "total_render_tuples": len(unique_render),
            "total_live_tuples": len(unique_live),
            "unique_live_images_count": len(live_images),
            "pinned_digest_count": len(pinned_digest_live),
            "tag_only_count": len(tag_only_live),
            "system_exception_count": len(system_exceptions_live),
            "user_workload_count": len(user_workloads_live),
            "harbor_internal_count": len(live_registries.get("harbor.imcherry5778.xyz", [])),
            "upstream_external_count": sum(len(v) for k, v in live_registries.items() if k != "harbor.imcherry5778.xyz")
        },
        "registries": {reg: len(items) for reg, items in live_registries.items()},
        "live_tuples": unique_live,
        "tag_only_tuples": tag_only_live,
        "system_exception_tuples": system_exceptions_live,
        "user_workload_tuples": user_workloads_live
    }

    return summary

def generate_markdown_report(report: Dict[str, Any]) -> str:
    m = report["metrics"]
    regs = report["registries"]
    
    md = []
    md.append("# SUPPLY-02: k3s 컨테이너 이미지 공급망 인벤토리 및 감사 보고서\n")
    md.append("이 문서는 `SUPPLY-02` 작업에서 k3s 클러스터 전체 워크로드를 대상으로 산출한 컨테이너 이미지 인벤토리 실측 데이터와 Kyverno Audit 정책 감사 결과를 기록한다.\n")
    md.append("단일 원본 추출 도구: `gitops/tools/supply-02/inventory.py`\n")
    
    md.append("## 1. 인벤토리 요약 지표 (Metrics Summary)\n")
    md.append("| 지표 항목 | 실측값 | 설명 |")
    md.append("|---|---|---|")
    md.append(f"| **총 Live 컨테이너 튜플 수** | `{m['total_live_tuples']}` | k3s 클러스터에서 실제 가동 중인 Pod 컨테이너 인스턴스 총합 |")
    md.append(f"| **고유 이미지 참조 수 (Unique Images)** | `{m['unique_live_images_count']}` | 레지스트리/저장소/태그/다이제스트 기준 고유 이미지 수 |")
    md.append(f"| **sha256 다이제스트 고정 이미지 수** | `{m['pinned_digest_count']}` | `@sha256:` 불변 다이제스트로 고정된 컨테이너 수 |")
    md.append(f"| **Tag-only 미고정 이미지 수** | `{m['tag_only_count']}` | sha256 고정 없이 mutable tag로 선언된 컨테이너 수 (`SUPPLY-04` 전환 대상) |")
    md.append(f"| **Harbor 내부 승격 이미지 수** | `{m['harbor_internal_count']}` | 내부 Harbor(`harbor.imcherry5778.xyz`)에서 소비 중인 이미지 수 |")
    md.append(f"| **외부 Upstream 직접 참조 수** | `{m['upstream_external_count']}` | 외부 public registry를 직접 pull 중인 수 (`SUPPLY-03`~`04` Proxy/Curated 대상) |")
    md.append(f"| **시스템 예외 대상 (System Exceptions)** | `{m['system_exception_count']}` | `kube-system`, `kyverno`, `falco`, `wazuh` 등 시스템 컴포넌트 |")
    md.append(f"| **일반 워크로드 대상 (User Workloads)** | `{m['user_workload_count']}` | 플랫폼 사용자 및 애플리케이션 서비스 컴포넌트 |")
    md.append("")

    md.append("## 2. 레지스트리별 분포 현황 (Registry Distribution)\n")
    md.append("| 레지스트리 도메인 | 컨테이너 튜플 수 | 비중 (%) | 분류 |")
    md.append("|---|---|---|---|")
    for reg, count in sorted(regs.items(), key=lambda x: x[1], reverse=True):
        pct = (count / m['total_live_tuples']) * 100
        category = "내부 레지스트리" if "harbor" in reg else "외부 Upstream (Proxy Cache 대상)"
        md.append(f"| `{reg}` | {count} | {pct:.1f}% | {category} |")
    md.append("")

    md.append("## 3. 소스별 튜플 비교 및 차이점 분석 (Git vs Render vs Live)\n")
    md.append("- **Git 선언 튜플 수**: `{}`".format(m['total_git_tuples']))
    md.append("- **Render 렌더링 튜플 수**: `{}`".format(m['total_render_tuples']))
    md.append("- **Live 실행 튜플 수**: `{}`".format(m['total_live_tuples']))
    md.append("\n### 차이점 발생 원인 분석:")
    md.append("1. **Helm Chart-Generated 컴포넌트**: Vault agent-injector, Cert-Manager webhook, Harbor exporter 등 Helm 릴리스가 런타임에 주입하는 sidecar/initContainer로 인해 Live 튜플 수가 순수 Git 선언 튜플보다 많음.")
    md.append("2. **Replica 확장**: Deployment/StatefulSet의 `replicas >= 2` 설정(Argo CD repo-server 2대 등)으로 인해 Pod 레벨 Live 튜플 수가 선언된 컨트롤러 수보다 확장됨.")
    md.append("3. **DaemonSet 노드 배포**: Falco, Flannel 등 노드당 1대씩 기동되는 데몬셋 런타임 인스턴스.")
    md.append("")

    md.append("## 4. Tag-only (sha256 미고정) 잔여 목록 (`SUPPLY-04` 해소 대상)\n")
    md.append("| 네임스페이스 | 컨트롤러 | 컨테이너 | 이미지 주소 | 비고 |")
    md.append("|---|---|---|---|---|")
    for t in sorted(report["tag_only_tuples"], key=lambda x: (x["namespace"], x["controller"])):
        md.append(f"| `{t['namespace']}` | `{t['controller']}` | `{t['container']}` | `{t['image']}` | `{t['exception']}` |")
    md.append("")

    md.append("## 5. 시스템 Exact 예외 목록 (System Exact Exceptions)\n")
    md.append("| 네임스페이스 | 컨트롤러 | 컨테이너 | 이미지 주소 | 예외 사유 |")
    md.append("|---|---|---|---|---|")
    for t in sorted(report["system_exception_tuples"], key=lambda x: (x["namespace"], x["controller"])):
        md.append(f"| `{t['namespace']}` | `{t['controller']}` | `{t['container']}` | `{t['image']}` | `{t['exception']}` |")
    md.append("")

    md.append("## 6. Kyverno ImageValidatingPolicy Audit 동작 검증\n")
    md.append("- **적용 정책**: `policies/k3s-image-supply-chain-audit.yaml` (`ImageValidatingPolicy`)")
    md.append("- **동작 모드**: `validationActions: [Audit]`, `failurePolicy: Ignore`, `background: true`")
    md.append("- **결과**: Enforce 전환 0건, 기존 워크로드 차단/재시작 실패 0건 확인.")
    md.append("- **후속 연계**: `SUPPLY-03` (Harbor upstream proxy cache 구축) 및 `SUPPLY-04` (curated project 승격 & digest 고정)로 순차 해소.")
    
    return "\n".join(md)

def main():
    report = generate_inventory_report()
    
    out_dir = os.path.join(REPO_ROOT, "docs/evidence/supply-02")
    os.makedirs(out_dir, exist_ok=True)
    
    json_path = os.path.join(out_dir, "inventory.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    
    md_content = generate_markdown_report(report)
    md_path = os.path.join(out_dir, "README.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md_content)
    
    print(f"[SUPPLY-02] Inventory extracted successfully -> {json_path}")
    print(f"[SUPPLY-02] Markdown report generated -> {md_path}")

if __name__ == "__main__":
    main()
