(() => {
  const require = window.__ncmGaplessProbeRequire;
  const exports = require.c[4].exports;
  const relevant = [];
  for (const [id, module] of Object.entries(require.c)) {
    const root = module.exports;
    const keys = root && ['object', 'function'].includes(typeof root) ? Object.keys(root) : [];
    if (keys.some(key => /Hacky|Cmder|store|dva|dispatch|NativeCall/i.test(key))) {
      relevant.push({ id, keys: keys.filter(key => /Hacky|Cmder|store|dva|dispatch|NativeCall/i.test(key)) });
    }
  }
  const nodes = [document.getElementById('root')._reactRootContainer._internalRoot.current];
  const stores = [];
  const visited = new Set();
  while (nodes.length && visited.size < 300) {
    const fiber = nodes.pop();
    if (!fiber || visited.has(fiber)) continue;
    visited.add(fiber);
    const store = fiber.memoizedProps && (fiber.memoizedProps.store || (fiber.memoizedProps.value && fiber.memoizedProps.value.store));
    if (store && typeof store.getState === 'function' && !stores.includes(store)) stores.push(store);
    if (fiber.child) nodes.push(fiber.child);
    if (fiber.sibling) nodes.push(fiber.sibling);
  }
  return {
    sdkExports: Object.keys(exports), relevant,
    sdkObjects: Object.fromEntries(Object.entries(exports).filter(([key, value]) => value && typeof value === 'object' && /cmder|native|bridge/i.test(key)).map(([key, value]) => [key, { keys: Object.keys(value), methods: Object.getOwnPropertyNames(Object.getPrototypeOf(value)) }])),
    storeFound: stores.length,
    stores: stores.map(store => ({ keys: Object.keys(store.getState()), matchesOldPatch: store === window.__ncmGapless?._store })),
  };
})()
