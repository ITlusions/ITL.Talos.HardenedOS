#!/usr/bin/env python3
"""
Generate Kyverno ClusterPolicy manifests from ITL PolicyBuilder.

Outputs a YAML manifest file ready for use as a Talos cluster.inlineManifest
(place it in flavors/controlplane-stack/manifests/).

Requires itl-policy-builder to be installed:
    pip install git+https://github.com/itlivetech/ITL.ControlPanel.PolicyBuilder.git
    # or locally:
    pip install -e d:/repos/ITL.ControlPanel.PolicyBuilder

Usage:
    python scripts/generate-kyverno-patch.py
    python scripts/generate-kyverno-patch.py --output flavors/controlplane-stack/manifests/10-kyverno-policies.yaml
    python scripts/generate-kyverno-patch.py --profile security
    python scripts/generate-kyverno-patch.py --profile talos
    python scripts/generate-kyverno-patch.py --profile all
    python scripts/generate-kyverno-patch.py --list
"""

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("[ERROR] PyYAML not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

try:
    from itl_policy_builder.templates.kyverno import (
        get_profile,
        get_profile_policies,
        list_profiles,
    )
except ImportError:
    print(
        "[ERROR] itl-policy-builder not found.\n"
        "Install with:\n"
        "  pip install git+https://github.com/itlivetech/ITL.ControlPanel.PolicyBuilder.git\n"
        "  # or locally:\n"
        "  pip install -e d:/repos/ITL.ControlPanel.PolicyBuilder",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _generate_manifest(profile_name: str) -> str:
    """Generate a multi-document YAML manifest for the given profile."""
    profile = get_profile(profile_name)
    policies = profile.policies

    docs: list[str] = [
        "# ITL Kyverno ClusterPolicy Manifests",
        f"# Profile   : {profile.display_name}",
        f"# Generated : by scripts/generate-kyverno-patch.py",
        f"# Source    : ITL.ControlPanel.PolicyBuilder",
        "#",
        f"# Description: {profile.description}",
        "#",
        "# NOTE: Kyverno must be installed before these policies take effect.",
        "#   Install Kyverno: https://kyverno.io/docs/installation/",
        "#   Recommended: add kyverno via flavors/controlplane-stack or a Helm release.",
        "",
    ]

    for policy_dict in policies:
        docs.append("---")
        docs.append(yaml.dump(policy_dict, default_flow_style=False, allow_unicode=True).rstrip())
        docs.append("")

    return "\n".join(docs)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    available_profiles = list_profiles()

    parser = argparse.ArgumentParser(
        description="Generate Kyverno ClusterPolicy manifests from ITL PolicyBuilder"
    )
    parser.add_argument(
        "--profile", "-p",
        default="security",
        choices=available_profiles,
        help="Policy profile to generate (default: security)",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="Output file path (default: stdout). "
             "Typical: flavors/controlplane-stack/manifests/10-kyverno-policies.yaml",
    )
    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="List available profiles and policies",
    )
    args = parser.parse_args()

    if args.list:
        print("Available profiles:\n")
        for name in available_profiles:
            profile = get_profile(name)
            print(f"  {name:10s}  {profile.description}")
            for policy_dict in profile.policies:
                pol_name = policy_dict.get("metadata", {}).get("name", "?")
                print(f"             - {pol_name}")
            print()
        return

    content = _generate_manifest(args.profile)
    profile = get_profile(args.profile)

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")
        print(f"[OK] Written {len(content.splitlines())} lines → {out}")
        print(f"     Profile  : {profile.display_name}")
        print(f"     Policies : {len(profile)}")
        print()
        print("Next steps:")
        print("  1. Commit the generated manifest")
        print("  2. talosctl gen config ... (manifest is picked up via cluster.inlineManifests patch)")
        print("  3. Ensure Kyverno is installed before policies are enforced")
    else:
        print(content)


if __name__ == "__main__":
    main()
