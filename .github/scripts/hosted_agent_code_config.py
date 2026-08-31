#!/usr/bin/env python3
"""Resolve hosted-agent code-deploy settings from a unified azure.yaml manifest."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable

try:
    import yaml
except ImportError:  # pragma: no cover - exercised by the CLI error path
    yaml = None


class CodeConfigError(ValueError):
    """Raised when a hosted-agent code configuration cannot be resolved."""


def _mapping(value: Any, *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CodeConfigError(f"{label} must be a mapping")
    return value


def resolve_code_config(
    manifest: Path,
    *,
    default_runtime: str,
    default_entry_point: str,
) -> dict[str, str]:
    """Return runtime and entry point, preferring the manifest over fallbacks."""
    if yaml is None:
        raise CodeConfigError("PyYAML is required; install it with 'pip install PyYAML'")

    try:
        document = yaml.safe_load(manifest.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise CodeConfigError(f"cannot read {manifest}: {error}") from error

    root = _mapping(document, label="azure.yaml document")
    services = _mapping(root.get("services"), label="services")
    hosted_services = [
        _mapping(service, label=f"services.{name}")
        for name, service in services.items()
        if isinstance(service, dict) and service.get("host") == "azure.ai.agent"
    ]
    if len(hosted_services) != 1:
        raise CodeConfigError(
            "azure.yaml must define exactly one service with host: azure.ai.agent"
        )

    code_config = hosted_services[0].get("codeConfiguration") or {}
    code_config = _mapping(code_config, label="codeConfiguration")
    runtime = code_config.get("runtime") or default_runtime
    entry_point = code_config.get("entryPoint") or default_entry_point
    if not isinstance(runtime, str) or not runtime.strip():
        raise CodeConfigError("codeConfiguration.runtime must be a non-empty string")
    if not isinstance(entry_point, str) or not entry_point.strip():
        raise CodeConfigError("codeConfiguration.entryPoint must be a non-empty string")

    return {"runtime": runtime, "entry_point": entry_point}


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--default-runtime", required=True)
    parser.add_argument("--default-entry-point", required=True)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        config = resolve_code_config(
            args.manifest,
            default_runtime=args.default_runtime,
            default_entry_point=args.default_entry_point,
        )
    except CodeConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(config))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
