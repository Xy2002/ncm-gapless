(() => {
  const require = window.__ncmGaplessProbeRequire;
  const module = require.c[18] && require.c[18].exports;
  const exports = module && Object.fromEntries(Object.entries(module).map(([key, value]) => [key, typeof value === 'function' && String(value).length < 2200 ? String(value) : typeof value]));
  const roots = Array.from(document.querySelectorAll('body > div')).map(node => ({ id: node.id, keys: Object.keys(node).filter(key => /react/i.test(key)), legacyRoot: !!node._reactRootContainer }));
  const globals = Object.getOwnPropertyNames(window).filter(key => /dva|g_app|redux|appstore/i.test(key));
  return { exports, roots, globals, oldPatchActive: window.__ncmGapless && { version: window.__ncmGapless.version, playing: window.__ncmGapless.stats.playing, position: window.__ncmGapless.stats.position, pcmEvents: window.__ncmGapless.stats.pcmEvents, triggers: window.__ncmGapless.stats.triggers } };
})()
