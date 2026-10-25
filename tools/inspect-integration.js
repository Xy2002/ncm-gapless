(() => {
  const require = window.__ncmGaplessProbeRequire;
  if (!require) throw new Error('Run inspect-modules.js first');
  const player = require.c[4].exports.AudioPlayer;
  const methods = {};
  for (const key of ['preLoad', 'getPlaybackInfo', 'subscribePlayStatus', 'subscribePreloadInfo', 'setPreloadInfoResult']) methods[key] = String(player[key]);
  const candidates = [];
  for (const [id, module] of Object.entries(require.c)) {
    const root = module.exports;
    const values = [['exports', root]];
    if (root && (typeof root === 'object' || typeof root === 'function')) {
      for (const key of Object.keys(root)) {
        try { values.push([key, root[key]]); } catch (_) {}
      }
    }
    for (const [key, value] of values) {
      if (typeof value === 'function') {
        const source = String(value);
        if (source.length < 600 && /getState\(|_store|\.dispatch\(/.test(source)) candidates.push({ id, key, source });
      } else if (value && typeof value === 'object') {
        const keys = Object.keys(value);
        if (keys.includes('_store') || keys.includes('_models')) candidates.push({ id, key, keys, store: value._store && Object.keys(value._store), stateKeys: value._store && Object.keys(value._store.getState()) });
      }
    }
  }
  const adapter = window.legacyNativeCmder._envAdapter;
  return { methods, candidates: candidates.slice(0, 55), adapter: Object.keys(adapter), adapterMethods: Object.getOwnPropertyNames(Object.getPrototypeOf(adapter)), callbackMap: Object.keys(adapter.registerCallMap || {}) };
})()
