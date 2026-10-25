(() => ({
  userAgent: navigator.userAgent,
  page: location.protocol + '//' + location.host + location.pathname,
  globals: Object.keys(window).filter(key => /channel|webpack|store|cmder|player|betterncm/i.test(key)),
  channel: window.channel ? Object.keys(window.channel).map(key => [key, typeof window.channel[key]]) : null,
  audio: { context: typeof window.AudioContext, worklet: typeof window.AudioWorkletNode, offline: typeof window.OfflineAudioContext },
  webpackChunks: window.webpackJsonp && window.webpackJsonp.length,
}))()
