(() => {
  let require = window.__ncmGaplessProbeRequire;
  if (!require) {
    const id = '__ncm_gapless_inspect__';
    window.webpackJsonp.push([[], { [id]: (module, exports, webpackRequire) => {
      require = webpackRequire;
    } }, [[id]]]);
    if (!require) throw new Error('Unsupported webpack runtime');
    window.__ncmGaplessProbeRequire = require;
    delete require.m[id];
    delete require.c[id];
  }
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
      if (!value || (typeof value !== 'object' && typeof value !== 'function')) continue;
      if (typeof value.getState === 'function' && typeof value.dispatch === 'function') {
        const state = value.getState();
        candidates.push({ id, key, kind: 'store', stateKeys: Object.keys(state), playingKeys: Object.keys(state.playing || {}) });
      }
      const prototype = Object.getPrototypeOf(value);
      const methods = [...Object.getOwnPropertyNames(value), ...Object.getOwnPropertyNames(prototype || {})];
      if (methods.some(name => /[Ff]etchPreload|[Ll]oadMusic|getPlaying|[Ss]ubScribe.*Play/.test(name))) {
        candidates.push({ id, key, kind: 'player', methods: methods.filter(name => !name.startsWith('__')) });
      }
    }
  }
  return { cached: Object.keys(require.c).length, candidates };
})()
