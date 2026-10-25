/* Experimental PCM scheduling core. It does not hook the NetEase player. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NcmGaplessCore = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  function integer(value, name, minimum) {
    if (!Number.isSafeInteger(value) || value < minimum) {
      throw new RangeError(name + ' must be an integer >= ' + minimum);
    }
    return value;
  }

  /**
   * Schedule already decoded buffers on ONE audio clock, using integer frames.
   * No end-event timers, crossfade, or silence detection participates in timing.
   * Buffers must already match context.sampleRate (decodeAudioData resamples).
   * Trims may only come from verified codec metadata, never silence guesses.
   */
  function schedule(context, tracks, options) {
    options = options || {};
    if (!context || !Number.isFinite(context.sampleRate) || context.state === 'closed') {
      throw new TypeError('An open BaseAudioContext is required');
    }
    if (!Array.isArray(tracks) || !tracks.length) throw new TypeError('No tracks supplied');
    const sampleRate = context.sampleRate;
    const startFrame = integer(options.startFrame === undefined
      ? Math.ceil((context.currentTime + 0.1) * sampleRate) : options.startFrame,
    'startFrame', 0);
    if (startFrame < Math.ceil(context.currentTime * sampleRate)) {
      throw new RangeError('Cannot schedule in the past');
    }

    // Validate the entire sequence before starting any audio.
    let cursor = startFrame;
    const plan = tracks.map(function (track) {
      const buffer = track && track.buffer;
      if (!buffer || typeof buffer.getChannelData !== 'function' ||
          !Number.isSafeInteger(buffer.length) || buffer.length <= 0) {
        throw new TypeError('Every track requires a non-empty AudioBuffer');
      }
      if (buffer.sampleRate !== sampleRate) {
        throw new RangeError('Decode/resample all buffers to the context sample rate first');
      }
      const head = integer(track.trimStartFrames === undefined ? 0 : track.trimStartFrames, 'trimStartFrames', 0);
      const tail = integer(track.trimEndFrames === undefined ? 0 : track.trimEndFrames, 'trimEndFrames', 0);
      const frames = buffer.length - head - tail;
      if (frames <= 0) throw new RangeError('Codec trim removes the entire track');
      const endFrame = integer(cursor + frames, 'endFrame', 1);
      const item = { buffer: buffer, startFrame: cursor, endFrame: endFrame,
        offsetFrames: head, frames: frames };
      cursor = endFrame;
      return item;
    });

    const sources = [];
    function dispose() {
      for (const source of sources) {
        try { source.stop(); } catch (_) {}
        try { source.disconnect(); } catch (_) {}
      }
    }
    try {
      for (const item of plan) {
        const source = context.createBufferSource();
        sources.push(source);
        source.buffer = item.buffer;
        source.connect(options.output || context.destination);
        source.start(item.startFrame / sampleRate, item.offsetFrames / sampleRate,
          item.frames / sampleRate);
      }
    } catch (error) {
      dispose();
      throw error;
    }
    return { sampleRate: sampleRate, startFrame: startFrame, endFrame: cursor,
      frames: cursor - startFrame, plan: plan, sources: sources, dispose: dispose };
  }

  return Object.freeze({ version: '0.1.0-research', schedule: schedule });
});
