/* MP4 timing adapter for a single, unencrypted AAC audio track.
 * Audio packets are never changed. Unsupported edit layouts fail closed.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NcmGaplessAac = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  function inspect(bytes, options) {
    const view = new DataView(bytes);
    let count = 0;
    function require(condition, message) { if (!condition) throw new Error(message || 'AAC_METADATA_INVALID'); }
    function text(offset, length) { require(offset >= 0 && offset + length <= bytes.byteLength); return String.fromCharCode(...new Uint8Array(bytes, offset, length)); }
    function uint64(offset) { const value = Number(view.getBigUint64(offset)); require(Number.isSafeInteger(value)); return value; }
    function children(start, end) {
      const result = [];
      while (start < end) {
        require(++count <= 20000 && start + 8 <= end);
        let size = view.getUint32(start), header = 8;
        if (size === 1) { require(start + 16 <= end); size = uint64(start + 8); header = 16; }
        else if (size === 0) size = end - start;
        require(size >= header && start + size <= end);
        result.push({ type: text(start + 4, 4), start, end: start + size, payload: start + header });
        start += size;
      }
      return result;
    }
    function child(parent, type) {
      const found = children(parent.payload, parent.end).filter(box => box.type === type);
      require(found.length === 1, 'AAC_' + type.toUpperCase() + '_MISSING_OR_DUPLICATED');
      return found[0];
    }
    function header(box) {
      require(box.payload + 24 <= box.end);
      const version = view.getUint8(box.payload);
      require(version === 0 || version === 1, 'AAC_HEADER_VERSION_UNSUPPORTED');
      const scaleOffset = box.payload + (version ? 20 : 12);
      const durationOffset = box.payload + (version ? 24 : 16);
      require(durationOffset + (version ? 8 : 4) <= box.end);
      return { scale: view.getUint32(scaleOffset), duration: version ? uint64(durationOffset) : view.getUint32(durationOffset),
        scaleOffset, durationOffset, wide: !!version };
    }
    const top = children(0, bytes.byteLength);
    require(!top.some(box => box.type === 'moof'), 'AAC_FRAGMENTED_UNSUPPORTED');
    const movie = top.find(box => box.type === 'moov');
    require(movie, 'AAC_MOOV_MISSING');
    const movieChildren = children(movie.payload, movie.end);
    const tracks = movieChildren.filter(box => box.type === 'trak');
    require(tracks.length === 1, 'AAC_MULTI_TRACK_UNSUPPORTED');
    const track = tracks[0], media = child(track, 'mdia');
    const handler = child(media, 'hdlr');
    require(handler.payload + 12 <= handler.end && text(handler.payload + 8, 4) === 'soun', 'AAC_NOT_AUDIO');
    const table = child(child(media, 'minf'), 'stbl');
    const description = child(table, 'stsd');
    require(description.payload + 8 <= description.end && view.getUint32(description.payload + 4) === 1, 'AAC_SAMPLE_ENTRY_UNSUPPORTED');
    const entries = children(description.payload + 8, description.end);
    require(entries.length === 1 && entries[0].type === 'mp4a', 'AAC_ENCRYPTED_OR_CODEC_UNSUPPORTED');
    const entry = entries[0];
    require(entry.start + 36 <= entry.end && view.getUint16(entry.start + 16) === 0, 'AAC_SAMPLE_ENTRY_VERSION_UNSUPPORTED');
    const sampleRate = view.getUint32(entry.start + 32) / 65536;
    require(Number.isInteger(sampleRate) && sampleRate >= 8000 && sampleRate <= 192000);
    require(!children(entry.start + 36, entry.end).some(box => box.type === 'sinf'), 'AAC_ENCRYPTED_UNSUPPORTED');
    const timing = header(child(media, 'mdhd'));
    const movieTiming = header(child(movie, 'mvhd'));
    require(timing.scale > 0 && movieTiming.scale > 0);
    const edits = child(child(track, 'edts'), 'elst');
    require(edits.payload + 8 <= edits.end && view.getUint32(edits.payload + 4) === 1, 'AAC_COMPLEX_EDITS_UNSUPPORTED');
    const version = view.getUint8(edits.payload), wide = version === 1;
    require(version === 0 || version === 1);
    const p = edits.payload + 8;
    require(p + (wide ? 20 : 12) <= edits.end);
    const editDuration = wide ? uint64(p) : view.getUint32(p);
    const mediaTime = wide ? Number(view.getBigInt64(p + 8)) : view.getInt32(p + 4);
    require(Number.isSafeInteger(mediaTime) && mediaTime >= 0, 'AAC_EMPTY_EDIT_UNSUPPORTED');
    const rateOffset = p + (wide ? 16 : 8);
    require(view.getInt16(rateOffset) === 1 && view.getInt16(rateOffset + 2) === 0, 'AAC_EDIT_RATE_UNSUPPORTED');
    const stts = child(table, 'stts');
    require(stts.payload + 8 <= stts.end);
    const rows = view.getUint32(stts.payload + 4);
    require(rows > 0 && rows <= 100000 && stts.payload + 8 + rows * 8 <= stts.end);
    let ticks = 0, sampleCount = 0, lastDelta = 0;
    for (let index = 0; index < rows; index++) {
      const offset = stts.payload + 8 + index * 8;
      const samples = view.getUint32(offset), delta = view.getUint32(offset + 4);
      require(samples > 0 && delta > 0);
      ticks += samples * delta; sampleCount += samples; lastDelta = delta;
      require(Number.isSafeInteger(ticks) && Number.isSafeInteger(sampleCount));
    }
    // Some files omit priming from mdhd.duration although stts still includes
    // it. The sample table, not mdhd minus delay, bounds the encoded timeline.
    let validTicks = ticks - mediaTime;
    require(validTicks > 0);
    require(timing.duration === ticks || timing.duration === validTicks, 'AAC_DURATION_CONFLICT');
    if (options?.timingOnly) {
      const metadataText = new TextDecoder('latin1').decode(new Uint8Array(bytes, movie.start, Math.min(movie.end - movie.start, 2 * 1024 * 1024)));
      const smpbAt = metadataText.indexOf('iTunSMPB');
      const smpb = smpbAt < 0 ? null : /([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{16})/.exec(metadataText.slice(smpbAt, smpbAt + 400));
      return { sampleRate, mediaScale: timing.scale, mediaDuration: timing.duration,
        movieScale: movieTiming.scale, editDuration, mediaTime, remainingTicks: validTicks,
        editTicks: editDuration * timing.scale / movieTiming.scale,
        sampleTable: { rows, ticks, samples: sampleCount, lastDelta }, tableTypes: children(table.payload, table.end).map(box => box.type),
        iTunSMPB: smpb ? { delay: parseInt(smpb[2], 16), padding: parseInt(smpb[3], 16), samples: parseInt(smpb[4], 16) } : null };
    }
    // Only repair the sub-millisecond quantization of an otherwise full edit.
    const precision = timing.scale / movieTiming.scale;
    const editTicks = editDuration * precision;
    const preciseTail = lastDelta * sampleRate / timing.scale < 1024;
    // An integer conversion of coarse movie ticks does not establish the
    // original PCM endpoint. Check the original evidence before replacing it:
    // either the sample table has a precise tail, or an edit tick is at most
    // one source sample. Frame integrality is checked separately below.
    const sampleAccurateEdit = movieTiming.scale >= sampleRate;
    require(preciseTail || sampleAccurateEdit, 'AAC_END_PADDING_AMBIGUOUS');
    const fullEditRounded = Math.abs(editTicks - validTicks) <= precision + 1 && preciseTail;
    if (!fullEditRounded) {
      if (Number.isSafeInteger(editTicks) && editTicks > 0 && editTicks <= validTicks) validTicks = editTicks;
      else require(false, 'AAC_INTENTIONAL_EDIT_UNSUPPORTED');
    }
    // If the sample table contains only padded full AAC packets, the original
    // sample count cannot be recovered from a coarse edit duration alone.
    const sourceFrames = validTicks * sampleRate / timing.scale;
    require(Number.isSafeInteger(sourceFrames), 'AAC_FRACTIONAL_SOURCE_SAMPLES');
    if (editDuration * precision !== validTicks) require(preciseTail, 'AAC_END_PADDING_AMBIGUOUS');
    const trackHeader = child(track, 'tkhd');
    const trackVersion = view.getUint8(trackHeader.payload);
    require(trackVersion === 0 || trackVersion === 1);
    const trackDurationOffset = trackHeader.payload + (trackVersion ? 28 : 20);
    require(trackDurationOffset + (trackVersion ? 8 : 4) <= trackHeader.end);
    return { sampleRate, sourceFrames, encoderDelayTicks: mediaTime, mediaScale: timing.scale,
      movieScale: movieTiming.scale, validTicks, mediaTicks: ticks, mediaTiming: timing, movieTiming, editOffset: p, editWide: wide,
      trackDurationOffset, trackWide: !!trackVersion, exactMovieTiming: editDuration * precision === validTicks };
  }
  function prepare(bytes) {
    const metadata = inspect(bytes), output = bytes.slice(0), view = new DataView(output);
    function duration(offset, wide, value) {
      if (!Number.isSafeInteger(value) || value < 0 || (!wide && value > 0xffffffff)) throw new Error('AAC_TIMING_OVERFLOW');
      if (wide) view.setBigUint64(offset, BigInt(value)); else view.setUint32(offset, value);
    }
    // Equal movie/media time scales make the edit duration sample accurate.
    view.setUint32(metadata.movieTiming.scaleOffset, metadata.mediaScale);
    duration(metadata.mediaTiming.durationOffset, metadata.mediaTiming.wide, metadata.mediaTicks);
    duration(metadata.movieTiming.durationOffset, metadata.movieTiming.wide, metadata.validTicks);
    duration(metadata.trackDurationOffset, metadata.trackWide, metadata.validTicks);
    duration(metadata.editOffset, metadata.editWide, metadata.validTicks);
    return { bytes: output, metadata };
  }
  return Object.freeze({ inspect, prepare });
});
