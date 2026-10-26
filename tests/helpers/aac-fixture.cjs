// Metadata-only MP4 boxes. Decoder/PCM tests separately use generated media.
function box(type, ...parts) {
  const payload = Buffer.concat(parts), out = Buffer.alloc(payload.length + 8);
  out.writeUInt32BE(out.length); out.write(type, 4); payload.copy(out, 8); return out;
}
function header(scale, duration) {
  const bytes = Buffer.alloc(24); bytes.writeUInt32BE(scale, 12); bytes.writeUInt32BE(duration, 16); return bytes;
}
function timingFixture({ sampleRate = 48000, mediaScale = sampleRate, movieScale = 1000, editDuration = 230,
  mediaTime = 1024 * mediaScale / sampleRate, rows = [[12, 1024 * mediaScale / sampleRate]] } = {}) {
  const ticks = rows.reduce((sum, [count, delta]) => sum + count * delta, 0);
  const tkhd = Buffer.alloc(24); tkhd.writeUInt32BE(editDuration, 20);
  const elst = Buffer.alloc(20); elst.writeUInt32BE(1, 4); elst.writeUInt32BE(editDuration, 8); elst.writeInt32BE(mediaTime, 12); elst.writeInt16BE(1, 16);
  const hdlr = Buffer.alloc(12); hdlr.write('soun', 8);
  const mp4a = Buffer.alloc(28); mp4a.writeUInt32BE(sampleRate * 65536, 24);
  const stsd = Buffer.alloc(8); stsd.writeUInt32BE(1, 4);
  const stts = Buffer.alloc(8 + rows.length * 8); stts.writeUInt32BE(rows.length, 4);
  rows.forEach(([count, delta], index) => { stts.writeUInt32BE(count, 8 + index * 8); stts.writeUInt32BE(delta, 12 + index * 8); });
  const bytes = box('moov', box('mvhd', header(movieScale, editDuration)), box('trak', box('tkhd', tkhd), box('edts', box('elst', elst)),
    box('mdia', box('mdhd', header(mediaScale, ticks)), box('hdlr', hdlr), box('minf', box('stbl', box('stsd', stsd, box('mp4a', mp4a)), box('stts', stts))))));
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}
module.exports = { timingFixture };
