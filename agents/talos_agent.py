"""
ITL Talos HardenedOS Agent
Deployment and customization assistant for ITL Talos HardenedOS clusters.

Tools cover the full lifecycle:
  - Connectivity checks
  - Config generation (with all ITL hardening patches)
  - Config apply + bootstrap
  - Cluster verification
  - Patch and flavor inspection
  - Doc lookup
  - Branding customisation advice
  - BrainCell memory (optional)

Usage:
    python talos_agent.py
    python talos_agent.py --question "How do I add a third worker node?"
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from langchain.agents import AgentExecutor, create_react_agent
from langchain.prompts import PromptTemplate
from langchain.tools import tool
from langchain_openai import ChatOpenAI

# ── Optional BrainCell import ─────────────────────────────────────────────
try:
    sys.path.insert(0, str(Path(__file__).parent.parent.parent / "ITL.Agents"))
    from braincell_client import BrainCellClient  # type: ignore

    _braincell_available = True
except ImportError:
    _braincell_available = False

load_dotenv()

# ── Paths ─────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).parent.parent
PATCHES_DIR = REPO_ROOT / "config" / "patches"
FLAVORS_DIR = REPO_ROOT / "flavors"
DOCS_DIR = REPO_ROOT / "docs"
GENERATED_DIR = REPO_ROOT / "config" / "generated"
ISO_DIR = REPO_ROOT / "iso-download"

# ── LLM ──────────────────────────────────────────────────────────────────
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
BRAINCELL_URL = os.getenv("BRAINCELL_API_URL", "http://localhost:9504")

llm = ChatOpenAI(
    api_key=OPENAI_API_KEY,
    model=os.getenv("AGENT_MODEL", "gpt-4o"),
    temperature=0.2,
)

# ── BrainCell client (optional) ───────────────────────────────────────────
braincell: Optional[Any] = None
if _braincell_available:
    braincell = BrainCellClient(
        base_url=BRAINCELL_URL,
        api_key=os.getenv("BRAINCELL_API_KEY"),
    )


# ─────────────────────────────────────────────────────────────────────────
# TOOLS
# ─────────────────────────────────────────────────────────────────────────


@tool
def check_node_connectivity(nodes: str) -> str:
    """
    Check whether Talos maintenance API (port 50000) is reachable for one or
    more nodes.  Pass a comma-separated list of IP addresses.

    Example: check_node_connectivity("192.168.1.100,192.168.1.101,192.168.1.102")
    """
    results = []
    for ip in [n.strip() for n in nodes.split(",") if n.strip()]:
        try:
            result = subprocess.run(
                ["talosctl", "version", "--nodes", ip, "--endpoints", ip, "--insecure"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                results.append(f"  [OK] {ip} — reachable (Talos maintenance API)")
            else:
                results.append(
                    f"  [FAIL] {ip} — {result.stderr.strip() or 'no response on port 50000'}"
                )
        except FileNotFoundError:
            return "talosctl not found in PATH. Install talosctl v1.9.0+ first."
        except subprocess.TimeoutExpired:
            results.append(f"  [TIMEOUT] {ip} — no response after 10 s")
    return "\n".join(results)


@tool
def list_available_patches(verbose: str = "false") -> str:
    """
    List all patch files available in config/patches/.
    Set verbose='true' to include the first 5 lines of each patch.
    """
    patches = sorted(PATCHES_DIR.glob("*.yaml"))
    if not patches:
        return "No patch files found in config/patches/"

    lines = []
    for p in patches:
        lines.append(f"  {p.name}")
        if verbose.lower() == "true":
            content = p.read_text(encoding="utf-8").splitlines()
            preview = "\n".join(f"    {l}" for l in content[:5])
            lines.append(preview)

    return "Patches in config/patches/:\n" + "\n".join(lines)


@tool
def read_patch(patch_name: str) -> str:
    """
    Read the full content of a patch file from config/patches/.
    patch_name should be the filename, e.g. 'security-hardening.yaml'.
    """
    path = PATCHES_DIR / patch_name
    if not path.exists():
        available = ", ".join(p.name for p in sorted(PATCHES_DIR.glob("*.yaml")))
        return f"Patch '{patch_name}' not found. Available: {available}"
    return path.read_text(encoding="utf-8")


@tool
def list_available_flavors() -> str:
    """
    List the deployment flavors in the flavors/ directory.
    Flavors are curated patch sets for specific deployment scenarios
    (e.g. controlplane-stack).
    """
    if not FLAVORS_DIR.exists():
        return "flavors/ directory not found"

    output = []
    for flavor_dir in sorted(FLAVORS_DIR.iterdir()):
        if flavor_dir.is_dir():
            readme = flavor_dir / "README.md"
            if readme.exists():
                first_line = readme.read_text(encoding="utf-8").splitlines()[2]
                output.append(f"  {flavor_dir.name}  —  {first_line}")
            else:
                output.append(f"  {flavor_dir.name}")
    return "Available flavors:\n" + "\n".join(output)


@tool
def read_flavor_patches(flavor_name: str) -> str:
    """
    List and show the patches for a specific flavor.
    Example: read_flavor_patches("controlplane-stack")
    """
    flavor_path = FLAVORS_DIR / flavor_name / "patches"
    if not flavor_path.exists():
        available = [d.name for d in FLAVORS_DIR.iterdir() if d.is_dir()]
        return f"Flavor '{flavor_name}' not found. Available: {', '.join(available)}"

    output = [f"Patches for flavor '{flavor_name}':"]
    for patch in sorted(flavor_path.glob("*.yaml")):
        output.append(f"\n── {patch.name} ──")
        output.append(patch.read_text(encoding="utf-8"))
    return "\n".join(output)


@tool
def list_docs() -> str:
    """
    List available documentation files in docs/.
    """
    docs = sorted(DOCS_DIR.glob("*.md"))
    if not docs:
        return "No docs found"
    return "Docs:\n" + "\n".join(f"  {d.name}" for d in docs)


@tool
def read_doc(doc_name: str) -> str:
    """
    Read a documentation file from docs/.
    doc_name is the filename, e.g. '08-BAREMETAL-CLUSTER-WALKTHROUGH.md'.
    To see what's available, call list_docs first.
    """
    path = DOCS_DIR / doc_name
    if not path.exists():
        available = ", ".join(d.name for d in sorted(DOCS_DIR.glob("*.md")))
        return f"Doc '{doc_name}' not found. Available:\n  {available}"
    return path.read_text(encoding="utf-8")


@tool
def generate_cluster_config(
    cluster_name: str,
    control_plane_ip: str,
    output_dir: str = "",
    extra_patches: str = "",
    enable_oidc: str = "false",
    flavor: str = "",
) -> str:
    """
    Generate Talos MachineConfig files for a cluster using all standard ITL
    hardening patches (security-hardening + network-hardening + branding).

    Args:
        cluster_name: Name for the cluster, e.g. 'itl'
        control_plane_ip: IP or hostname of the control plane node
        output_dir: Where to write the generated files (default: config/generated/<cluster_name>)
        extra_patches: Comma-separated list of additional patch filenames from config/patches/
        enable_oidc: 'true' to also apply oidc-patch.yaml (requires live Keycloak)
        flavor: Optional flavor name to include all flavor patches (e.g. 'controlplane-stack')

    Returns:
        Shell command to run, plus explanation
    """
    out = output_dir or str(GENERATED_DIR / cluster_name)

    # Base patches always applied
    patch_flags = [
        f"--config-patch @{PATCHES_DIR / 'security-hardening.yaml'}",
        f"--config-patch @{PATCHES_DIR / 'network-hardening.yaml'}",
        f"--config-patch @{PATCHES_DIR / 'branding-patch.yaml'}",
    ]

    if enable_oidc.lower() == "true":
        patch_flags.append(f"--config-patch @{PATCHES_DIR / 'oidc-patch.yaml'}")

    if extra_patches:
        for ep in extra_patches.split(","):
            ep = ep.strip()
            if ep:
                patch_flags.append(f"--config-patch @{PATCHES_DIR / ep}")

    if flavor:
        flavor_patch_dir = FLAVORS_DIR / flavor / "patches"
        if flavor_patch_dir.exists():
            for fp in sorted(flavor_patch_dir.glob("*.yaml")):
                patch_flags.append(f"--config-patch @{fp}")
        else:
            return f"Flavor '{flavor}' not found or has no patches directory."

    patches_joined = " \\\n    ".join(patch_flags)
    cmd = (
        f"talosctl gen config {cluster_name} https://{control_plane_ip}:6443 \\\n"
        f"    --output {out} \\\n"
        f"    {patches_joined} \\\n"
        f"    --force"
    )

    explanation = [
        f"Generated config command for cluster '{cluster_name}':",
        f"  Control plane endpoint : https://{control_plane_ip}:6443",
        f"  Output directory       : {out}",
        f"  Patches applied        : security-hardening, network-hardening, branding",
    ]
    if enable_oidc.lower() == "true":
        explanation.append("                           + oidc (Keycloak)")
    if extra_patches:
        explanation.append(f"                           + {extra_patches}")
    if flavor:
        explanation.append(f"                           + flavor: {flavor}")

    explanation += [
        "",
        "Run this command from the repo root:",
        "",
        cmd,
        "",
        "Output files:",
        f"  {out}/controlplane.yaml  → apply to the control plane node",
        f"  {out}/worker.yaml        → apply to each worker node",
        f"  {out}/talosconfig        → your talosctl credentials",
    ]

    return "\n".join(explanation)


@tool
def apply_node_config(node_ip: str, config_path: str, insecure: str = "true") -> str:
    """
    Apply a Talos MachineConfig to a node.

    Args:
        node_ip: IP address of the target node
        config_path: Path to the YAML config file (controlplane.yaml or worker.yaml)
        insecure: 'true' for first-time apply (node has no cert yet); 'false' after bootstrap

    Returns:
        Result of the talosctl apply-config command
    """
    p = Path(config_path)
    if not p.exists():
        return f"Config file not found: {config_path}"

    cmd = [
        "talosctl", "apply-config",
        "--nodes", node_ip,
        "--file", str(p),
    ]
    if insecure.lower() == "true":
        cmd.append("--insecure")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            return (
                f"[OK] Config applied to {node_ip}.\n"
                "The node will now install Talos to disk and reboot. "
                "Remove the USB drive after the first reboot."
            )
        return f"[FAIL] apply-config returned {result.returncode}:\n{result.stderr}"
    except FileNotFoundError:
        return "talosctl not found in PATH."
    except subprocess.TimeoutExpired:
        return f"[TIMEOUT] apply-config to {node_ip} timed out after 60 s."


@tool
def bootstrap_cluster(control_plane_ip: str, talosconfig_path: str = "") -> str:
    """
    Bootstrap the Kubernetes control plane (etcd + kube-apiserver).
    Run exactly ONCE on the first control plane node.

    Args:
        control_plane_ip: IP of the control plane node
        talosconfig_path: Path to talosconfig (default: config/generated/itl/talosconfig)
    """
    tc = talosconfig_path or str(GENERATED_DIR / "itl" / "talosconfig")
    cmd = [
        "talosctl", "bootstrap",
        "--nodes", control_plane_ip,
        "--endpoints", control_plane_ip,
        "--talosconfig", tc,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            return (
                f"[OK] Cluster bootstrapped via {control_plane_ip}.\n"
                "etcd is initialising. Wait ~3 min then run get_kubeconfig."
            )
        return f"[FAIL] bootstrap returned {result.returncode}:\n{result.stderr}"
    except FileNotFoundError:
        return "talosctl not found in PATH."
    except subprocess.TimeoutExpired:
        return "[TIMEOUT] bootstrap timed out. The CP may still be rebooting — retry in 60 s."


@tool
def get_kubeconfig(control_plane_ip: str, output_path: str = "", talosconfig_path: str = "") -> str:
    """
    Retrieve kubeconfig from the cluster and write it to a file.

    Args:
        control_plane_ip: IP of the control plane node
        output_path: Where to write kubeconfig (default: ./kubeconfig-itl)
        talosconfig_path: Path to talosconfig (default: config/generated/itl/talosconfig)
    """
    tc = talosconfig_path or str(GENERATED_DIR / "itl" / "talosconfig")
    out = output_path or str(REPO_ROOT / "kubeconfig-itl")

    cmd = [
        "talosctl", "kubeconfig", out,
        "--nodes", control_plane_ip,
        "--endpoints", control_plane_ip,
        "--talosconfig", tc,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return (
                f"[OK] kubeconfig written to {out}\n"
                f"Set env var:  $env:KUBECONFIG = '{out}'\n"
                "Then verify:  kubectl get nodes -o wide"
            )
        return f"[FAIL] kubeconfig returned {result.returncode}:\n{result.stderr}"
    except FileNotFoundError:
        return "talosctl not found in PATH."
    except subprocess.TimeoutExpired:
        return "[TIMEOUT] kubeconfig timed out. Is the API server ready yet?"


@tool
def get_cluster_health(control_plane_ip: str, talosconfig_path: str = "") -> str:
    """
    Run talosctl health to check cluster readiness.

    Args:
        control_plane_ip: IP of the control plane node
        talosconfig_path: Path to talosconfig
    """
    tc = talosconfig_path or str(GENERATED_DIR / "itl" / "talosconfig")
    cmd = [
        "talosctl", "health",
        "--nodes", control_plane_ip,
        "--endpoints", control_plane_ip,
        "--talosconfig", tc,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return result.stdout or result.stderr or "No output"
    except FileNotFoundError:
        return "talosctl not found in PATH."
    except subprocess.TimeoutExpired:
        return "[TIMEOUT] health check timed out. The cluster may still be bootstrapping."


@tool
def get_node_info(node_ip: str, info_type: str = "all", talosconfig_path: str = "") -> str:
    """
    Get information from a running Talos node.

    Args:
        node_ip: IP address of the node
        info_type: One of 'all', 'volumes', 'extensions', 'services', 'version'
            - volumes   → disk encryption status (LUKS2 partitions)
            - extensions → installed Talos extensions (branding, security, TPM)
            - services  → systemd-style service states
            - version   → Talos + Kubernetes versions
        talosconfig_path: Path to talosconfig
    """
    tc = talosconfig_path or str(GENERATED_DIR / "itl" / "talosconfig")
    base = ["talosctl", "--nodes", node_ip, "--endpoints", node_ip, "--talosconfig", tc]

    subcommands = {
        "volumes": base + ["get", "volumes"],
        "extensions": base + ["get", "extensions"],
        "services": base + ["services"],
        "version": base + ["version"],
    }

    if info_type == "all":
        results = []
        for name, cmd in subcommands.items():
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
                results.append(f"── {name.upper()} ──\n{r.stdout or r.stderr}")
            except Exception as e:
                results.append(f"── {name.upper()} ── ERROR: {e}")
        return "\n".join(results)

    if info_type not in subcommands:
        return f"Unknown info_type '{info_type}'. Use: {', '.join(subcommands.keys())} or 'all'"

    try:
        r = subprocess.run(subcommands[info_type], capture_output=True, text=True, timeout=20)
        return r.stdout or r.stderr or "No output"
    except FileNotFoundError:
        return "talosctl not found in PATH."
    except subprocess.TimeoutExpired:
        return f"[TIMEOUT] {info_type} query timed out."


@tool
def list_iso_files() -> str:
    """
    List ISO files available in the iso-download/ and iso-output/ directories.
    """
    results = []
    for d in ["iso-download", "iso-output"]:
        p = REPO_ROOT / d
        if p.exists():
            isos = list(p.glob("*.iso"))
            if isos:
                results.append(f"{d}/:")
                for iso in sorted(isos):
                    size_mb = iso.stat().st_size // (1024 * 1024)
                    results.append(f"  {iso.name}  ({size_mb} MB)")
            else:
                results.append(f"{d}/: (empty — build or download an ISO first)")
        else:
            results.append(f"{d}/: directory not found")
    return "\n".join(results) or "No ISO directories found"


@tool
def get_branding_info() -> str:
    """
    Show the current branding configuration: banner text, console issue content,
    and instructions for customising it.
    """
    output = []

    branding_patch = PATCHES_DIR / "branding-patch.yaml"
    if branding_patch.exists():
        output.append("── Current branding patch (config/patches/branding-patch.yaml) ──")
        output.append(branding_patch.read_text(encoding="utf-8")[:1500])

    banner_template = REPO_ROOT / "branding" / "templates" / "banner-header.txt"
    if banner_template.exists():
        output.append("\n── Banner template (branding/templates/banner-header.txt) ──")
        output.append(banner_template.read_text(encoding="utf-8"))

    output.append("\n── How to customise ──")
    output.append(
        "1. Edit config/patches/branding-patch.yaml — change the /etc/issue content directly.\n"
        "2. Edit branding/templates/banner-header.txt — used by build.sh to regenerate the banner.\n"
        "3. Replace branding/logos/ files with your own PNG (512×512 recommended) for the boot splash.\n"
        "4. Run .\\build-iso.ps1 to rebuild the ISO with new branding baked in.\n"
        "5. Re-apply the branding-patch.yaml after a config re-generation if you changed the\n"
        "   patch content without rebuilding the ISO."
    )
    return "\n".join(output)


@tool
def get_deployment_checklist(scenario: str = "baremetal") -> str:
    """
    Return a deployment checklist for a given scenario.

    Args:
        scenario: One of 'baremetal', 'hyperv', 'ztp' (Zero-Touch Provisioning)
    """
    checklists = {
        "baremetal": """
