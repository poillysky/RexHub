// PlayerSign 四头（X-Khronos / X-Gorgon / X-Argus / X-Ladon）。
// 逐行移植自 聚合短剧WorkerA v2.6.8 的 playerSignJstv / playerBranchOf（沙箱验通版）。
// AES 段用 node:crypto 的 AES-128-CBC 等价实现，替代原版的逐字节 _expandKey/_encryptBlock。
import nodeCrypto from 'node:crypto';
import { md5, sm3 } from './crypto.js';

const MASK = (1n << 64n) - 1n;
const utf8 = (value) => new TextEncoder().encode(String(value ?? ''));
const hexToBytes = (value) => Uint8Array.from(Buffer.from(String(value).replace(/\s+/g, ''), 'hex'));
const bytesToHex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const concatBytes = (...xs) => xs.flatMap((x) => Array.from(x));
const md5Bytes = (data) => md5(data);
const sm3Bytes = (data) => sm3(data);

function rot(x, n) {
  n = ((n % 64) + 64) % 64;
  const bn = BigInt(n);
  return ((x << bn) | (x >> BigInt(64 - n))) & MASK;
}
function vi(n) {
  let v = BigInt(n);
  const out = [];
  while (v > 127n) { out.push(Number(v & 127n) | 128); v >>= 7n; }
  out.push(Number(v));
  return out;
}
const field = (n, v) => vi(BigInt(n) * 8n).concat(vi(BigInt(v)));
const bytesField = (n, v) => {
  const b = Array.from(v);
  return vi(BigInt(n) * 8n + 2n).concat(vi(BigInt(b.length)), b);
};
function u64le(buf, off) {
  let x = 0n;
  for (let i = 7; i >= 0; i--) x = (x << 8n) | BigInt(buf[off + i] & 255);
  return x;
}
function w64le(out, off, x) {
  let v = BigInt(x);
  for (let i = 0; i < 8; i++) { out[off + i] = Number(v & 255n); v >>= 8n; }
}
function pad16(arr) {
  const n = 16 - (arr.length % 16);
  const out = arr.slice();
  for (let i = 0; i < n; i++) out.push(n);
  return out;
}
function rev8(x) {
  let n = 0;
  for (let j = 0; j < 8; j++) n = (n << 1) | ((x >> j) & 1);
  return n;
}

function argus(query, bodyBytes, ts, device, nonce) {
  const key = Array.from(hexToBytes('ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c'));
  const bh = sm3Bytes(bodyBytes && bodyBytes.length ? md5Bytes(bodyBytes) : new Uint8Array(16));
  const qh = sm3Bytes(utf8(query));
  const counters = [].concat(field(1, 1), field(2, 1), field(3, 1), field(7, 3348294860));
  const env = [].concat(
    bytesField(1, utf8('25053RT47C')),
    bytesField(2, utf8('16')),
    bytesField(3, utf8('update_64')),
    field(4, 2147483648),
  );
  const nonceField = ((nonce[6] & 255) | ((nonce[7] & 255) << 8) | ((nonce[8] & 255) << 16) | ((nonce[9] & 255) << 24)) & 0x7fffffff;
  let msg = [];
  msg = msg.concat(field(1, 0x20200929 * 2));
  msg = msg.concat(field(2, 2));
  msg = msg.concat(field(3, nonceField));
  msg = msg.concat(bytesField(4, utf8('8662')));
  msg = msg.concat(bytesField(5, utf8(String(device || ''))));
  msg = msg.concat(bytesField(6, utf8('1611921764')));
  msg = msg.concat(bytesField(7, utf8('7.3.5.32')));
  msg = msg.concat(bytesField(8, utf8('v04.07.01-ml-android')));
  msg = msg.concat(field(9, 135135744));
  msg = msg.concat(bytesField(10, [0, 0, 0, 0, 0, 0, 0, 0]));
  msg = msg.concat(field(11, 0));
  msg = msg.concat(field(12, BigInt(ts) * 2n));
  msg = msg.concat(bytesField(13, Array.from(bh.slice(0, 6))));
  msg = msg.concat(bytesField(14, Array.from(qh.slice(0, 6))));
  msg = msg.concat(bytesField(15, counters));
  msg = msg.concat(bytesField(16, []));
  msg = msg.concat(bytesField(20, utf8('none')));
  msg = msg.concat(field(21, 738));
  msg = msg.concat(bytesField(23, env));
  msg = msg.concat(field(25, 2));
  let data = pad16(msg);
  const derived = sm3Bytes(concatBytes(key, [0x3c, 0xcc, 0x56, 0x7b], key));
  const rounds = [];
  for (let i = 0; i < 4; i++) rounds.push(u64le(derived, i * 8));
  for (let i = 4; i < 72; i++) {
    let mixed = rot(rounds[i - 1], -3) ^ rounds[i - 3];
    mixed ^= rot(mixed, -1);
    rounds.push(((~rounds[i - 4]) ^ mixed ^ ((0x3dc94c3a046d678bn >> BigInt((i - 4) % 62)) & 1n) ^ 3n) & MASK);
  }
  for (let off = 0; off < data.length; off += 16) {
    let l = u64le(data, off);
    let r = u64le(data, off + 8);
    for (const round of rounds) {
      const nl = r;
      const nr = (l ^ (rot(r, 1) & rot(r, 8)) ^ rot(r, 2) ^ round) & MASK;
      l = nl;
      r = nr;
    }
    w64le(data, off, l);
    w64le(data, off + 8, r);
  }
  const xorPat = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (let i = 0; i < data.length; i++) data[i] ^= xorPat[i % 8];
  const rev = xorPat.concat(data).reverse();
  const container = pad16([0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18].concat(rev, [0x56, 0x7b]));
  // 等价于原版 AES-128-CBC(key=md5(key[0:16]), iv=md5(key[16:32]))，container 已自行填充。
  const cipher = nodeCrypto.createCipheriv('aes-128-cbc', md5Bytes(key.slice(0, 16)), md5Bytes(key.slice(16, 32)));
  cipher.setAutoPadding(false);
  const encrypted = Buffer.concat([cipher.update(Buffer.from(container)), cipher.final()]);
  return b64([0x3c, 0xcc, ...encrypted]);
}

