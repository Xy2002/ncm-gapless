"""Observe real, uninterrupted client playback; never seek, pause or change it."""
import argparse
import json
from pathlib import Path
import time
from check_source_access import value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--output", type=Path, default=Path(".local/natural-transition.json"))
    arguments = parser.parse_args()
    script = """(() => { const p=window.NcmGapless; if(!p?.installed)return {installed:false};const s=p.status();const c=window.NcmGaplessClient.discover(window);const state=c.getState();return {...s,track:window.__ncmGaplessAlbumFixture?.items.some(item=>item.track.name===state.playing.resourceName)?state.playing.resourceName:'other',appPlayingState:state.playing.playingState};})()"""
    samples = []
    started = time.monotonic()
    baseline = None
    success = False
    while time.monotonic() - started < arguments.timeout:
        status = value(arguments.port, script)
        status["elapsedSeconds"] = round(time.monotonic() - started, 3)
        samples.append(status)
        if baseline is None:
            baseline = status.get("transitions", 0)
            print(json.dumps({"started": True, "track": status.get("track"), "position": status.get("position"), "duration": status.get("duration")}), flush=True)
        if not status.get("installed") or status.get("errors", 0) or status.get("fallbacks", 0) or status.get("unpreparedEnds", 0):
            break
        if status.get("transitions", 0) > baseline and status.get("currentMatchesOfficial") and not status.get("waitingForOfficialHandoff"):
            success = status.get("lastBoundaryDeltaFrames") == 0 and status.get("playing") is True
            break
        time.sleep(1)
    report = {"pass": success, "observationOnly": True, "outputDeviceLoopbackRecorded": False,
              "samples": samples, "elapsedSeconds": round(time.monotonic() - started, 3)}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"pass": success, "samples": len(samples), "elapsedSeconds": report["elapsedSeconds"], "last": samples[-1]}, ensure_ascii=False), flush=True)
    raise SystemExit(0 if success else 1)


if __name__ == "__main__":
    main()
