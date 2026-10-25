"""Exercise official pause/resume/seek against the active experimental player."""
import argparse
import json
from pathlib import Path
import time
from check_source_access import value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    arguments = parser.parse_args()
    read = lambda: value(arguments.port, "window.NcmGapless.status()")
    initial = read()
    if not initial.get("active") or not initial.get("playing"):
        raise RuntimeError("Start an authorized album track first")
    pause = "window.NcmGaplessClient.discover(window).store.dispatch({type:'playing/pause',payload:{triggerScene:'unknown'}});true"
    resume = "window.NcmGaplessClient.discover(window).store.dispatch({type:'playing/resume',payload:{triggerScene:'unknown'}});true"
    value(arguments.port, pause, user_gesture=True)
    time.sleep(0.25)
    a = read()
    time.sleep(0.5)
    b = read()
    assert not a["playing"] and not b["playing"] and abs(a["position"] - b["position"]) < 1 / a["sampleRate"], "Pause did not freeze the audio clock"
    value(arguments.port, resume, user_gesture=True)
    time.sleep(0.4)
    resumed = read()
    assert resumed["playing"] and resumed["position"] > b["position"], "Resume did not advance"
    value(arguments.port, pause, user_gesture=True)
    time.sleep(0.2)
    seek = """(async()=>{const c=window.NcmGaplessClient.discover(window);const p=c.getState().playing.playId;return await Promise.race([c.sdk.AudioPlayer.seek({playId:p,seekId:'gapless-control-test',value:10}),new Promise((r,j)=>setTimeout(()=>j(new Error('SEEK_TIMEOUT')),3000))]);})()"""
    result = value(arguments.port, seek, user_gesture=True)
    paused_seek = read()
    assert result.get("code") == 0 and abs(paused_seek["position"] - 10) < 0.02 and not paused_seek["playing"], "Paused seek failed or unexpectedly played"
    value(arguments.port, resume, user_gesture=True)
    time.sleep(0.4)
    final = read()
    assert final["playing"] and final["position"] > 10 and final["currentMatchesOfficial"], "Seek/resume lost official synchronization"
    report = {"pass": True, "cases": ["pause-freezes-audio-clock", "resume-advances", "paused-seek-replies-and-stays-paused", "seek-resume-synchronizes"],
              "final": final, "naturalPlaybackTest": False}
    Path(".local/control-proof.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
