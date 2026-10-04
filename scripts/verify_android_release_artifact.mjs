// Packaging evidence only. Never installs or executes a phone artifact.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const machines = { 'arm64-v8a': 183, x86_64: 62 };

export function verifyElf(bytes, abi) {
  assert(Object.hasOwn(machines, abi), 'Only explicitly supported 64-bit ABIs');
  assert(bytes.length >= 64, 'Complete ELF64 header required');
  assert.equal(bytes.subarray(0, 4).toString('hex'), '7f454c46', 'Real ELF library required');
  assert.equal(bytes[4], 2, 'ELF must be 64-bit');
  assert.equal(bytes[5], 1, 'ELF must be little-endian');
  assert.equal(bytes[6], 1, 'ELF identification version');
  assert.equal(bytes.readUInt16LE(16), 3, 'ELF must be a shared object');
  assert.equal(bytes.readUInt16LE(18), machines[abi], 'ELF machine must match the declared ABI');
  assert.equal(bytes.readUInt32LE(20), 1, 'ELF header version');
  assert.equal(bytes.readUInt16LE(52), 64, 'ELF64 header size');
}

// Android's published 16 KB checks, including the linker's whole-LOAD exception.
// https://developer.android.com/guide/practices/page-sizes
// https://android.googlesource.com/platform/bionic/+/android16-qpr2-release/linker/linker_phdr_16kib_compat.cpp
export function verifySegments(bytes) {
  assert(bytes.length >= 64, 'Complete ELF64 header required');
  const offset = bytes.readBigUInt64LE(32);
  const size = bytes.readUInt16LE(54), count = bytes.readUInt16LE(56);
  assert.equal(size, 56, 'ELF64 program header size');
  assert(count > 0 && offset >= 64n && offset + BigInt(size * count) <= BigInt(bytes.length),
    'Complete bounded program-header table required');
  const loads = [], loadRanges = [], relros = [];
  for (let index = 0; index < count; index++) {
    const start = Number(offset) + size * index;
    const type = bytes.readUInt32LE(start);
    const flags = bytes.readUInt32LE(start + 4);
    const fileOffset = bytes.readBigUInt64LE(start + 8);
    const address = bytes.readBigUInt64LE(start + 16);
    const memorySize = bytes.readBigUInt64LE(start + 40);
    const alignment = bytes.readBigUInt64LE(start + 48);
    if (type === 1) {
      assert(alignment >= 16384n && (alignment & (alignment - 1n)) === 0n,
        'Every LOAD segment requires at least 16 KB power-of-two alignment');
      assert.equal(fileOffset % 16384n, address % 16384n, 'LOAD file/address congruence');
      loads.push(alignment.toString());
      loadRanges.push({ address, end: address + memorySize, flags });
    } else if (type === 0x6474e552) {
      relros.push({ address, end: address + memorySize });
    }
  }
  assert(loads.length > 0, 'At least one LOAD segment required');
  const relroLayouts = relros.map(relro => {
    if (relro.end % 16384n === 0n) return 'aligned-end';
    // Bionic explicitly exempts a RELRO occupying the entire LOAD segment.
    // Its end need not be aligned if rounding protection cannot cover writable data.
    const entire = loadRanges.find(load => load.address === relro.address && load.end === relro.end);
    const protectedStart = relro.address - relro.address % 16384n;
    const protectedEnd = (relro.end + 16383n) / 16384n * 16384n;
    const overlapsWritable = loadRanges.some(load => load !== entire && (load.flags & 2) &&
      load.address < protectedEnd && load.end > protectedStart);
    assert(entire && !overlapsWritable, 'Partial RELRO end requires 16 KB alignment');
    return 'whole-load';
  });
  return { loadAlignments: loads, relroEnds: relros.map(relro => relro.end.toString()), relroLayouts };
}

export async function verifyArtifact(abi) {
  assert(Object.hasOwn(machines, abi), 'Choose arm64-v8a or x86_64');
  const apk = join(root, `app/build/app/outputs/flutter-apk/app-${abi}-release.apk`);
  const aapt = process.env.AAPT_BINARY ?? 'D:/Android/Sdk/build-tools/36.0.0/aapt2.exe';
  const jar = process.env.JAR_BINARY ?? 'D:/cash-app-toolchains/jdk17/bin/jar.exe';
  const zipalign = process.env.ZIPALIGN_BINARY ?? 'D:/Android/Sdk/build-tools/36.0.0/zipalign.exe';
  const options = { windowsHide: true, timeout: 30_000, maxBuffer: 4 * 1024 * 1024 };
  const badging = (await run(aapt, ['dump', 'badging', apk], options)).stdout;
  assert.match(badging, /package: name='app\.privateledger\.private_ledger'/);
  assert.equal(badging.match(/^native-code: (.+)$/m)?.[1].trim(), `'${abi}'`, 'Exactly one declared ABI');
  assert(!badging.includes('application-debuggable'), 'Release must not be debuggable');
  const inventory = (await run(jar, ['tf', apk], options)).stdout.split(/\r?\n/).filter(Boolean);
  const libraries = inventory.filter(entry => entry.startsWith('lib/') && entry.endsWith('.so'));
  assert(libraries.length > 0, 'Native libraries required');
  assert.equal(new Set(libraries).size, libraries.length, 'No duplicate native entries');
  for (const entry of libraries) {
    assert.match(entry, /^lib\/(arm64-v8a|x86_64)\/[A-Za-z0-9_]+\.so$/, 'Only safe library extraction paths');
    assert.equal(entry.split('/')[1], abi, 'No stray ABI libraries');
  }
  for (const name of ['libapp.so', 'libflutter.so', 'librust_lib_cash_app.so']) {
    assert(libraries.includes(`lib/${abi}/${name}`), `Actual ${name} required`);
  }
  const alignment = (await run(zipalign, ['-v', '-c', '-P', '16', '4', apk], options)).stdout;
  assert(alignment.includes('Verification successful'), 'APK ZIP alignment must pass the Android tool');
  // Only the exact safe library entries above, in this invocation's fresh temp directory.
  const temporary = await mkdtemp(join(tmpdir(), 'cash-app-apk-inventory-'));
  const summaries = [], alignmentErrors = [];
  try {
    await run(jar, ['xf', apk, ...libraries], { ...options, cwd: temporary });
    for (const entry of libraries) {
      const bytes = await readFile(join(temporary, entry));
      let segments;
      try {
        verifyElf(bytes, abi);
      } catch (error) {
        throw new Error(`${entry}: ${error.message}`, { cause: error });
      }
      try {
        segments = verifySegments(bytes);
      } catch (error) {
        alignmentErrors.push(`${entry}: ${error.message}`);
        segments = { alignmentError: error.message };
      }
      summaries.push({ entry, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), ...segments });
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
  const bytes = await readFile(apk);
  const result = {
    apk, abi, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
    package: badging.split(/\r?\n/).find(line => line.startsWith('package: ')),
    libraries: summaries,
    zipAlignment: 'zipalign -v -c -P 16 4: Verification successful',
    alignmentErrors,
    scope: 'Packaging/ELF verification only; no device execution or store-signing claim.',
  };
  console.log(JSON.stringify(result, null, 2));
  assert.equal(alignmentErrors.length, 0, 'Every packaged library must pass 16 KB ELF/RELRO checks');
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 3, 'Usage: node scripts/verify_android_release_artifact.mjs arm64-v8a|x86_64');
  await verifyArtifact(process.argv[2]);
}
