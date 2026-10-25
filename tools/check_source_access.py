"""Fail unless a clean official-client source reaches decoded PCM.

Captures only capability booleans, HTTP status, and frame counts. No URLs,
account data, headers values, or music are written to disk.
"""

import argparse
import json
from pathlib import Path

from cdp_probe import evaluate

ROOT = Path(__file__).resolve().parents[1]


def value(port, expression, *, user_gesture=False):
    raw = evaluate(port, expression, user_gesture=user_gesture)
    result = raw.get("result", {})
    if "exceptionDetails" in result or "value" not in result.get("result", {}):
        raise RuntimeError("CDP evaluation failed; inspect locally without exporting target content")
    return result["result"]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--output", type=Path, default=ROOT / ".local" / "source-check.json")
    arguments = parser.parse_args()
    old_patch = value(arguments.port, "Boolean(window.__ncmGapless)")
    if old_patch:
        report = {"pass": False, "reason": "previous-patch-still-in-memory"}
    else:
        value(arguments.port, (ROOT / "tools" / "inspect-modules.js").read_text(encoding="utf-8"))
        try:
            report = value(arguments.port, (ROOT / "tools" / "probe-authorized-source.js").read_text(encoding="utf-8"))
            report["pass"] = report.get("browserDecoded") is True and report.get("frames", 0) > 0
        finally:
            value(arguments.port, "(() => { delete window.__ncmGaplessProbeRequire; return true; })()")
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report["pass"] else 1)


if __name__ == "__main__":
    main()