Bare Metal Deployment Checklist (3 nodes: 1 CP + 2 Workers)
─────────────────────────────────────────────────────────────
 Pre-flight
  [ ] talosctl v1.9.0+ installed on admin machine
  [ ] kubectl v1.29.0+ installed on admin machine
  [ ] ISO present in iso-download/ (or built via .\\build-iso.ps1)
  [ ] USB drives flashed with Rufus (GPT/UEFI) or dd
  [ ] Secure Boot DISABLED on each machine
  [ ] USB boot priority set in BIOS
  [ ] All 3 machines powered on and showing Talos maintenance screen
  [ ] Admin machine on same LAN, port 50000 reachable

 Config generation
  [ ] Run: talosctl gen config ... with all 3 patches
  [ ] Verify controlplane.yaml + worker.yaml + talosconfig in output dir

 Apply
  [ ] talosctl apply-config --insecure to CP (192.168.1.100)
  [ ] talosctl apply-config --insecure to W1 (192.168.1.101)
  [ ] talosctl apply-config --insecure to W2 (192.168.1.102)
  [ ] Wait for all 3 nodes to reboot from disk
  [ ] Remove USB drives

 Bootstrap
  [ ] talosctl bootstrap (once, on CP only)
  [ ] Wait ~3 min for API server to start

 Verify
  [ ] talosctl kubeconfig
  [ ] kubectl get nodes -o wide → all 3 nodes Ready
  [ ] talosctl health → all checks passing
  [ ] talosctl get volumes → LUKS2 encryption confirmed on STATE + EPHEMERAL
  [ ] talosctl get extensions → itl-branding, itl-security visible

 Optional
  [ ] -EnableOidc $true (if Keycloak is live at auth.itlusions.com)
  [ ] Apply flavor patches (e.g. controlplane-stack) for full ITL stack

