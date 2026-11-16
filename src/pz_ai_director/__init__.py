from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def main() -> None:
    """Entry point for the `pz-ai-director` CLI script."""
    repo_server = Path(__file__).resolve().parents[2] / "server.py"
    if not repo_server.exists():
        raise FileNotFoundError(
            f"Could not locate server.py at {repo_server}. Run `uv run server.py` from the repository root."
        )
    spec = importlib.util.spec_from_file_location("pz_ai_director_server", repo_server)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Failed to load MCP server module from {repo_server}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.main()
