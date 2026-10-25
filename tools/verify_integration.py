"""Render the actual engine and check official event contracts without sound."""
import argparse
import json
from pathlib import Path
from check_source_access import value

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    arguments = parser.parse_args()
    source = "\n".join((ROOT / "src" / name).read_text(encoding="utf-8") for name in ("client-adapter.js", "gapless-engine.js"))
    suite = (ROOT / "tests" / "engine-audio.js").read_text(encoding="utf-8")
    script = "(async()=>{const previousClient=window.NcmGaplessClient,previousEngine=window.NcmGaplessEngine;try{\n" + source + "\n" + suite + "\nreturn await verifyEngineAndAdapter(window.NcmGaplessEngine,window.NcmGaplessClient);" + "}catch(error){const message=String(error?.message||'');return {pass:false,failure:/^(adjacent|cancel-queued|seek|pause-resume|same-rate-during-second-track) altered rendered PCM: [0-9.e+-]+$/.test(message)||message==='Regression must reach the second track'?message:'INTEGRATION_TEST_FAILED'};}finally{window.NcmGaplessClient=previousClient;window.NcmGaplessEngine=previousEngine;}})()"
    report = value(arguments.port, script)
    (ROOT / ".local" / "integration-proof.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report["pass"] else 1)


if __name__ == "__main__":
    main()