See docs/08-BAREMETAL-CLUSTER-WALKTHROUGH.md for the full walkthrough.""",
        "hyperv": """
Hyper-V Development Cluster Checklist
──────────────────────────────────────
  [ ] Hyper-V enabled (Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V)
  [ ] ISO present in iso-download/
  [ ] Run: .\\setup-cluster.ps1

The script automatically:
  - Creates 3 Gen2 VMs (itl-cp1, itl-w1, itl-w2) with 2 GB RAM, 40 GB VHD
  - Disables Secure Boot
  - Attaches ISO + starts VMs
  - Waits for DHCP IPs to appear
  - Runs all config gen → apply → bootstrap → kubeconfig steps""",
        "ztp": """
Zero-Touch Provisioning Checklist
───────────────────────────────────
  [ ] Registration Service running: cd provisioner && docker compose up -d
  [ ] Configs downloaded: docker compose exec registration /bin/sh -c "/app/scripts/download-configs.sh v1.9.0"
  [ ] Machines pre-registered with EK fingerprint (talosctl + TPM read)
  [ ] USB agent built: cd provisioner/usb-agent && .\\build-usb.sh /dev/sdX
  [ ] USB inserted into new machine
  ZTP flow (~10 min per node, zero operator input after USB insert):
    1. Machine boots Alpine USB agent
    2. TPM EK fingerprint read → POST /api/v1/machines/register
    3. Registration Service auto-approves (if policy matches) → returns role + ISO URL
    4. ISO downloaded + dd'd to disk
    5. First Talos boot → fetches MachineConfig token → applies patches → reboots
    6. TPM PCR attestation → machine transitions to 'attested'
  [ ] Verify: curl /api/v1/machines | jq '.[] | {hostname,status}'""",
    }

    result = checklists.get(scenario)
    if not result:
        return f"Unknown scenario '{scenario}'. Available: {', '.join(checklists.keys())}"
    return result


@tool
def run_automated_script(script_name: str, args: str = "") -> str:
    """
    Run one of the ITL Talos helper scripts.

    Args:
        script_name: One of 'setup-cluster-baremetal', 'setup-cluster' (Hyper-V), 'build-iso'
        args: Additional PowerShell arguments, e.g. '-CpIp 192.168.1.100 -W1Ip 192.168.1.101 -W2Ip 192.168.1.102'

    Returns:
        The command to run (does not execute automatically — requires user confirmation for
        destructive operations like wiping disks).
    """
    scripts = {
        "setup-cluster-baremetal": REPO_ROOT / "setup-cluster-baremetal.ps1",
        "setup-cluster": REPO_ROOT / "setup-cluster.ps1",
        "build-iso": REPO_ROOT / "build-iso.ps1",
    }

    if script_name not in scripts:
        return f"Unknown script '{script_name}'. Available: {', '.join(scripts.keys())}"

    script_path = scripts[script_name]
    if not script_path.exists():
        return f"Script not found at {script_path}"

    cmd = f"pwsh -File {script_path}"
    if args.strip():
        cmd += f" {args}"

    return (
        f"Command to run:\n\n  {cmd}\n\n"
        f"WARNING: This will write to physical disks / create VMs. "
        f"Confirm with the user before executing."
    )


# ── BrainCell tools (only registered if BrainCell is importable) ──────────

def _braincell_search(query: str) -> str:
    """Search BrainCell for prior cluster decisions and deployment notes."""
    if not braincell:
        return "BrainCell not available (optional dependency). Skipping memory search."
    result = braincell.search(query, limit=5)
    if result.success:
        items = result.data.get("results", [])
        if items:
            return "BrainCell results:\n" + "\n".join(
                f"  - {i.get('content', '')}" for i in items
            )
        return "No prior decisions found in BrainCell for this query."
    return f"BrainCell error: {result.error}"


def _braincell_store_decision(
    decision_id: str, title: str, context: str, decision: str,
    rationale: str, tags: str,
) -> str:
    """Store a cluster/deployment decision in BrainCell for future reference."""
    if not braincell:
        return "BrainCell not available."
    result = braincell.store_decision(
        decision_id=decision_id,
        title=title,
        context=context,
        decision=decision,
        rationale=rationale,
        tags=tags.split(",") + ["talos", "itl-talos-hardened-os"],
    )
    if result.success:
        return f"[OK] Decision '{decision_id} — {title}' stored in BrainCell."
    return f"BrainCell error: {result.error}"


braincell_search = tool(_braincell_search)
braincell_search.name = "braincell_search"
braincell_search.description = (
    "Search BrainCell for prior cluster decisions and deployment notes. "
    "Input: search query string."
)

braincell_store = tool(_braincell_store_decision)
braincell_store.name = "braincell_store_decision"
braincell_store.description = (
    "Store a cluster or deployment decision in BrainCell. "
    "Inputs: decision_id, title, context, decision, rationale, tags (comma-separated)."
)


# ─────────────────────────────────────────────────────────────────────────
# SYSTEM PROMPT
# ─────────────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are TalosOps, the expert deployment and customisation assistant for
ITL Talos HardenedOS — an enterprise-grade, security-hardened Kubernetes operating system
built by ITLusions on top of Talos Linux v1.9.

─── What you know ──────────────────────────────────────────────────────────

REPOSITORY LAYOUT
  config/patches/        — MachineConfig patch files applied at provision time
  config/generated/      — Output of talosctl gen config (not committed)
  flavors/               — Purpose-built patch stacks for specific deployments
  docs/                  — Complete documentation (01..08)
  iso-download/          — Pre-built ISOs
  iso-output/            — Locally-built ISO output
  branding/              — Console banner templates and boot logos
  extensions/            — Custom Talos extension Dockerfiles (branding, security, TPM)
  provisioner/           — Zero-Touch Provisioning service (FastAPI + USB Alpine agent)
  setup-cluster-baremetal.ps1  — Automated bare metal setup script (8 steps)
  setup-cluster.ps1            — Automated Hyper-V development cluster script
  build-iso.ps1                — ISO build script (Docker-based)

PATCHES (config/patches/)
  security-hardening.yaml   — LUKS2+TPM2 disk encryption (STATE + EPHEMERAL), kubelet CIS
                              hardening, kernel sysctls (ptrace scope 2, BPF disabled,
                              IPv6 disabled, TCP SYN cookies), SSH key-only auth, audit log
  network-hardening.yaml    — DNS (1.1.1.1/8.8.8.8), NTP (Cloudflare+pool.ntp.org),
                              kube-proxy iptables, etcd metrics on localhost only
  branding-patch.yaml       — ITLusions ASCII banner on /etc/issue and /etc/motd
  oidc-patch.yaml           — Keycloak OIDC on kube-apiserver
                              (issuer: https://auth.itlusions.com/realms/itl,
                               client: talos-cluster)

FLAVORS (flavors/)
  controlplane-stack/    — Adds Cilium CNI, Nginx Ingress, local-path-provisioner,
                           default namespaces (itl-controlplane, itl-monitoring, itl-ingress),
                           RBAC for itl-platform-admins/viewers, registry mirrors,
                           node labels (itl.io/role: infra or app)

DEPLOYMENT SCENARIOS
  Bare metal   — 3 nodes (1 CP + 2 workers), USB boot, DHCP or static IPs
                 Full script: .\setup-cluster-baremetal.ps1
  Hyper-V      — Local development, 3 VMs auto-created
                 Full script: .\setup-cluster.ps1
  ZTP          — Zero-Touch Provisioning via USB Alpine agent + Registration Service
                 TPM EK fingerprint identity, PCR attestation, auto-approval policies

KEY DISTINCTION
  The ISO contains: boot loader, ITL-branded kernel, splash screen, installer.
  The ISO does NOT apply hardening — hardening is applied as MachineConfig patches
  via talosctl apply-config. Always apply all patches.

TOOLS AVAILABLE
  check_node_connectivity   — verify port 50000 on nodes
  list_available_patches    — list patches in config/patches/
  read_patch                — read full patch YAML
  list_available_flavors    — list deployment flavors
  read_flavor_patches       — read all patches for a flavor
  list_docs / read_doc      — browse and read documentation
  generate_cluster_config   — produce the talosctl gen config command with correct patches
  apply_node_config         — run talosctl apply-config on a node
  bootstrap_cluster         — run talosctl bootstrap (once, on CP)
  get_kubeconfig            — retrieve kubeconfig from cluster
  get_cluster_health        — run talosctl health
  get_node_info             — volumes / extensions / services / version per node
  list_iso_files            — list available ISOs
  get_branding_info         — show and explain branding customisation
  get_deployment_checklist  — step-by-step checklist per scenario
  run_automated_script      — show the command for a helper script
  braincell_search          — search prior decisions (optional)
  braincell_store_decision  — record a decision (optional)

─── How you behave ─────────────────────────────────────────────────────────

1. When an engineer asks HOW to do something, prefer showing exact commands
   over lengthy explanations. Use code blocks.

2. When they ask WHAT to do, use get_deployment_checklist to show a structured plan.

3. Before generating configs, confirm the cluster name and control-plane IP.

4. NEVER suggest skipping security-hardening.yaml or network-hardening.yaml.
   These are always applied. oidc-patch.yaml is optional (requires live Keycloak).

5. For destructive operations (apply-config, bootstrap, disk wipe), always
   state what will happen and ask for confirmation before proceeding.

6. When troubleshooting, gather info first:
     check_node_connectivity → get_node_info → get_cluster_health
   then diagnose.

7. If BrainCell is available, search it for prior decisions before answering
   architecture questions.

8. Always cite the relevant doc file when it covers the question, e.g.:
   "See docs/08-BAREMETAL-CLUSTER-WALKTHROUGH.md for the full walkthrough."

{agent_scratchpad}"""