function ladon(aid, ts, prefix) {
  const digest = Array.from(utf8(bytesToHex(md5Bytes(concatBytes(Array.from(prefix), utf8(String(aid)))))));
  let l = u64le(digest, 0);
  let r = u64le(digest, 8);
  const queue = [u64le(digest, 16), u64le(digest, 24)];
  const keys = [];
  for (let i = 0; i < 34; i++) {
    keys.push(l);
    const mixed = ((rot(r, -8) + l) & MASK) ^ BigInt(i);
    queue.push(mixed);
    l = (mixed ^ rot(l, 3)) & MASK;
    r = queue.shift();
  }
  const data = pad16(Array.from(utf8(String(ts) + '-1611921764-' + String(aid))));
  for (let off = 0; off < data.length; off += 16) {
    let bl = u64le(data, off);
    let br = u64le(data, off + 8);
    for (const key of keys) {
      br = (key ^ ((bl + rot(br, -8)) & MASK)) & MASK;
      bl = (br ^ rot(bl, 3)) & MASK;
    }
    w64le(data, off, bl);
    w64le(data, off + 8, br);
  }
  return b64([...prefix, ...data]);
}

export function playerSignJstv(url, bodyBytes, ts, nonce) {
  const s = String(url);
  const qi = s.indexOf('?');
  const query = qi < 0 ? '' : s.slice(qi + 1);
  const p = new Array(20).fill(0);
  const qm = md5Bytes(utf8(query));
  for (let i = 0; i < 4; i++) p[i] = qm[i];
  if (bodyBytes && bodyBytes.length) {
    const bm = md5Bytes(bodyBytes);
    for (let i = 0; i < 4; i++) p[4 + i] = bm[i];
  }
  p[13] = 6;
  p[14] = 11;
  p[15] = 28;
  p[16] = (ts >>> 24) & 255;
  p[17] = (ts >>> 16) & 255;
  p[18] = (ts >>> 8) & 255;
  p[19] = ts & 255;
  const gk = hexToBytes('44b9b9d9a4aef9fca493aa757ca3c2c4a496938f');
  for (let i = 0; i < 20; i++) p[i] ^= gk[i];
  for (let i = 0; i < 20; i++) {
    const x = (((p[i] << 4) | (p[i] >> 4)) & 255) ^ p[(i + 1) % 20];
    p[i] = rev8(x) ^ 255 ^ 20;
  }
  let device = '';
  let aid = '8662';
  for (const pair of query.split('&')) {
    const eq = pair.indexOf('=');
    if (eq < 0) continue;
    const k = pair.slice(0, eq);
    const v = pair.slice(eq + 1);
    if (k === 'device_id') device = decodeURIComponent(v);
    else if (k === 'aid') aid = decodeURIComponent(v);
  }
  return {
    'X-Khronos': String(ts),
    'X-Gorgon': bytesToHex([0x84, 4, 0x40, 0x1c, 0, 0].concat(p)),
    'X-Argus': argus(query, bodyBytes, ts, device, nonce),
    'X-Ladon': ladon(aid, ts, nonce.slice(2, 6)),
  };
}

function getIv(iv, data) {
  let value = iv;
  for (let i = 0; i < data.length; i++) {
    const d = data[i] & 0xff;
    if ((i & 1) === 0) value = ((value >>> 4) ^ value ^ (value << 6) ^ d) | 0;
    else value = ~((value >>> 7) ^ value ^ (d | (value << 12)));
  }
  return value;
}

// 返回签名分支；分支为 1 时上游会拒，调用方递增 _rticket 重算。
export function playerBranchOf(url, bodyBytes, ts) {
  const bodyMd5 = bodyBytes && bodyBytes.length ? md5Bytes(bodyBytes) : new Uint8Array(16);
  const s = String(url);
  const qi = s.indexOf('?');
  const q = sm3Bytes(utf8(qi < 0 ? '' : s.slice(qi + 1)));
  const le = [ts & 255, (ts >>> 8) & 255, (ts >>> 16) & 255, (ts >>> 24) & 255];
  const iv = getIv(getIv(getIv(0x20230928, q), bodyMd5), le);
  const low = iv & 15;
  return low - (((low * 171) >> 9) * 3);
}
