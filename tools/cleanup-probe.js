(() => {
  const sdk = window.__ncmGaplessProbeRequire && Object.values(window.__ncmGaplessProbeRequire.c).map(module => module.exports).find(value => value && value.AudioPlayer && value.Bridge);
  const temporaryPrefetchHookRestored = sdk ? !Object.prototype.hasOwnProperty.call(sdk.AudioPlayer, 'setPreloadInfoResult') : null;
  delete window.__ncmGaplessProbeRequire;
  return {
    probeRemoved: !Object.prototype.hasOwnProperty.call(window, '__ncmGaplessProbeRequire'),
    temporaryPrefetchHookRestored,
    audioCoreRemoved: !Object.prototype.hasOwnProperty.call(window, 'NcmGaplessCore'),
    previousExperimentPresent: !!window.__ncmGapless,
    productionPatchInstalled: false,
  };
})()