REACT_TEMPLATE = (
    SYSTEM_PROMPT
    + """

Question: {input}

You have access to these tools:
{tools}

Tool names: {tool_names}

Use this format:
Thought: <your reasoning>
Action: <tool_name>
Action Input: <tool input>
Observation: <result>
... (repeat as needed)
Thought: I now know the final answer
Final Answer: <your answer>

Begin!"""
)


# ─────────────────────────────────────────────────────────────────────────
# AGENT FACTORY
# ─────────────────────────────────────────────────────────────────────────


def build_tools() -> list:
    tools = [
        check_node_connectivity,
        list_available_patches,
        read_patch,
        list_available_flavors,
        read_flavor_patches,
        list_docs,
        read_doc,
        generate_cluster_config,
        apply_node_config,
        bootstrap_cluster,
        get_kubeconfig,
        get_cluster_health,
        get_node_info,
        list_iso_files,
        get_branding_info,
        get_deployment_checklist,
        run_automated_script,
        braincell_search,
        braincell_store,
    ]
    return tools


def create_talos_agent() -> AgentExecutor:
    tools = build_tools()
    prompt = PromptTemplate.from_template(REACT_TEMPLATE)
    agent = create_react_agent(llm, tools, prompt)
    return AgentExecutor(
        agent=agent,
        tools=tools,
        verbose=True,
        max_iterations=15,
        handle_parsing_errors=True,
    )


