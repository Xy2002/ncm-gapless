(function (root) {
  'use strict';
  if (root.NcmGapless && root.NcmGapless.installed) return;

  function install(options) {
    if (root.NcmGapless?.installed) return root.NcmGapless.status();
    options = Object.assign({ maximumDecodedBytes: 256 * 1024 * 1024, maximumEncodedBytes: 80 * 1024 * 1024 }, options);
    const client = root.NcmGaplessClient.discover(root);
    const native = (name, callback, args) => client.callNative(name, callback || function () {}, args || []);
    let context = new root.AudioContext({ latencyHint: 'playback', sampleRate: 48000 });
    const counters = { loads: 0, decoded: 0, prepared: 0, transitions: 0, unpreparedEnds: 0, fallbacks: 0,
      cancelledPrefetch: 0, errors: 0, lastError: null, lastBoundaryDeltaFrames: null, lastSourceCapabilities: null, aacTimingFixes: 0, officialRefreshes: 0 };
    let current = null, handoff = null, installed = true, generation = 0, preparation = 0;
    let loadController = null, loading = null, prefetchController = null, prefetchTimer = null;
    let queueReference, modeReference, qualityReference, tickTimer;
    const reports = new Map();
    let engine = new root.NcmGaplessEngine.Engine(context, { onBoundary: onBoundary });
    let sourceRateChosen = false, initialization = Promise.resolve();
    engine.setVolume(Number(client.getState().playing.playingVolume) || 0);
    engine.rate = Number(client.getState().playing.playingSpeed) || 1;

    function code(error) {
      if (error?.name === 'AbortError') return 'CANCELLED';
      const text = String(error?.message || 'UNKNOWN');
      return /^[A-Z0-9_:-]{1,90}$/.test(text) ? text : 'OPERATION_FAILED';
    }
    function problem(error) { counters.errors++; counters.lastError = code(error); }
    function emit(name) { client.emit.apply(null, arguments); }
    function acknowledge(callback, value) { if (typeof callback === 'function') callback(value); }
    function later(callback) { Promise.resolve().then(callback).catch(problem); }
    function songId(info) { return String(info?.songId || ''); }
    function sameSource(left, right) {
      return songId(left) && songId(left) === songId(right) &&
        (!left.md5 || !right.md5 || left.md5 === right.md5) &&
        (!left.bitrate || !right.bitrate || String(left.bitrate) === String(right.bitrate));
    }
    function supported(info) {
      if (!info?.musicurl || !songId(info) || info.freeTrialInfo || info.freeTrialPrivilege?.resConsumable || info.freeTrialPrivilege?.userConsumable) return false;
      let url; try { url = new URL(info.musicurl); } catch (_) { return false; }
      if (!['http:', 'https:'].includes(url.protocol) || !/(^|\.)(music\.126\.net|music126\.net|music\.163\.com|netease\.com)$/.test(url.hostname)) return false;
      const format = String(info.format || /\.([a-z0-9]+)$/.exec(url.pathname)?.[1] || '').toLowerCase();
      return ['mp3', 'flac', 'wav', 'm4a', 'aac'].includes(format);
    }
    async function decode(info, signal) {
      if (!supported(info)) throw new Error('FORMAT_OR_SOURCE_UNSUPPORTED');
      let extra = {}; try { extra = typeof info.extHeader === 'string' ? JSON.parse(info.extHeader) : info.extHeader || {}; } catch (_) {}
      const headers = {};
      for (const key of Object.keys(extra)) if (['x-cdn-trace-tag', 'x-song-info'].includes(key.toLowerCase())) headers[key] = extra[key];
      let response = await root.fetch(info.musicurl, { signal, headers });
      if ([401, 403, 410].includes(response.status)) {
        info = await client.refreshInfo(info, signal);
        if (!supported(info)) throw new Error('FORMAT_OR_SOURCE_UNSUPPORTED');
        counters.officialRefreshes++;
        response = await root.fetch(info.musicurl, { signal, headers });
      }
      if (!response.ok && new URL(info.musicurl).protocol === 'http:') {
        const secure = new URL(info.musicurl); secure.protocol = 'https:';
        response = await root.fetch(secure.href, { signal, headers });
      }
      if (!response.ok) throw new Error('AUDIO_HTTP_' + response.status);
      const declared = Number(response.headers.get('Content-Length'));
      if (declared > options.maximumEncodedBytes) throw new Error('ENCODED_MEMORY_LIMIT');
      const reader = response.body.getReader();
      const chunks = []; let length = 0;
      for (;;) {
        const value = await reader.read(); if (value.done) break;
        length += value.value.byteLength;
        if (length > options.maximumEncodedBytes) { await reader.cancel(); throw new Error('ENCODED_MEMORY_LIMIT'); }
        chunks.push(value.value);
      }
      if (signal.aborted) throw new Error('CANCELLED');
      const bytes = new Uint8Array(length); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const extension = /\.([a-z0-9]+)$/i.exec(new URL(info.musicurl).pathname)?.[1]?.toLowerCase();
      const isAac = ['aac', 'm4a'].includes(String(info.format || extension).toLowerCase());
      const prepared = isAac ? root.NcmGaplessAac.prepare(bytes.buffer) : { bytes: bytes.buffer };
      if (!sourceRateChosen) {
        sourceRateChosen = true;
        const sampleRate = prepared.metadata?.sampleRate;
        if (sampleRate && sampleRate !== context.sampleRate) initialization = (async () => {
          await engine.close();
          context = new root.AudioContext({ latencyHint: 'playback', sampleRate });
          engine = new root.NcmGaplessEngine.Engine(context, { onBoundary });
          engine.setVolume(Number(client.getState().playing.playingVolume) || 0);
          engine.rate = Number(client.getState().playing.playingSpeed) || 1;
        })();
      }
      await initialization;
      if (signal.aborted || !installed) throw new Error('CANCELLED');
      const buffer = await context.decodeAudioData(prepared.bytes);
      if (prepared.metadata) {
        const expected = prepared.metadata.sourceFrames * context.sampleRate / prepared.metadata.sampleRate;
        if (Math.abs(buffer.length - expected) > 1) throw new Error('AAC_DECODED_LENGTH_MISMATCH');
        if (!prepared.metadata.exactMovieTiming) counters.aacTimingFixes++;
      }
      if (signal.aborted) throw new Error('CANCELLED');
      if (buffer.length * buffer.numberOfChannels * 4 > options.maximumDecodedBytes) throw new Error('DECODED_MEMORY_LIMIT');
      counters.decoded++;
      return { info, buffer, encodedBytes: length, codecMetadata: prepared.metadata };
    }
    function cancelPreparation() {
      preparation++; clearTimeout(prefetchTimer);
      if (prefetchController && !prefetchController.signal.aborted) { prefetchController.abort(); counters.cancelledPrefetch++; }
      prefetchController = null; engine.cancelNext();
    }
    function queueStamp() {
      const state = client.getState();
      queueReference = state.playingList.curPlayingList;
      modeReference = state.playing.playingMode;
      qualityReference = state.setting?.quantity;
    }
    function planNext(delay) {
      clearTimeout(prefetchTimer);
      if (!installed || !current || handoff || engine.next) return;
      prefetchTimer = setTimeout(prepareNext, delay === undefined ? 150 : delay);
    }
    async function prepareNext() {
      if (!installed || !current || handoff) return;
      const epoch = preparation, active = current;
      const abort = new AbortController(); prefetchController = abort;
      try {
        const info = await client.nextInfo(abort.signal);
        if (!info || !supported(info) || abort.signal.aborted || current !== active || epoch !== preparation) return;
        const entry = await decode(info, abort.signal);
        const memory = (active.buffer.length * active.buffer.numberOfChannels + entry.buffer.length * entry.buffer.numberOfChannels) * 4;
        if (memory > options.maximumDecodedBytes) throw new Error('DECODED_MEMORY_LIMIT');
        if (abort.signal.aborted || current !== active || epoch !== preparation) return;
        if (engine.queue(entry)) counters.prepared++;
      } catch (error) {
        if (!abort.signal.aborted && installed && current === active) {
          problem(error);
          if (code(error) === 'PREFETCH_BUSY') planNext(350);
        }
      } finally { if (prefetchController === abort) prefetchController = null; }
    }
    function remember(entry, position) {
      if (!entry?.id) return;
      reports.set(entry.id, { playedTime: position, playedAudioTime: position, result: true,
        playedPercent: Math.min(1, position / entry.buffer.duration), wholeCached: true, preloadWholeCached: true,
        sourceAudioFormat: { channels: entry.buffer.numberOfChannels, samplerate: entry.buffer.sampleRate, samplesize: 32 },
        playAudioFormat: { channels: entry.buffer.numberOfChannels, samplerate: context.sampleRate, samplesize: 32 },
        deviceAudioFormat: { channels: context.destination.channelCount, samplerate: context.sampleRate, samplesize: 32 } });
      while (reports.size > 8) reports.delete(reports.keys().next().value);
    }
    function onBoundary(previous, next) {
      if (!installed || current !== previous) return;
      remember(previous, previous.buffer.duration);
      if (next) {
        counters.transitions++;
        counters.lastBoundaryDeltaFrames = Math.round((next.start - previous.end) * context.sampleRate);
        handoff = { entry: next, previousId: previous.id };
      } else counters.unpreparedEnds++;
      emit('PlayProgress', previous.id, previous.buffer.duration, 1, true);
      emit('End', previous.id, { activeCode: 0, code: 0, errorCode: 0, errorString: '', playedTime: previous.buffer.duration * 1000 });
    }
    function load(id, info, callback) {
      const epoch = ++generation;
      loadController?.abort(); cancelPreparation();
      if (handoff && sameSource(handoff.entry.info, info) && engine.current === handoff.entry) {
        current = handoff.entry; handoff = null;
        Object.assign(current, { id, info, playTag: '' });
        if (current.gain) current.gain.gain.setValueAtTime(Math.pow(10, (Number(info.volumeDelta) || 0) / 20), context.currentTime);
        queueStamp(); acknowledge(callback);
        later(() => emit('Load', id, { activeCode: 0, code: 0, duration: current.buffer.duration, errorCode: 0, errorString: '' }));
        return;
      }
      handoff = null; engine.clear(); current = null;
      const oldId = client.getState().playing.playId;
      native('audioplayer.stop', null, [oldId]);
      const abort = new AbortController(); loadController = abort;
      const pending = { id, info, paused: false }; loading = pending;
      let timedOut = false;
      const deadline = setTimeout(() => { timedOut = true; abort.abort(); }, 30000);
      counters.loads++; acknowledge(callback);
      decode(info, abort.signal).then(entry => {
        if (!installed || abort.signal.aborted || epoch !== generation) return;
        current = Object.assign(entry, { id, playTag: '', initialPaused: pending.paused });
        loading = null;
        engine.load(current); queueStamp();
        emit('Load', id, { activeCode: 0, code: 0, duration: entry.buffer.duration, errorCode: 0, errorString: '' });
      }).catch(error => {
        if ((abort.signal.aborted && !timedOut) || epoch !== generation || !installed) return;
        counters.fallbacks++; problem(error);
        current = null; loading = null; native('audioplayer.load', null, [id, info]);
      }).finally(() => clearTimeout(deadline));
    }
    function ownId(argument) {
      const id = argument && typeof argument === 'object' ? argument.playId : argument;
      return current && (id === current.id || id === undefined || id === '');
    }
    const hook = function (name, callback, args, forward) {
      args = args || [];
      if (!installed) return forward(name, callback, args);
      const pendingId = args[0] && typeof args[0] === 'object' ? args[0].playId : args[0];
      if (loading && (pendingId === loading.id || pendingId === undefined || pendingId === '')) {
        if (name === 'audioplayer.pause' || name === 'audioplayer.play') {
          loading.paused = name === 'audioplayer.pause'; acknowledge(callback); return;
        }
        if (name === 'audioplayer.stop') {
          generation++; loadController?.abort(); loading = null; acknowledge(callback); return;
        }
      }
      if (name === 'audioplayer.load') {
        let sourceUrl; try { sourceUrl = new URL(args[1]?.musicurl); } catch (_) {}
        counters.lastSourceCapabilities = { hasUrl: !!args[1]?.musicurl, hasPath: !!args[1]?.path,
          hasSongId: !!songId(args[1]), keys: Object.keys(args[1] || {}),
          format: /^[a-z0-9_-]{1,20}$/i.test(String(args[1]?.format)) ? String(args[1]?.format) : 'other',
          protocol: sourceUrl?.protocol || null, extension: /\.([a-z0-9]{1,8})$/i.exec(sourceUrl?.pathname || '')?.[1] || null,
          hostAllowed: !!sourceUrl && /(^|\.)(music\.126\.net|music126\.net|music\.163\.com|netease\.com)$/.test(sourceUrl.hostname),
          hasTrial: !!args[1]?.freeTrialInfo || !!args[1]?.freeTrialPrivilege?.resConsumable || !!args[1]?.freeTrialPrivilege?.userConsumable };
        if (supported(args[1])) return load(args[0], args[1], callback);
        generation++; loadController?.abort(); loading = null; cancelPreparation(); engine.clear(); current = null; handoff = null;
        counters.fallbacks++;
        return forward(name, callback, args);
      }
      if (name === 'audioplayer.getPlayedTime' || name === 'audioplayer.getPlaybackInfo') {
        const id = typeof args[0] === 'object' ? args[0]?.playId : args[0];
        if (current?.id === id) remember(current, handoff ? current.buffer.duration : engine.position());
        if (reports.has(id)) { acknowledge(callback, Object.assign({}, reports.get(id))); return; }
      }
      if (name === 'audioplayer.setVolume' && current) {
        engine.setVolume(Number(args[2])); acknowledge(callback);
        later(() => emit('Volume', current.id, '', 0, Number(args[2]))); return;
      }
      if (name === 'audioplayer.setPlaybackRate' && current) {
        const rate = Number(typeof args[0] === 'object' ? args[0]?.rate ?? args[0]?.playbackRate ?? args[0]?.value : args[0]);
        acknowledge(callback);
        engine.setRate(rate).catch(problem); return;
      }
      if (ownId(args[0])) {
        if (name === 'audioplayer.play') {
          const active = current; active.playTag = args[1] || active.playTag;
          acknowledge(callback);
          if (active.initialPaused) {
            active.initialPaused = false;
            setTimeout(() => { if (installed && current === active) emit('PlayState', active.id, active.playTag, 2); }, 30);
            return;
          }
          engine.play().then(() => {
            if (!installed || current !== active) return;
            emit('PlayState', active.id, active.playTag, 1);
            planNext();
          }).catch(problem); return;
        }
        if (name === 'audioplayer.pause') {
          const active = current; active.playTag = args[1] || active.playTag;
          acknowledge(callback);
          engine.pause().then(() => { if (installed && current === active) emit('PlayState', active.id, active.playTag, 2); }).catch(problem);
          return;
        }
        if (name === 'audioplayer.seek') {
          const active = current; acknowledge(callback);
          engine.seek(Number(args[2])).then(() => {
            // SDK.seek registers its one-shot listener AFTER its call ack.
            // A timer preserves the native event ordering even while paused.
            setTimeout(() => {
              if (!installed || current !== active) return;
              emit('Seek', active.id, args[1], 0, engine.position());
              emit('PlayProgress', active.id, engine.position(), 1, true);
            }, 0);
          }).catch(problem); return;
        }
        if (name === 'audioplayer.stop') {
          acknowledge(callback);
          if (handoff && args[0] === handoff.previousId) return;
          remember(current, engine.position()); generation++; loadController?.abort(); cancelPreparation(); engine.clear(); current = null; handoff = null;
          return;
        }
      }
      return forward(name, callback, args);
    };

    const restoreCalls = client.intercept(hook);
    const unsubscribe = client.subscribe(() => {
      if (!current || !installed) return;
      const state = client.getState();
      engine.setVolume(Number(state.playing.playingVolume) || 0);
      if (state.playingList.curPlayingList !== queueReference || state.playing.playingMode !== modeReference || state.setting?.quantity !== qualityReference) {
        queueStamp();
        if (!handoff) { cancelPreparation(); planNext(250); }
      }
    });
    tickTimer = setInterval(() => {
      if (!current || !installed || handoff || !engine.current) return;
      emit('PlayProgress', current.id, engine.position(), 1, false);
    }, 100);

    const api = {
      version: '0.3.1-experimental', installed: true,
      install: function () { return api.status(); },
      status: function () {
        return Object.assign({ version: api.version, installed, clientVersion: client.version, platform: client.platform,
          active: !!current, contextState: context.state, sampleRate: context.sampleRate, playbackRate: engine.rate, playing: engine.playing,
          position: engine.position(), duration: engine.current?.buffer.duration || 0,
          nextReady: !!engine.next, waitingForOfficialHandoff: !!handoff,
          currentMatchesOfficial: !!current && current.id === client.getState().playing.playId,
          decodedBytes: [engine.current, engine.next].reduce((sum, entry) => sum + (entry ? entry.buffer.length * entry.buffer.numberOfChannels * 4 : 0), 0),
        }, counters);
      },
      // Intended for a user-requested activation after installing; preserves the official queue.
      activateCurrent: function () { return client.replay(); },
      uninstall: async function () {
        if (!installed) return { installed: false };
        const item = client.getState().playing.curPlaying;
        const pending = loading;
        const info = pending?.info || current?.info;
        const position = pending ? 0 : engine.position();
        const wasPlaying = pending ? !pending.paused : engine.playing;
        const wasActive = !!current || !!pending;
        installed = false; api.installed = false; generation++; loadController?.abort(); loading = null; cancelPreparation();
        clearInterval(tickTimer); unsubscribe();
        restoreCalls();
        await engine.close(); current = null; handoff = null;
        if (wasActive && item) {
          await client.restorePlayback(item, position, wasPlaying, info, !!pending);
        }
        return { installed: false, officialPlaybackRestored: wasActive && !!item };
      },
    };
    root.NcmGapless = api;
    return api.status();
  }
  root.NcmGapless = { installed: false, install: install };
})(typeof globalThis === 'object' ? globalThis : this);
