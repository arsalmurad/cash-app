import assert from 'node:assert/strict';
import { test } from 'node:test';
import { verifyElf, verifySegments } from './verify_android_release_artifact.mjs';

function header(machine) {
  const bytes = Buffer.alloc(64);
  bytes.set([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  bytes.writeUInt16LE(3, 16);
  bytes.writeUInt16LE(machine, 18);
  bytes.writeUInt32LE(1, 20);
  bytes.writeUInt16LE(64, 52);
  return bytes;
}

test('accepts ELF64 shared-object headers for the exact expected machine', () => {
  verifyElf(header(183), 'arm64-v8a');
  verifyElf(header(62), 'x86_64');
});

test('rejects mislabelled, truncated, non-ELF and wrong-format libraries', () => {
  assert.throws(() => verifyElf(header(62), 'arm64-v8a'), /machine/);
  assert.throws(() => verifyElf(header(183), 'x86_64'), /machine/);
  assert.throws(() => verifyElf(Buffer.alloc(8), 'arm64-v8a'), /Complete/);
  assert.throws(() => verifyElf(Buffer.alloc(64), 'arm64-v8a'), /Real ELF/);
  for (const [offset, value] of [[4, 1], [5, 2], [6, 0], [16, 2], [20, 0], [52, 52]]) {
    const bytes = header(183);
    bytes[offset] = value;
    assert.throws(() => verifyElf(bytes, 'arm64-v8a'));
  }
  assert.throws(() => verifyElf(header(183), 'arbitrary'), /supported/);
});

function segments() {
  const bytes = Buffer.alloc(176);
  header(183).copy(bytes);
  bytes.writeBigUInt64LE(64n, 32);
  bytes.writeUInt16LE(56, 54);
  bytes.writeUInt16LE(2, 56);
  bytes.writeUInt32LE(1, 64);
  bytes.writeBigUInt64LE(16384n, 64 + 48);
  bytes.writeUInt32LE(0x6474e552, 120);
  bytes.writeBigUInt64LE(16380n, 120 + 16);
  bytes.writeBigUInt64LE(4n, 120 + 40);
  return bytes;
}

test('requires every LOAD alignment and RELRO end to satisfy the 16 KB checks', () => {
  assert.deepEqual(verifySegments(segments()), {
    loadAlignments: ['16384'], relroEnds: ['16384'], relroLayouts: ['aligned-end'],
  });
  for (const [offset, value] of [[112, 4096n], [112, 24576n], [72, 1n], [160, 3n]]) {
    const bytes = segments();
    bytes.writeBigUInt64LE(value, offset);
    assert.throws(() => verifySegments(bytes));
  }
  const noLoad = segments();
  noLoad.writeUInt32LE(0, 64);
  assert.throws(() => verifySegments(noLoad), /LOAD/);
  const truncated = segments().subarray(0, 175);
  assert.throws(() => verifySegments(truncated), /bounded/);
  const overflow = segments();
  overflow.writeBigUInt64LE(0xffffffffffffffffn, 32);
  assert.throws(() => verifySegments(overflow), /bounded/);
});

test('permits the verified whole-LOAD RELRO layout but refuses an unaligned partial region', () => {
  const bytes = segments();
  bytes.writeUInt32LE(6, 64 + 4);
  bytes.writeBigUInt64LE(4096n, 64 + 40);
  bytes.writeBigUInt64LE(0n, 120 + 16);
  bytes.writeBigUInt64LE(4096n, 120 + 40);
  assert.deepEqual(verifySegments(bytes).relroLayouts, ['whole-load']);
  const overlapping = Buffer.alloc(232);
  bytes.copy(overlapping);
  overlapping.writeUInt16LE(3, 56);
  overlapping.writeUInt32LE(1, 176);
  overlapping.writeUInt32LE(6, 180);
  overlapping.writeBigUInt64LE(8192n, 176 + 8);
  overlapping.writeBigUInt64LE(8192n, 176 + 16);
  overlapping.writeBigUInt64LE(4096n, 176 + 40);
  overlapping.writeBigUInt64LE(16384n, 176 + 48);
  assert.throws(() => verifySegments(overlapping), /Partial RELRO/);
  bytes.writeBigUInt64LE(8192n, 64 + 40);
  assert.throws(() => verifySegments(bytes), /Partial RELRO/);
});
