(() => {
  const sdk = window.__ncmGaplessProbeRequire.c[4].exports;
  const inspect = object => {
    const prototype = Object.getPrototypeOf(object);
    return Object.fromEntries(Object.getOwnPropertyNames(prototype).filter(key => {
      const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
      return key !== 'constructor' && typeof descriptor.value === 'function';
    }).map(key => [key, /request|download|fetch|file|cache/i.test(key) ? String(prototype[key]).slice(0, 4500) : 'function']));
  };
  return { network: inspect(sdk.Network), storage: inspect(sdk.Storage), bridge: Object.keys(sdk.Bridge._Adapter.registerCallMap).filter(key => /network|file|download/i.test(key)) };
})()
