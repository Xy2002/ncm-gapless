(() => {
  const patch = window.__ncmGapless;
  const describe = value => {
    if (value === null) return 'null';
    if (Array.isArray(value)) return { type: 'array', length: value.length };
    if (typeof value === 'object') return { type: 'object', keys: Object.keys(value) };
    return typeof value;
  };
  return {
    patch: patch ? {
      keys: Object.keys(patch), version: patch.version,
      config: Object.fromEntries(Object.entries(patch.cfg || {}).filter(([key, value]) => !/token|cookie|url|path|id|account/i.test(key) && ['boolean', 'number'].includes(typeof value))),
      stats: Object.fromEntries(Object.entries(patch.stats || {}).map(([key, value]) => [key, typeof value === 'number' ? value : describe(value)])),
      store: patch._store ? { playing: Object.keys(patch._store.getState().playing || {}), playingList: Object.keys(patch._store.getState().playingList || {}) } : null,
    } : null,
    nativeCall: String(window.channel.call).slice(0, 7000),
    injectedResources: Array.from(document.scripts).map(script => script.src).filter(url => /gapless|127\.0\.0\.1|localhost/.test(url)),
  };
})()
