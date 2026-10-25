(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NcmGaplessEngine = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  class Engine {
    constructor(context, options) {
      this.context = context;
      this.options = options || {};
      this.master = context.createGain();
      this.master.connect(this.options.output || context.destination);
      this.current = null; this.next = null; this.rate = 1; this.epoch = 0;
      this.playing = false; this.pausedPosition = 0;
    }
    setVolume(volume) {
      if (!Number.isFinite(volume)) return;
      this.master.gain.setValueAtTime(Math.max(0, Math.min(1, volume)), this.context.currentTime);
    }
    position() {
      if (!this.current) return 0;
      if (!this.playing) return this.pausedPosition;
      return Math.max(0, Math.min(this.current.buffer.duration,
        this.current.offset + (this.context.currentTime - this.current.start) * this.rate));
    }
    _stop(entry) {
      if (!entry?.source) return;
      entry.cancelled = true;
      try { entry.source.stop(); } catch (_) {}
      try { entry.source.disconnect(); entry.gain.disconnect(); } catch (_) {}
      entry.source = null;
    }
    _schedule(entry, when, offset) {
      const epoch = this.epoch;
      const source = this.context.createBufferSource();
      const gain = this.context.createGain();
      gain.gain.value = Math.pow(10, (Number(entry.info?.volumeDelta) || 0) / 20);
      source.buffer = entry.buffer;
      source.playbackRate.value = this.rate;
      source.connect(gain); gain.connect(this.master);
      Object.assign(entry, { source, gain, start: when, offset: offset || 0,
        end: when + (entry.buffer.duration - (offset || 0)) / this.rate, cancelled: false });
      source.onended = () => {
        if (entry.cancelled || this.epoch !== epoch || this.current !== entry) return;
        this.playing = false;
        this.pausedPosition = entry.buffer.duration;
        const following = this.next;
        if (following && !following.cancelled) {
          this.current = following; this.next = null; this.playing = true;
          this.pausedPosition = 0;
        }
        try { source.disconnect(); gain.disconnect(); } catch (_) {}
        this.options.onBoundary?.(entry, following || null);
      };
      source.start(entry.start, entry.offset, Math.max(0, entry.buffer.duration - entry.offset));
      return entry;
    }
    load(entry) {
      this.clear(); this.current = entry; this.pausedPosition = 0;
    }
    async play() {
      if (!this.current) return;
      if (this.playing) { await this.context.resume(); return; }
      await this.context.resume();
      const offset = Math.min(this.pausedPosition, Math.max(0, this.current.buffer.duration - 1 / this.context.sampleRate));
      this.playing = true;
      if (!this.current.source) {
        const when = Math.ceil((this.context.currentTime + 0.06) * this.context.sampleRate) / this.context.sampleRate;
        this._schedule(this.current, when, offset);
        if (this.next) this._schedule(this.next, this.current.end, 0);
      }
    }
    async pause() {
      if (!this.current) return;
      await this.context.suspend();
      if (this.current.source) this.pausedPosition = Math.max(0, Math.min(this.current.buffer.duration,
        this.current.offset + (this.context.currentTime - this.current.start) * this.rate));
      this.playing = false;
    }
    queue(entry) {
      this._stop(this.next); this.next = null;
      if (!this.current || !entry) return false;
      // A late download may never be reported as a seamless transition.
      if (this.current.source && this.current.end < this.context.currentTime + 0.06) return false;
      this.next = entry;
      if (this.current.source) this._schedule(entry, this.current.end, 0);
      return true;
    }
    cancelNext() { this._stop(this.next); this.next = null; }
    async seek(position, rate) {
      if (!this.current) return;
      const resume = this.playing;
      const offset = Math.max(0, Math.min(this.current.buffer.duration - 1 / this.context.sampleRate, position));
      this.epoch++;
      this._stop(this.current); this._stop(this.next);
      this.pausedPosition = offset;
      if (rate !== undefined) this.rate = rate;
      this.playing = false;
      if (resume) await this.play();
    }
    async setRate(rate) {
      if (!Number.isFinite(rate) || rate < 0.25 || rate > 4) throw new Error('PLAYBACK_RATE_INVALID');
      // The official client reapplies the selected speed after every Load.
      // Restarting an already scheduled source here inserts startup latency
      // into the second track even though its boundary was sample aligned.
      if (rate === this.rate) return;
      const position = this.position();
      await this.seek(position, rate);
    }
    clear() {
      this.epoch++;
      this._stop(this.current); this._stop(this.next);
      this.current = null; this.next = null; this.playing = false; this.pausedPosition = 0;
    }
    async close() { this.clear(); this.master.disconnect(); await this.context.close(); }
  }

  return Object.freeze({ Engine: Engine });
});
