(() => {
  const legacy = window.legacyNativeCmder;
  const methods = Object.getOwnPropertyNames(Object.getPrototypeOf(legacy || {}));
  const own = Object.keys(legacy || {});
  const functions = {};
  for (const key of [...own, ...methods]) {
    if (typeof legacy[key] === 'function' && /call|register|trigger/i.test(key)) {
      functions[key] = String(legacy[key]).slice(0, 2500);
    }
  }
  return {
    legacy: { own, methods, functions },
    register: String(window.channel.registerCall).slice(0, 1800),
    nativeEvents: window.channel.viewCall().filter(name => /audioplayer|player\./i.test(name)),
    webpackFirstChunkKeys: window.webpackJsonp.slice(0, 2).map(chunk => ({ ids: chunk[0], modules: Object.keys(chunk[1] || {}).length })),
  };
})()