# ─────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────

BANNER = """
╔══════════════════════════════════════════════════════════════════╗
║  TalosOps — ITL Talos HardenedOS Deployment Assistant           ║
║  Talos v1.9  •  LUKS2+TPM2  •  CIS Hardened  •  OIDC Ready     ║
╚══════════════════════════════════════════════════════════════════╝
Type your question, or 'quit' to exit.
"""


def run_interactive(agent: AgentExecutor) -> None:
    print(BANNER)
    while True:
        try:
            question = input("TalosOps> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye.")
            break

        if not question:
            continue
        if question.lower() in {"quit", "exit", "q"}:
            print("Bye.")
            break

        try:
            response = agent.invoke({"input": question})
            print(f"\n{response.get('output', 'No response')}\n")
        except Exception as exc:
            print(f"[ERROR] {exc}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="ITL Talos HardenedOS Agent")
    parser.add_argument("--question", "-q", help="Single question (non-interactive mode)")
    args = parser.parse_args()

    if not OPENAI_API_KEY:
        sys.exit(
            "ERROR: OPENAI_API_KEY is not set.\n"
            "Copy agents/.env.example to agents/.env and fill in your key."
        )

    agent = create_talos_agent()

    if args.question:
        response = agent.invoke({"input": args.question})
        print(response.get("output", "No response"))
    else:
        run_interactive(agent)


if __name__ == "__main__":
    main()
