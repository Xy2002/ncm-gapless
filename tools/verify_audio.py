"""Check real CEF audio rendering. No playback, account access, or player hooks."""

import argparse
import base64
import json
import math
from pathlib import Path
import struct
import subprocess
import wave

from cdp_probe import evaluate

ROOT = Path(__file__).resolve().parents[1]


def fixtures(directory):
    directory.mkdir(parents=True, exist_ok=True)
    result = []
    for rate in (44100, 48000):
        offset = 0
        for index, frames in enumerate((8191, 11003)):
            path = directory / f"{rate}-{index}.wav"
            with wave.open(str(path), "wb") as target:
                target.setnchannels(2)
                target.setsampwidth(2)
                target.setframerate(rate)
                data = bytearray()
                for frame in range(frames):
                    for channel in range(2):
                        value = round(11000 * math.sin((offset + frame) * 0.087 + channel * 0.4))
                        data += struct.pack("<h", value)
                target.writeframes(data)
            offset += frames
            for codec, extension in (("flac", "flac"), ("libmp3lame", "mp3"), ("aac", "m4a")):
                encoded = path.with_suffix("." + extension)
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(path),
                                "-c:a", codec, str(encoded)], check=True, capture_output=True)
                entry = {"codec": extension, "sampleRate": rate, "segment": index,
                         "expectedFrames": frames, "base64": base64.b64encode(encoded.read_bytes()).decode()}
                if extension == "m4a":
                    reference = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(encoded),
                                                "-f", "f32le", "-c:a", "pcm_f32le", "pipe:1"], check=True, capture_output=True).stdout
                    entry["reference"] = base64.b64encode(reference).decode()
                result.append(entry)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9222)
    arguments = parser.parse_args()
    audio = fixtures(ROOT / ".local" / "fixtures")
    core = (ROOT / "src" / "gapless-core.js").read_text(encoding="utf-8")
    aac = (ROOT / "src" / "aac-timing.js").read_text(encoding="utf-8")
    suite = (ROOT / "tests" / "offline-audio.js").read_text(encoding="utf-8")
    expression = """(async () => {
      const previous = window.NcmGaplessCore;
      const previousAac = window.NcmGaplessAac;
      try {
    """ + core + "\n" + aac + "\n" + suite + "\nconst fixtures = " + json.dumps(audio) + ";\n" + """
        const rendering = await verifyGaplessCore(window.NcmGaplessCore);
        const decoding = [];
        const variants = fixtures.concat(fixtures.filter(item => item.codec === 'm4a').map(item => ({ ...item, nativeStyleHeader: true })));
        for (const item of variants) {
          const context = new OfflineAudioContext(2, 1, item.sampleRate);
          const binary = atob(item.base64);
          const bytes = Uint8Array.from(binary, char => char.charCodeAt(0));
          try {
            if (item.nativeStyleHeader) {
              const metadata = window.NcmGaplessAac.inspect(bytes.buffer);
              const view = new DataView(bytes.buffer);
              if (metadata.mediaTiming.wide) view.setBigUint64(metadata.mediaTiming.durationOffset, BigInt(metadata.mediaTicks - metadata.encoderDelayTicks));
              else view.setUint32(metadata.mediaTiming.durationOffset, metadata.mediaTicks - metadata.encoderDelayTicks);
            }
            const prepared = item.codec === 'm4a' ? window.NcmGaplessAac.prepare(bytes.buffer) : { bytes: bytes.buffer };
            const buffer = await context.decodeAudioData(prepared.bytes);
            let referenceError = null, referenceFrames = null;
            if (item.reference) {
              const raw = Uint8Array.from(atob(item.reference), char => char.charCodeAt(0));
              const reference = new DataView(raw.buffer); referenceFrames = raw.length / 8;
              referenceError = 0;
              if (referenceFrames < item.expectedFrames) throw new Error('REFERENCE_TOO_SHORT');
              for (let channel = 0; channel < 2; channel++) {
                const actual = buffer.getChannelData(channel);
                for (let frame = 0; frame < Math.min(buffer.length, item.expectedFrames); frame++) {
                  referenceError = Math.max(referenceError, Math.abs(actual[frame] - reference.getFloat32((frame * 2 + channel) * 4, true)));
                }
              }
            }
            decoding.push({ codec: item.codec, sampleRate: item.sampleRate, segment: item.segment,
              expectedFrames: item.expectedFrames, decodedFrames: buffer.length, nativeStyleHeader: !!item.nativeStyleHeader,
              lengthMatches: buffer.length === item.expectedFrames, channels: buffer.numberOfChannels,
              timingAdjusted: prepared.metadata ? !prepared.metadata.exactMovieTiming : false,
              referenceFrames, referenceError, referenceMatches: referenceError === null || referenceError < 0.00001 });
          } catch (error) {
            decoding.push({ codec: item.codec, sampleRate: item.sampleRate, segment: item.segment,
              expectedFrames: item.expectedFrames, supported: false, error: error.name });
          }
        }
        return { userAgent: navigator.userAgent, rendering, decoding, noAudiblePlayback: true };
      } finally {
        if (previous === undefined) delete window.NcmGaplessCore;
        else window.NcmGaplessCore = previous;
        if (previousAac === undefined) delete window.NcmGaplessAac;
        else window.NcmGaplessAac = previousAac;
      }
    })()"""
    raw = evaluate(arguments.port, expression)
    result = raw.get("result", {})
    if "exceptionDetails" in result or "value" not in result.get("result", {}):
        raise RuntimeError(json.dumps(raw, ensure_ascii=False))
    report = result["result"]["value"]
    output = ROOT / ".local" / "audio-proof.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not report["rendering"]["pass"] or not all(item.get("lengthMatches", False) and item.get("referenceMatches", False) for item in report["decoding"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
