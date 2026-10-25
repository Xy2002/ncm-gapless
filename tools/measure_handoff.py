"""Measure an actual prepared album boundary through WASAPI, retaining no audio.

Seeks to the last 2.5 seconds of the current track; uses the real patch and SDK.
Only aggregate timing and bounded engine events are written to .local.
"""
import argparse
import base64
import json
from pathlib import Path
import time

import numpy as np
import pyaudiowpatch as pa
from check_source_access import value

ROOT = Path(__file__).resolve().parents[1]
ANALYSIS_RATE = 8000


def resample(signal, source_rate):
    """Band-limit both reference and output before comparing different clocks."""
    taps = np.arange(-64, 65)
    kernel = np.sinc(2 * 2800 / source_rate * taps) * np.hanning(len(taps))
    kernel /= kernel.sum()
    filtered = np.convolve(signal, kernel, mode='same')
    positions = np.arange(int(len(signal) * ANALYSIS_RATE / source_rate)) * source_rate / ANALYSIS_RATE
    return np.interp(positions, np.arange(len(signal)), filtered)


def locate(audio, reference):
    """Normalized matched-filter lag; reference must contain non-silent music."""
    reference = reference.astype(np.float64)
    reference -= reference.mean()
    energy = float(reference @ reference)
    if energy < 1e-8:
        raise RuntimeError('REFERENCE_IS_SILENT')
    size = 1 << (len(audio) + len(reference) - 1).bit_length()
    dot = np.fft.irfft(np.fft.rfft(audio, size) * np.fft.rfft(reference[::-1], size), size)
    dot = dot[len(reference) - 1:len(audio)]
    sums = np.r_[0, np.cumsum(audio)]
    squares = np.r_[0, np.cumsum(audio * audio)]
    local_energy = squares[len(reference):] - squares[:-len(reference)] - (sums[len(reference):] - sums[:-len(reference)]) ** 2 / len(reference)
    scores = dot / np.sqrt(np.maximum(local_energy * energy, 1e-20))
    index = int(np.argmax(scores))
    return index, float(scores[index])


def analyse(audio, reference):
    rate = ANALYSIS_RATE
    decode = lambda key: resample(np.frombuffer(base64.b64decode(reference[key]), dtype='<f4').astype(np.float64), reference['rate'])
    a, b = decode('a'), decode('b')
    windows = [('tail', a[int(.4 * rate):int(1.9 * rate)], .4),
               ('head-early', b[int(.08 * rate):int(.55 * rate)], reference['tail'] + .08),
               ('head-late', b[int(1.2 * rate):int(2.7 * rate)], reference['tail'] + 1.2)]
    matches = []
    for name, samples, expected in windows:
        index, correlation = locate(audio, samples)
        matches.append({'name': name, 'correlation': round(correlation, 5), 'lagMs': round((index / rate - expected) * 1000, 3)})
    delta = matches[-1]['lagMs'] - matches[0]['lagMs']
    reliable = all(m['correlation'] > .92 for m in matches)
    return {'reliable': reliable, 'matches': matches, 'insertedTimeMs': round(delta, 3),
            'pass': reliable and abs(delta) < 5}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=9222)
    parser.add_argument('--output', default='.local/handoff-measurement.json')
    parser.add_argument('--natural', action='store_true', help='Wait for the current track tail without seeking')
    args = parser.parse_args()
    read = lambda code: value(args.port, code, user_gesture=True)
    initial = read('window.NcmGapless.status()')
    if not initial.get('active') or not initial.get('playing') or not initial.get('nextReady') or initial.get('playbackRate') != 1:
        raise RuntimeError('ACTIVE_PREPARED_PAIR_AT_RATE_ONE_REQUIRED')
    if args.natural:
        deadline = time.monotonic() + initial['duration'] + 15
        while initial['duration'] - initial['position'] > 3:
            if time.monotonic() > deadline or not initial['playing'] or not initial['nextReady']:
                raise RuntimeError('NATURAL_BOUNDARY_WAIT_FAILED')
            time.sleep(.2)
            initial = read('window.NcmGapless.status()')
    read((ROOT / 'tools' / 'measure-handoff.js').read_text(encoding='utf-8'))
    chunks, flags = [], []
    audio_api = pa.PyAudio()
    stream = None
    try:
        device = audio_api.get_default_wasapi_loopback()
        sample_rate, channels = int(device['defaultSampleRate']), device['maxInputChannels']
        def callback(data, count, timing, flag):
            if flag:
                flags.append(flag)
            chunks.append(data)
            return None, pa.paContinue
        stream = audio_api.open(format=pa.paFloat32, channels=channels, rate=sample_rate, input=True,
                               input_device_index=device['index'], frames_per_buffer=480, stream_callback=callback)
        time.sleep(.15)
        if not args.natural:
            seek = """(async()=>{const c=window.NcmGaplessClient.discover(window);return await c.sdk.AudioPlayer.seek({playId:c.getState().playing.playId,seekId:'handoff-measurement',value:window.NcmGapless.status().duration-2.5});})()"""
            response = read(seek)
            if response.get('code') != 0:
                raise RuntimeError('SEEK_NOT_ACKNOWLEDGED')
        time.sleep(7)
        stream.stop_stream()
        measured = read('window.__ncmHandoffMeasurement.result()')
        audio = np.frombuffer(b''.join(chunks), dtype='<f4').reshape(-1, channels).mean(axis=1).astype(np.float64)
        audio = resample(audio, sample_rate)
        report = analyse(audio, measured['reference'])
        report.update({'deviceRate': sample_rate, 'captureFlags': flags, 'events': measured['events'],
                       'finalStatus': measured['status'], 'naturalPlaybackTest': args.natural, 'audioSaved': False})
        if flags:
            report['pass'] = False
        (ROOT / args.output).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(report, indent=2))
        raise SystemExit(0 if report['pass'] else 1)
    finally:
        if stream is not None:
            stream.close()
        audio_api.terminate()
        read('window.__ncmHandoffMeasurement?.cleanup();true')


if __name__ == '__main__':
    main()
