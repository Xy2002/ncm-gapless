(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NcmGaplessClient = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  function discover(target) {
    const version = /NeteaseMusicDesktop\/([\d.]+)/.exec(target.navigator.userAgent);
    if (!version || version[1] !== '3.1.42.205594') throw new Error('CLIENT_VERSION_UNVERIFIED');
    if (!target.channel || typeof target.channel.call !== 'function' || !target.webpackJsonp) throw new Error('CLIENT_BRIDGE_MISSING');
    if (target.__ncmGapless) throw new Error('OLD_PATCH_STILL_LOADED');
    let require;
    const key = '__ncm_gapless_adapter_' + Date.now();
    target.webpackJsonp.push([[], { [key]: function (module, exports, reference) { require = reference; } }, [[key]]]);
    if (!require) throw new Error('WEBPACK_RUNTIME_UNSUPPORTED');
    delete require.m[key]; delete require.c[key];
    let sdk, preload, refresh, states;
    for (const module of Object.values(require.c)) {
      const exports = module.exports;
      if (!exports || !['object', 'function'].includes(typeof exports)) continue;
      if (exports.AudioPlayer?.setPreloadInfoResult && exports.Bridge?.triggerRegisterCall) sdk = exports;
      for (const key of Object.keys(exports)) {
        let value; try { value = exports[key]; } catch (_) { continue; }
        if (value && typeof value === 'object' && typeof value.Playing === 'number' && typeof value.Pause === 'number' && typeof value.Stop === 'number') states = value;
        if (typeof value === 'function') {
          const source = String(value);
          if (source.includes('preloadIndex') && source.includes('setPreloadInfoResult')) preload = value;
          if (source.includes('skipLocalRpcCache') && source.includes('soundQuality') && source.includes('immerseType')) refresh = value;
        }
      }
    }
    let store;
    const element = target.document.getElementById('root');
    const pending = [element?._reactRootContainer?._internalRoot?.current];
    const visited = new Set();
    while (pending.length && visited.size < 10000) {
      const fiber = pending.pop();
      if (!fiber || visited.has(fiber)) continue;
      visited.add(fiber);
      const candidate = fiber.memoizedProps?.store || fiber.memoizedProps?.value?.store;
      if (candidate?.getState && candidate?.dispatch && candidate?.subscribe) { store = candidate; break; }
      pending.push(fiber.child, fiber.sibling);
    }
    if (!sdk || !preload || !refresh || !store || !states || !store.getState().playingList) throw new Error('PLAYBACK_INTERFACE_MISSING');

    let prefetchBusy = false;
    async function nextInfo(signal) {
      if (prefetchBusy) throw new Error('PREFETCH_BUSY');
      if (signal?.aborted) throw new Error('PREFETCH_CANCELLED');
      prefetchBusy = true;
      const id = store.getState().playing.playId;
      const player = sdk.AudioPlayer;
      const descriptor = Object.getOwnPropertyDescriptor(player, 'setPreloadInfoResult');
      const original = player.setPreloadInfoResult;
      let captured, timer, abortHandler;
      try {
        player.setPreloadInfoResult = function (result) {
          if (result?.params?.curPlayId === id && result?.params?.preloadIndex === 0) captured = result;
          return original.apply(this, arguments);
        };
        await Promise.race([
          preload({ curPlayId: id, preloadIndex: 0 }),
          new Promise(function (resolve, reject) {
            timer = setTimeout(() => reject(new Error('PREFETCH_TIMEOUT')), 15000);
            abortHandler = () => reject(new Error('PREFETCH_CANCELLED'));
            signal?.addEventListener('abort', abortHandler, { once: true });
          }),
        ]);
        if (signal?.aborted || store.getState().playing.playId !== id) throw new Error('PREFETCH_CANCELLED');
        if (captured?.code !== 1 || !captured.info?.musicurl) return null;
        return captured.info;
      } finally {
        if (descriptor) Object.defineProperty(player, 'setPreloadInfoResult', descriptor);
        else delete player.setPreloadInfoResult;
        clearTimeout(timer);
        if (abortHandler) signal?.removeEventListener('abort', abortHandler);
        prefetchBusy = false;
      }
    }

    function emit(name) {
      const args = Array.prototype.slice.call(arguments, 1);
      // This SDK's public triggerRegisterCall passes the entire argument list
      // as ONE array. Native callbacks require positional arguments instead.
      const key = 'audioplayer.on' + name;
      sdk.Bridge._Adapter._registerCallQueue(key)(...args);
      // Legacy consumers use a distinct callback map, e.g. desktop lyrics.
      const legacy = target.legacyNativeCmder;
      if (legacy?._envAdapter?._registerCallQueue && legacy !== sdk.Bridge) legacy._envAdapter._registerCallQueue(key)(...args);
    }
    async function refreshInfo(info, signal) {
      if (signal?.aborted) throw new Error('PREFETCH_CANCELLED');
      let timer, abortHandler;
      try {
        const data = await Promise.race([
          refresh({ ids: info.songId, soundQuality: info.soundQuality || info.level || 'standard' }, true),
          new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error('SOURCE_REFRESH_TIMEOUT')), 15000);
            abortHandler = () => reject(new Error('PREFETCH_CANCELLED'));
            signal?.addEventListener('abort', abortHandler, { once: true });
          }),
        ]);
        if (signal?.aborted) throw new Error('PREFETCH_CANCELLED');
        if (!data?.url || data.code !== 200 || data.freeTrialInfo || data.freeTrialPrivilege?.resConsumable || data.freeTrialPrivilege?.userConsumable) throw new Error('SOURCE_REFRESH_NOT_AUTHORIZED');
        return Object.assign({}, info, { musicurl: data.url, md5: data.md5 || info.md5,
          fileSize: data.size || info.fileSize, expireTime: data.expi,
          format: data.format || info.format, freeTrialInfo: data.freeTrialInfo || null,
          freeTrialPrivilege: data.freeTrialPrivilege || null });
      } finally {
        clearTimeout(timer); if (abortHandler) signal?.removeEventListener('abort', abortHandler);
      }
    }
    return { version: version[1], sdk: sdk, states: states, store: store, nextInfo: nextInfo, refreshInfo, emit: emit,
      getState: () => store.getState(), subscribe: callback => store.subscribe(callback),
      replay: function (item) {
        return store.dispatch({ type: 'playing/setPlaying', payload: {
          trackIn: item || store.getState().playing.curPlaying, playingState: states.Playing, flag: 0,
          fromType: 'call', triggerScene: 'unknown', isForceSetPlaying: true, noAddToHistory: true,
        } });
      } };
  }
  return Object.freeze({ discover: discover });
});
