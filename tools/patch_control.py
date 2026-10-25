"""Development install/status/disable through the official client's local CDP.

All injected code comes from this repository. No account or music is exported.
"""
import argparse
import json
from pathlib import Path

from check_source_access import value

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "disable", "native-baseline"))
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--activate", action="store_true")
    arguments = parser.parse_args()
    if arguments.action == "install":
        code = "\n".join((ROOT / "src" / name).read_text(encoding="utf-8") for name in (
            "client-adapter.js", "aac-timing.js", "gapless-engine.js", "netease-gapless.js"))
        code += "\n;if (!window.NcmGapless.installed) window.NcmGapless.install();"
        if arguments.activate:
            code += "\n;window.NcmGapless.activateCurrent();"
        code += "\n;window.NcmGapless.status();"
    elif arguments.action == "status":
        code = "window.NcmGapless?.status?.() || {installed:false}"
    elif arguments.action == "disable":
        code = "window.NcmGapless?.uninstall ? window.NcmGapless.uninstall() : ({installed:false})"
    else:
        code = (ROOT / "src" / "client-adapter.js").read_text(encoding="utf-8")
        code += "\n;" + (ROOT / "tools" / "dawn-fm-native-baseline.js").read_text(encoding="utf-8")
    print(json.dumps(value(arguments.port, code, user_gesture=arguments.action != "status"), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
