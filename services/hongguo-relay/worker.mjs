const RELAY_VERSION = "3.0.1";

// ============================================================
// AGG_CRYPTO · 聚合模块共用纯 JS 密码学 (Rex/JSCore 无 crypto 接口,
// 在册 ONE 模块同为自带实现)。当前供野果: AES-128-CBC 解密接口回包。
// SBOX 由 GF(2^8) 生成 (不转录表, 降低抄错面), 回测以 NIST 向量
// + Node crypto 随机向量双验。解密口径对齐 upload-13.py 的
// _aes_raw: 先截断到 16 的倍数, 末字节值 1..16 才截尾、不验填充内容。
// ============================================================
const AGG_CRYPTO = (() => {
  function xtime(a) { a <<= 1; if (a & 0x100) a ^= 0x11b; return a & 0xff; }
  function gmul(a, b) { let r = 0; while (b) { if (b & 1) r ^= a; a = xtime(a); b >>= 1; } return r; }

  // ---- SBOX 生成: 乘法逆 (生成元 3 的 log/exp 表) + 仿射变换 ----
  const EXP = new Array(512), LOG = new Array(256);
  let _x = 1;
  for (let i = 0; i < 255; i++) { EXP[i] = _x; LOG[_x] = i; _x = gmul(_x, 3); }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
  function rotl8(v, n) { return ((v << n) | (v >> (8 - n))) & 0xff; }
  const SBOX = new Array(256), INV_SBOX = new Array(256);
  for (let i = 0; i < 256; i++) {
    const inv = i === 0 ? 0 : EXP[255 - LOG[i]];
    const s = (inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63) & 0xff;
    SBOX[i] = s; INV_SBOX[s] = i;
  }
  const RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

  function expandKey(key) {
    const w = [];
    for (let i = 0; i < 16; i++) w.push(key[i]);
    for (let i = 4; i < 44; i++) {
      let t0 = w[(i - 1) * 4], t1 = w[(i - 1) * 4 + 1], t2 = w[(i - 1) * 4 + 2], t3 = w[(i - 1) * 4 + 3];
      if (i % 4 === 0) {
        const r = RCON[i / 4 - 1];
        const n0 = SBOX[t1] ^ r, n1 = SBOX[t2], n2 = SBOX[t3], n3 = SBOX[t0];
        t0 = n0; t1 = n1; t2 = n2; t3 = n3;
      }
      w.push(w[(i - 4) * 4] ^ t0, w[(i - 4) * 4 + 1] ^ t1, w[(i - 4) * 4 + 2] ^ t2, w[(i - 4) * 4 + 3] ^ t3);
    }
    return w;
  }
  function addRoundKey(s, rk, round) { for (let i = 0; i < 16; i++) s[i] ^= rk[round * 16 + i]; }
  function invShiftRows(s) {
    const t = s.slice();
    for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) s[r + 4 * c] = t[r + 4 * ((c - r + 4) % 4)];
  }
  function invSubBytes(s) { for (let i = 0; i < 16; i++) s[i] = INV_SBOX[s[i]]; }
  function invMixColumns(s) {
    for (let c = 0; c < 4; c++) {
      const i = 4 * c, a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
      s[i + 1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
      s[i + 2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
      s[i + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
    }
  }
  function decryptBlock(rk, block) {
    const s = [];
    for (let i = 0; i < 16; i++) s.push(block[i]);
    addRoundKey(s, rk, 10);
    for (let round = 9; round >= 1; round--) {
      invShiftRows(s); invSubBytes(s); addRoundKey(s, rk, round); invMixColumns(s);
    }
    invShiftRows(s); invSubBytes(s); addRoundKey(s, rk, 0);
    return s;
  }

  function strBytes(str) {
    const out = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 0xff;
    return out;
  }

  // AES-CBC 解密 (py _aes_raw 口径: 截断到 16 倍数 + 末字节 1..16 宽松去尾)
  function aesCbcDecrypt(keyBytes, ivBytes, data) {
    const n = data.length - (data.length % 16);
    if (n <= 0) return new Uint8Array(0);
    const rk = expandKey(keyBytes);
    const out = new Uint8Array(n);
    let prev = [];
    for (let i = 0; i < 16; i++) prev.push(ivBytes[i]);
    for (let off = 0; off < n; off += 16) {
      const block = data.slice(off, off + 16);
      const dec = decryptBlock(rk, block);
      for (let i = 0; i < 16; i++) out[off + i] = dec[i] ^ prev[i];
      prev = [];
      for (let i = 0; i < 16; i++) prev.push(block[i]);
    }
    const pad = out[n - 1];
    if (pad >= 1 && pad <= 16) return out.slice(0, n - pad);
    return out;
  }

  const B64T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function b64ToBytes(s) {
    s = String(s || "").replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    const out = [];
    for (let i = 0; i + 3 < s.length + 1 && i < s.length; i += 4) {
      const a = B64T.indexOf(s[i]), b = B64T.indexOf(s[i + 1]);
      if (a < 0 || b < 0) return new Uint8Array(0);
      const c = s[i + 2] === "=" ? 0 : B64T.indexOf(s[i + 2]);
      const d = s[i + 3] === "=" ? 0 : B64T.indexOf(s[i + 3]);
      if (c < 0 || d < 0) return new Uint8Array(0);
      out.push(((a << 2) | (b >> 4)) & 0xff);
      if (s[i + 2] !== "=") out.push(((b & 15) << 4 | (c >> 2)) & 0xff);
      if (s[i + 3] !== "=") out.push(((c & 3) << 6 | d) & 0xff);
    }
    return new Uint8Array(out);
  }

  // UTF-8 解码 (py decode("utf-8","ignore") 口径: 坏序列跳字节)
  function utf8Decode(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length;) {
      const b = bytes[i];
      if (b < 0x80) { out += String.fromCharCode(b); i++; continue; }
      let need = 0, cp = 0;
      if ((b & 0xe0) === 0xc0) { need = 1; cp = b & 0x1f; }
      else if ((b & 0xf0) === 0xe0) { need = 2; cp = b & 0x0f; }
      else if ((b & 0xf8) === 0xf0) { need = 3; cp = b & 0x07; }
      else { i++; continue; }
      let ok = true;
      for (let j = 1; j <= need; j++) {
        if (i + j >= bytes.length || (bytes[i + j] & 0xc0) !== 0x80) { ok = false; break; }
        cp = (cp << 6) | (bytes[i + j] & 0x3f);
      }
      if (!ok) { i++; continue; }
      i += need + 1;
      if (cp > 0xffff) {
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      } else out += String.fromCharCode(cp);
    }
    return out;
  }

  // base64 密文 → 明文字符串 (py _aes_text 等价)
  function aesCbcDecryptText(b64, keyStr, ivStr) {
    const raw = b64ToBytes(b64);
    if (!raw.length) return "";
    return utf8Decode(aesCbcDecrypt(strBytes(keyStr), strBytes(ivStr), raw));
  }

  // ============================================================
  // 以下为 ENGINE AG 增补 (2026-11-08): 正向 AES / GCM / 哈希 / HMAC / RSA。
  // 既有成员语义不变; 新成员均以 Node crypto 对照向量验证 (tests/test-crypto-ag.mjs)。
  // ============================================================
  function subBytesF(s) { for (let i = 0; i < 16; i++) s[i] = SBOX[s[i]]; }
  function shiftRowsF(s) {
    const t = s.slice();
    for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) s[r + 4 * c] = t[r + 4 * ((c + r) % 4)];
  }
  function mixColumnsF(s) {
    for (let c = 0; c < 4; c++) {
      const i = 4 * c, a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3;
      s[i + 1] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3;
      s[i + 2] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3);
      s[i + 3] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2);
    }
  }
  function encryptBlock(rk, block) {
    const s = [];
    for (let i = 0; i < 16; i++) s.push(block[i]);
    addRoundKey(s, rk, 0);
    for (let round = 1; round <= 9; round++) {
      subBytesF(s); shiftRowsF(s); mixColumnsF(s); addRoundKey(s, rk, round);
    }
    subBytesF(s); shiftRowsF(s); addRoundKey(s, rk, 10);
    return s;
  }

  function pkcs7Pad(data) {
    const n = 16 - (data.length % 16);
    const out = new Uint8Array(data.length + n);
    out.set(data);
    for (let i = data.length; i < out.length; i++) out[i] = n;
    return out;
  }
  // py _ag_pkcs7_unpad 口径: 末字节 1..16 才截尾, 不验填充内容
  function unpadLenient(out) {
    if (!out.length) return out;
    const pad = out[out.length - 1];
    if (pad >= 1 && pad <= 16 && pad <= out.length) return out.slice(0, out.length - pad);
    return out;
  }

  function aesCbcEncrypt(keyBytes, ivBytes, data) {
    const rk = expandKey(keyBytes);
    const padded = pkcs7Pad(data);
    const out = new Uint8Array(padded.length);
    let prev = [];
    for (let i = 0; i < 16; i++) prev.push(ivBytes[i]);
    for (let off = 0; off < padded.length; off += 16) {
      const block = [];
      for (let i = 0; i < 16; i++) block.push(padded[off + i] ^ prev[i]);
      const enc = encryptBlock(rk, block);
      for (let i = 0; i < 16; i++) { out[off + i] = enc[i]; prev[i] = enc[i]; }
    }
    return out;
  }
  function aesEcbEncrypt(keyBytes, data) {
    const rk = expandKey(keyBytes);
    const padded = pkcs7Pad(data);
    const out = new Uint8Array(padded.length);
    for (let off = 0; off < padded.length; off += 16) {
      const enc = encryptBlock(rk, padded.slice(off, off + 16));
      for (let i = 0; i < 16; i++) out[off + i] = enc[i];
    }
    return out;
  }
  function aesEcbDecrypt(keyBytes, data) {
    const n = data.length - (data.length % 16);
    if (n <= 0) return new Uint8Array(0);
    const rk = expandKey(keyBytes);
    const out = new Uint8Array(n);
    for (let off = 0; off < n; off += 16) {
      const dec = decryptBlock(rk, data.slice(off, off + 16));
      for (let i = 0; i < 16; i++) out[off + i] = dec[i];
    }
    return unpadLenient(out);
  }

  // ---- AES-GCM 解密 (forge 口径: 密文尾 16B = tag; 失败回 null, py 回 "{}") ----
  function gf128Mul(x, y) {
    const z = new Array(16).fill(0);
    const v = y.slice();
    for (let i = 0; i < 128; i++) {
      if ((x[i >> 3] >> (7 - (i & 7))) & 1) for (let j = 0; j < 16; j++) z[j] ^= v[j];
      const lsb = v[15] & 1;
      for (let j = 15; j > 0; j--) v[j] = ((v[j] >> 1) | ((v[j - 1] & 1) << 7)) & 0xff;
      v[0] = (v[0] >> 1) & 0xff;
      if (lsb) v[0] ^= 0xe1;
    }
    return z;
  }
  function ghash(H, blocks) {
    let y = new Array(16).fill(0);
    for (let off = 0; off + 16 <= blocks.length; off += 16) {
      for (let j = 0; j < 16; j++) y[j] ^= blocks[off + j];
      y = gf128Mul(y, H);
    }
    return y;
  }
  function lenBlock(aadBits, ctBits) {
    const out = new Uint8Array(16);
    const ah = Math.floor(aadBits / 4294967296), al = aadBits >>> 0;
    const ch = Math.floor(ctBits / 4294967296), cl = ctBits >>> 0;
    out[0] = (ah >>> 24) & 0xff; out[1] = (ah >>> 16) & 0xff; out[2] = (ah >>> 8) & 0xff; out[3] = ah & 0xff;
    out[4] = (al >>> 24) & 0xff; out[5] = (al >>> 16) & 0xff; out[6] = (al >>> 8) & 0xff; out[7] = al & 0xff;
    out[8] = (ch >>> 24) & 0xff; out[9] = (ch >>> 16) & 0xff; out[10] = (ch >>> 8) & 0xff; out[11] = ch & 0xff;
    out[12] = (cl >>> 24) & 0xff; out[13] = (cl >>> 16) & 0xff; out[14] = (cl >>> 8) & 0xff; out[15] = cl & 0xff;
    return out;
  }
  function pad16(data) {
    if (data.length % 16 === 0) return data;
    const out = new Uint8Array(data.length + (16 - (data.length % 16)));
    out.set(data);
    return out;
  }
  function aesGcmDecrypt(keyBytes, nonceBytes, data) {
    if (!data || data.length < 16) return null;
    const rk = expandKey(keyBytes);
    const ct = data.slice(0, data.length - 16);
    const tag = data.slice(data.length - 16);
    const H = encryptBlock(rk, new Array(16).fill(0));
    let J0;
    if (nonceBytes.length === 12) {
      J0 = new Array(16);
      for (let i = 0; i < 12; i++) J0[i] = nonceBytes[i];
      J0[12] = 0; J0[13] = 0; J0[14] = 0; J0[15] = 1;
    } else {
      const buf = pad16(nonceBytes);
      const all = new Uint8Array(buf.length + 16);
      all.set(buf);
      all.set(lenBlock(0, nonceBytes.length * 8), buf.length);
      J0 = ghash(H, all);
    }
    const ghInput = new Uint8Array(pad16(ct).length + 16);
    ghInput.set(pad16(ct));
    ghInput.set(lenBlock(0, ct.length * 8), pad16(ct).length);
    const S = ghash(H, ghInput);
    const EJ0 = encryptBlock(rk, J0);
    for (let i = 0; i < 16; i++) if ((S[i] ^ EJ0[i]) !== tag[i]) return null;
    const out = new Uint8Array(ct.length);
    const ctr = J0.slice();
    for (let off = 0; off < ct.length; off += 16) {
      // inc32
      let v = ((ctr[12] << 24) | (ctr[13] << 16) | (ctr[14] << 8) | ctr[15]) + 1;
      ctr[12] = (v >>> 24) & 0xff; ctr[13] = (v >>> 16) & 0xff; ctr[14] = (v >>> 8) & 0xff; ctr[15] = v & 0xff;
      const ks = encryptBlock(rk, ctr);
      const n = Math.min(16, ct.length - off);
      for (let i = 0; i < n; i++) out[off + i] = ct[off + i] ^ ks[i];
    }
    return out;
  }

  // ---- 编码工具 ----
  function utf8Encode(str) {
    const out = [];
    str = String(str == null ? "" : str);
    for (let i = 0; i < str.length; i++) {
      let cp = str.charCodeAt(i);
      if (cp < 0x80) { out.push(cp); continue; }
      if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < str.length) {
        const lo = str.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00); i++; }
      }
      if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
      else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    }
    return new Uint8Array(out);
  }
  function b64FromBytes(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += B64T[(a >> 2) & 63] + B64T[((a & 3) << 4) | (b >> 4)];
      out += i + 1 < bytes.length ? B64T[((b & 15) << 2) | (c >> 6)] : "=";
      out += i + 2 < bytes.length ? B64T[c & 63] : "=";
    }
    return out;
  }
  function hexToBytes(hex) {
    hex = String(hex || "").replace(/\s+/g, "");
    const out = new Uint8Array(Math.floor(hex.length / 2));
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16) & 0xff;
    return out;
  }
  function bytesToHex(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; i++) out += (bytes[i] >>> 4).toString(16) + (bytes[i] & 15).toString(16);
    return out;
  }
  function strToBytes(str) { return strBytes(str); }

  // ---- MD5 ----
  const MD5_S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  const MD5_K = new Array(64);
  for (let i = 0; i < 64; i++) MD5_K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0;
  function md5Bytes(data) {
    const bitLen = data.length * 8;
    const paddedLen = (((data.length + 8) >> 6) + 1) << 6;
    const msg = new Uint8Array(paddedLen);
    msg.set(data);
    msg[data.length] = 0x80;
    const lo = bitLen >>> 0, hi = Math.floor(bitLen / 4294967296);
    for (let i = 0; i < 4; i++) msg[paddedLen - 8 + i] = (lo >>> (8 * i)) & 0xff;
    for (let i = 0; i < 4; i++) msg[paddedLen - 4 + i] = (hi >>> (8 * i)) & 0xff;
    let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    const M = new Array(16);
    for (let off = 0; off < paddedLen; off += 64) {
      for (let i = 0; i < 16; i++) M[i] = (msg[off + 4 * i] | (msg[off + 4 * i + 1] << 8) | (msg[off + 4 * i + 2] << 16) | (msg[off + 4 * i + 3] << 24)) >>> 0;
      let A = a0, B = b0, C = c0, D = d0;
      for (let i = 0; i < 64; i++) {
        let F, g;
        if (i < 16) { F = (B & C) | (~B & D); g = i; }
        else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
        else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * i) % 16; }
        const tmp = D;
        D = C; C = B;
        const sum = (A + F + MD5_K[i] + M[g]) >>> 0;
        const rot = ((sum << MD5_S[i]) | (sum >>> (32 - MD5_S[i]))) >>> 0;
        B = (B + rot) >>> 0;
        A = tmp;
      }
      a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
    }
    const out = new Uint8Array(16);
    const words = [a0, b0, c0, d0];
    for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) out[4 * i + j] = (words[i] >>> (8 * j)) & 0xff;
    return out;
  }
  function md5Hex(str) { return bytesToHex(md5Bytes(utf8Encode(str))); }

  // ---- SHA-1 ----
  function sha1Bytes(data) {
    const bitLen = data.length * 8;
    const paddedLen = (((data.length + 8) >> 6) + 1) << 6;
    const msg = new Uint8Array(paddedLen);
    msg.set(data);
    msg[data.length] = 0x80;
    const lo = bitLen >>> 0, hi = Math.floor(bitLen / 4294967296);
    for (let i = 0; i < 4; i++) msg[paddedLen - 4 + i] = (lo >>> (8 * (3 - i))) & 0xff;
    for (let i = 0; i < 4; i++) msg[paddedLen - 8 + i] = (hi >>> (8 * (3 - i))) & 0xff;
    let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
    const w = new Array(80);
    for (let off = 0; off < paddedLen; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = ((msg[off + 4 * i] << 24) | (msg[off + 4 * i + 1] << 16) | (msg[off + 4 * i + 2] << 8) | msg[off + 4 * i + 3]) >>> 0;
      for (let i = 16; i < 80; i++) { const x = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) >>> 0; w[i] = ((x << 1) | (x >>> 31)) >>> 0; }
      let a = h0, b = h1, c = h2, d = h3, e = h4;
      for (let i = 0; i < 80; i++) {
        let f, k;
        if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
        else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else { f = b ^ c ^ d; k = 0xca62c1d6; }
        const tmp = ((((a << 5) | (a >>> 27)) >>> 0) + f + e + k + w[i]) >>> 0;
        e = d; d = c; c = ((b << 30) | (b >>> 2)) >>> 0; b = a; a = tmp;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
    }
    const out = new Uint8Array(20);
    const hs = [h0, h1, h2, h3, h4];
    for (let i = 0; i < 5; i++) for (let j = 0; j < 4; j++) out[4 * i + j] = (hs[i] >>> (8 * (3 - j))) & 0xff;
    return out;
  }

  // ---- SHA-256 (常数由前 8/64 个素数的平方根/立方根小数部分生成, 向量验证) ----
  function firstPrimes(n) {
    const out = [];
    let c = 2;
    while (out.length < n) {
      let prime = true;
      for (let i = 2; i * i <= c; i++) if (c % i === 0) { prime = false; break; }
      if (prime) out.push(c);
      c++;
    }
    return out;
  }
  function frac32(x) { return Math.floor((x - Math.floor(x)) * 4294967296) >>> 0; }
  const SHA256_H0 = firstPrimes(8).map((p) => frac32(Math.sqrt(p)));
  const SHA256_K = firstPrimes(64).map((p) => frac32(Math.cbrt(p)));
  function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }
  function sha256Bytes(data) {
    const bitLen = data.length * 8;
    const paddedLen = (((data.length + 8) >> 6) + 1) << 6;
    const msg = new Uint8Array(paddedLen);
    msg.set(data);
    msg[data.length] = 0x80;
    const lo = bitLen >>> 0, hi = Math.floor(bitLen / 4294967296);
    for (let i = 0; i < 4; i++) msg[paddedLen - 4 + i] = (lo >>> (8 * (3 - i))) & 0xff;
    for (let i = 0; i < 4; i++) msg[paddedLen - 8 + i] = (hi >>> (8 * (3 - i))) & 0xff;
    const H = SHA256_H0.slice();
    const w = new Array(64);
    for (let off = 0; off < paddedLen; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = ((msg[off + 4 * i] << 24) | (msg[off + 4 * i + 1] << 16) | (msg[off + 4 * i + 2] << 8) | msg[off + 4 * i + 3]) >>> 0;
      for (let i = 16; i < 64; i++) {
        const s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
        const s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }
      let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (let i = 0; i < 64; i++) {
        const S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
        const ch = ((e & f) ^ (~e & g)) >>> 0;
        const t1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
        const S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
        const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
        const t2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    const out = new Uint8Array(32);
    for (let i = 0; i < 8; i++) for (let j = 0; j < 4; j++) out[4 * i + j] = (H[i] >>> (8 * (3 - j))) & 0xff;
    return out;
  }

  // ---- HMAC ----
  function hmac(hashFn, blockSize, keyBytes, msgBytes) {
    let key = keyBytes;
    if (key.length > blockSize) key = hashFn(key);
    const ipad = new Uint8Array(blockSize), opad = new Uint8Array(blockSize);
    for (let i = 0; i < blockSize; i++) {
      const kb = i < key.length ? key[i] : 0;
      ipad[i] = kb ^ 0x36; opad[i] = kb ^ 0x5c;
    }
    const inner = new Uint8Array(blockSize + msgBytes.length);
    inner.set(ipad); inner.set(msgBytes, blockSize);
    const ih = hashFn(inner);
    const outer = new Uint8Array(blockSize + ih.length);
    outer.set(opad); outer.set(ih, blockSize);
    return hashFn(outer);
  }
  function hmacSha256Hex(msgStr, keyStr) {
    return bytesToHex(hmac(sha256Bytes, 64, utf8Encode(keyStr), utf8Encode(msgStr)));
  }
  function hmacSha1Bytes(keyBytes, msgBytes) { return hmac(sha1Bytes, 64, keyBytes, msgBytes); }

  // ---- RSA PKCS#1 v1.5 + SHA-256 签名 (薏米; 依赖 BigInt, 无则回 "" 同 py 失败口径) ----
  function derTlv(buf, off) {
    const tag = buf[off];
    let len = buf[off + 1];
    let hdr = 2;
    if (len & 0x80) {
      const n = len & 0x7f;
      len = 0;
      for (let i = 0; i < n; i++) len = len * 256 + buf[off + 2 + i];
      hdr = 2 + n;
    }
    return { tag: tag, start: off + hdr, end: off + hdr + len, next: off + hdr + len };
  }
  function derChildren(buf, tlv) {
    const out = [];
    let off = tlv.start;
    while (off < tlv.end) { const t = derTlv(buf, off); out.push(t); off = t.next; }
    return out;
  }
  function rsaSignSha256B64(pem, dataStr) {
    try {
      if (typeof BigInt !== "function") return "";
      const b64 = String(pem || "").replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
      const der = b64ToBytes(b64);
      if (!der.length) return "";
      const outer = derTlv(der, 0);
      const parts = derChildren(der, outer);
      if (parts.length < 3) return "";
      const oct = parts[2];
      const innerDer = der.slice(oct.start, oct.end);
      const inner = derTlv(innerDer, 0);
      const ints = derChildren(innerDer, inner);
      if (ints.length < 4) return "";
      function intAt(t) {
        let b = innerDer.slice(t.start, t.end);
        if (b.length > 1 && b[0] === 0) b = b.slice(1);
        return b;
      }
      const nBytes = intAt(ints[1]);
      const dBytes = intAt(ints[3]);
      const k = nBytes.length;
      function toBig(bytes) {
        let h = "0x";
        for (let i = 0; i < bytes.length; i++) h += (bytes[i] >>> 4).toString(16) + (bytes[i] & 15).toString(16);
        return BigInt(h);
      }
      const n = toBig(nBytes), d = toBig(dBytes);
      const digest = sha256Bytes(utf8Encode(dataStr));
      const T = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20];
      for (let i = 0; i < digest.length; i++) T.push(digest[i]);
      const em = new Uint8Array(k);
      em[0] = 0; em[1] = 1;
      const psLen = k - T.length - 3;
      for (let i = 0; i < psLen; i++) em[2 + i] = 0xff;
      em[2 + psLen] = 0;
      em.set(T, 3 + psLen);
      const m = toBig(em);
      let r = 1n, base = m % n, e = d;
      while (e > 0n) { if (e & 1n) r = (r * base) % n; base = (base * base) % n; e >>= 1n; }
      let hex = r.toString(16);
      while (hex.length < k * 2) hex = "0" + hex;
      return b64FromBytes(hexToBytes(hex));
    } catch (err) {
      return "";
    }
  }

  return { aesCbcDecrypt, aesCbcDecryptText, b64ToBytes, utf8Decode, _decryptBlock: decryptBlock, _expandKey: expandKey,
    aesCbcEncrypt, aesEcbEncrypt, aesEcbDecrypt, aesGcmDecrypt,
    utf8Encode, b64FromBytes, hexToBytes, bytesToHex, strToBytes,
    md5Hex, md5Bytes, sha1Bytes, sha256Bytes, hmacSha256Hex, hmacSha1Bytes, rsaSignSha256B64,
    _encryptBlock: encryptBlock, _sha256H0: SHA256_H0, _sha256K: SHA256_K };
})();

// HG 六神常量表 — 由 upload-13.py 程序化提取 (禁止手抄):
// s_box = AES_V3 自定义 S 盒 1024B (4 组 x 256, 按 khronos&3 选组)
// branch1 = _branch_one_bytes() 解压结果 81936B (5 组 x 16KB)
// branch2orders = branch_2_orders 320B; sha512k/h = SHA-512 常量 (质数根小数部生成, 已对拍)
const HG_TABLES = {
  sbox: "+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==",
  branch1: "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",
  branch2orders: "DwcEAAkIAwoGCwUNDgEMAg8FCAwACQIBAwcOBgsKDQQGBQAHDAAKBAgPAQsNCQIOBgsCBQQDCAEBBwoADQwJDg0HDg8LAggDDAUJAQAEBgoNCQIGDwsKBAgHAAwFAwEODAkPBwYPAw4CDQQFAQsKAAwFCgkOCAIEBAcDDwEGCwALDwQIAgoHAAkNBgEOAwUMCwYKBQgCDAMHDw4JDQABBAkGCA8FCAAECgsDDQECDA4JDQwGBAcKAwMPAAgBBQIOAQANDwkKCw4EAggHAwYMBQEICgwPCQUGCwADBAIOBw0ECA8ADA8ODQoBBgIHCQUDBAIFCA0LCgYGAA4PBwwJAwoIBA8ACwEGDQwHCQMOBQIKBwsFDwACDgEIAw0MBgkEDQcPCAUPBgQLCg4MCQACAw0MAgcEAQsODggGDwkFAAM=",
  sha512k: "428a2f98d728ae227137449123ef65cdb5c0fbcfec4d3b2fe9b5dba58189dbbc3956c25bf348b53859f111f1b605d019923f82a4af194f9bab1c5ed5da6d8118d807aa98a303024212835b0145706fbe243185be4ee4b28c550c7dc3d5ffb4e272be5d74f27b896f80deb1fe3b1696b19bdc06a725c71235c19bf174cf692694e49b69c19ef14ad2efbe4786384f25e30fc19dc68b8cd5b5240ca1cc77ac9c652de92c6f592b02754a7484aa6ea6e4835cb0a9dcbd41fbd476f988da831153b5983e5152ee66dfaba831c66d2db43210b00327c898fb213fbf597fc7beef0ee4c6e00bf33da88fc2d5a79147930aa72506ca6351e003826f142929670a0e6e7027b70a8546d22ffc2e1b21385c26c9264d2c6dfc5ac42aed53380d139d95b3df650a73548baf63de766a0abb3c77b2a881c2c92e47edaee692722c851482353ba2bfe8a14cf10364a81a664bbc423001c24b8b70d0f89791c76c51a30654be30d192e819d6ef5218d69906245565a910f40e35855771202a106aa07032bbd1b819a4c116b8d2d0c81e376c085141ab532748774cdf8eeb9934b0bcb5e19b48a8391c0cb3c5c95a634ed8aa4ae3418acb5b9cca4f7763e373682e6ff3d6b2b8a3748f82ee5defb2fc78a5636f43172f6084c87814a1f0ab728cc702081a6439ec90befffa23631e28a4506cebde82bde9bef9a3f7b2c67915c67178f2e372532bca273eceea26619cd186b8c721c0c207eada7dd6cde0eb1ef57d4f7fee6ed17806f067aa72176fba0a637dc5a2c898a6113f9804bef90dae1b710b35131c471b28db77f523047d8432caab7b40c724933c9ebe0a15c9bebc431d67c49c100d4c4cc5d4becb3e42b6597f299cfc657e2a5fcb6fab3ad6faec6c44198c4a475817",
  sha512h: "6a09e667f3bcc908bb67ae8584caa73b3c6ef372fe94f82ba54ff53a5f1d36f1510e527fade682d19b05688c2b3e6c1f1f83d9abfb41bd6b5be0cd19137e2179"
};

// ============================================================
// HG_CRYPTO · 红果六神签名 JS 移植 (第一部分: SM3 / Gorgon / Helios)
// 源: upload-13.py — SM3 L2584, _xg_rc4 L3618, _encrypt_gorgon L3639,
//     _encrypt_helios L3656, _json_body_md5 L3591, _url_encode L3604。
// 依赖 AGG_CRYPTO (engines/crypto.js) 的 md5Hex/hexToBytes/utf8Encode 等。
// 64 位运算用 [hi, lo] 双字实现, 不依赖 BigInt (Rex JSCore 可用性未证)。
// 随机源由调用方注入 rand32() (0..0xFFFFFFFF) 与 rand16(); 金向量测试时
// 注入恒定 0x1234 复现 py 冻结 random.randint 的口径。
// ============================================================
const HG_CRYPTO = (function () {
  const AC = AGG_CRYPTO;

  function u8(arr) { return new Uint8Array(arr); }
  function concatBytes() {
    let n = 0;
    for (const a of arguments) n += a.length;
    const out = new Uint8Array(n);
    let off = 0;
    for (const a of arguments) { out.set(a, off); off += a.length; }
    return out;
  }
  function bytesToHexLocal(bytes) { return AC.bytesToHex(bytes); }

  // ---------------- SM3 (py 纯回退口径 = 国标) ----------------
  function rol32(v, n) { n &= 31; return ((v << n) | (v >>> (32 - n))) >>> 0; }
  function sm3Bytes(data) {
    const len = data.length;
    const bitLen = len * 8;
    let total = len + 1;
    while (total % 64 !== 56) total++;
    total += 8;
    const msg = new Uint8Array(total);
    msg.set(data, 0);
    msg[len] = 0x80;
    const hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
    msg[total - 8] = (hi >>> 24) & 255; msg[total - 7] = (hi >>> 16) & 255;
    msg[total - 6] = (hi >>> 8) & 255; msg[total - 5] = hi & 255;
    msg[total - 4] = (lo >>> 24) & 255; msg[total - 3] = (lo >>> 16) & 255;
    msg[total - 2] = (lo >>> 8) & 255; msg[total - 1] = lo & 255;
    let iv = [0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600, 0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E];
    const w = new Array(68), w1 = new Array(64);
    for (let off = 0; off < total; off += 64) {
      for (let i = 0; i < 16; i++) {
        w[i] = ((msg[off + i * 4] << 24) | (msg[off + i * 4 + 1] << 16) | (msg[off + i * 4 + 2] << 8) | msg[off + i * 4 + 3]) >>> 0;
      }
      for (let j = 16; j < 68; j++) {
        const x = (w[j - 16] ^ w[j - 9] ^ rol32(w[j - 3], 15)) >>> 0;
        w[j] = ((x ^ rol32(x, 15) ^ rol32(x, 23) ^ rol32(w[j - 13], 7) ^ w[j - 6]) >>> 0);
      }
      for (let j = 0; j < 64; j++) w1[j] = (w[j] ^ w[j + 4]) >>> 0;
      let a = iv[0], b = iv[1], c = iv[2], d = iv[3], e = iv[4], f = iv[5], g = iv[6], h = iv[7];
      for (let j = 0; j < 64; j++) {
        const tj = j < 16 ? 0x79CC4519 : 0x7A879D8A;
        const ss1 = rol32(((rol32(a, 12) + e + rol32(tj, j % 32)) >>> 0), 7);
        const ss2 = (ss1 ^ rol32(a, 12)) >>> 0;
        const ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c));
        const gg = j < 16 ? (e ^ f ^ g) : ((e & f) | ((~e) & g));
        const tt1 = ((ff >>> 0) + d + ss2 + w1[j]) >>> 0;
        const tt2 = ((gg >>> 0) + h + ss1 + w[j]) >>> 0;
        d = c; c = rol32(b, 9); b = a; a = tt1;
        h = g; g = rol32(f, 19); f = e; e = (tt2 ^ rol32(tt2, 9) ^ rol32(tt2, 17)) >>> 0;
      }
      iv = [(iv[0] ^ a) >>> 0, (iv[1] ^ b) >>> 0, (iv[2] ^ c) >>> 0, (iv[3] ^ d) >>> 0,
            (iv[4] ^ e) >>> 0, (iv[5] ^ f) >>> 0, (iv[6] ^ g) >>> 0, (iv[7] ^ h) >>> 0];
    }
    const out = new Uint8Array(32);
    for (let i = 0; i < 8; i++) {
      out[i * 4] = (iv[i] >>> 24) & 255; out[i * 4 + 1] = (iv[i] >>> 16) & 255;
      out[i * 4 + 2] = (iv[i] >>> 8) & 255; out[i * 4 + 3] = iv[i] & 255;
    }
    return out;
  }
  function sm3Hex(data) { return bytesToHexLocal(sm3Bytes(data)); }

  // ---------------- 64 位 [hi, lo] 工具 ----------------
  function ror64(v, count) {
    const hi = v[0], lo = v[1];
    if (count === 8) return [((hi >>> 8) | (lo << 24)) >>> 0, ((lo >>> 8) | (hi << 24)) >>> 0];
    if (count === 61) return [((hi << 3) | (lo >>> 29)) >>> 0, ((lo << 3) | (hi >>> 29)) >>> 0]; // = rol 3
    throw new Error("ror64 只支持 8/61");
  }
  function add64(a, b) {
    const loSum = a[1] + b[1];
    const carry = loSum >= 4294967296 ? 1 : 0;
    return [(a[0] + b[0] + carry) >>> 0, loSum >>> 0];
  }
  function xor64(a, b) { return [(a[0] ^ b[0]) >>> 0, (a[1] ^ b[1]) >>> 0]; }
  function u64FromLE(bytes, off) {
    const lo = (bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)) >>> 0;
    const hi = (bytes[off + 4] | (bytes[off + 5] << 8) | (bytes[off + 6] << 16) | (bytes[off + 7] << 24)) >>> 0;
    return [hi, lo];
  }
  function u64ToLE(v) {
    return u8([v[1] & 255, (v[1] >>> 8) & 255, (v[1] >>> 16) & 255, (v[1] >>> 24) & 255,
               v[0] & 255, (v[0] >>> 8) & 255, (v[0] >>> 16) & 255, (v[0] >>> 24) & 255]);
  }

  // ---------------- _json_body_md5 / _url_encode ----------------
  function jsonBodyMd5(data, dataType) {
    if (!data) return "";
    let raw;
    if (typeof data === "string") raw = AC.utf8Encode(data);
    else if (data instanceof Uint8Array) raw = data;
    else if (dataType === "application/json; charset=UTF-8") raw = AC.utf8Encode(JSON.stringify(data));
    else raw = AC.utf8Encode(urlEncode(data));
    return AC.bytesToHex(AC.md5Bytes(raw)).toUpperCase();
  }
  function urlEncode(obj) {
    const parts = [];
    for (const k of Object.keys(obj)) {
      parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(obj[k])));
    }
    return parts.join("&").replace(/\+/g, "%20").replace(/%2A/g, "*");
  }

  // ---------------- _xg_rc4 (变体, 逐行对 py) ----------------
  function xgRc4(data, key) {
    const table = new Array(256);
    for (let i = 0; i < 256; i++) table[i] = i;
    let j = 0;
    for (let i = 0; i < 256; i++) {
      j = (j + table[i] + key[i % key.length]) % 256;
      table[i] = table[j];
    }
    let i = 0; j = 0;
    const result = new Uint8Array(data.length);
    for (let index = 0; index < data.length; index++) {
      i = (i + 1) & 0xFF;
      const x = table[i];
      j = (j + x) & 0xFF;
      const y = table[j];
      table[i] = y;
      result[index] = data[index] ^ table[(y + y) & 0xFF];
    }
    return result;
  }
  function reverseBits(v) {
    let r = 0;
    for (let k = 0; k < 8; k++) { r = (r << 1) | ((v >>> k) & 1); }
    return r;
  }

  // ---------------- _encrypt_gorgon ----------------
  function encryptGorgon(body, query, khronos, xgRand, dataType) {
    const bodyMd5 = body ? jsonBodyMd5(body, dataType).toLowerCase() : "";
    const qDigest = AC.hexToBytes(AC.md5Hex(query));
    let data = concatBytes(
      qDigest.slice(0, 4),
      bodyMd5 ? AC.hexToBytes(bodyMd5).slice(0, 4) : u8([0, 0, 0, 0]),
      u8([0, 0, 0, 0]),
      u8([67503104 & 255, (67503104 >>> 8) & 255, (67503104 >>> 16) & 255, (67503104 >>> 24) & 255]),
      u8([(khronos >>> 24) & 255, (khronos >>> 16) & 255, (khronos >>> 8) & 255, khronos & 255])
    );
    const key = u8([0x4A, 320 & 0xFF, 0x16, (xgRand >>> 8) & 0xFF, 0x47, 0x6C, 1, xgRand & 0xFF]);
    const result = xgRc4(data, key);
    for (let index = 0; index < result.length; index++) {
      const v = ((result[index] >>> 4) | (result[index] << 4)) & 0xFF;
      const following = index + 1 < result.length ? result[index + 1] : result[0];
      result[index] = (~(reverseBits(following ^ v) ^ 20)) & 0xFF;
    }
    const head = u8([0x84, 0x04, xgRand & 255, (xgRand >>> 8) & 255, 320 & 255, (320 >>> 8) & 255]);
    return bytesToHexLocal(concatBytes(head, result));
  }

  // ---------------- _encrypt_helios ----------------
  function encryptHelios(khronos, randValue) {
    const seed = concatBytes(
      u8([randValue & 255, (randValue >>> 8) & 255, (randValue >>> 16) & 255, (randValue >>> 24) & 255]),
      AC.utf8Encode("8662")
    );
    // py: keys = md5(seed) 十六进制字符串的 ASCII 字节 (32B); seed 含任意字节, 须按字节哈希
    const hexStr = AC.bytesToHex(AC.md5Bytes(seed));
    const keys = AC.utf8Encode(hexStr);
    const table = [u64FromLE(keys, 0)];
    let words = [u64FromLE(keys, 0), u64FromLE(keys, 8), u64FromLE(keys, 16), u64FromLE(keys, 24)];
    let first = words[0], second = words[1];
    words = words.slice(2);
    for (let index = 0; index < 0x22; index++) {
      let v2 = ror64(second, 8);
      v2 = add64(v2, first);
      v2 = xor64(v2, [0, index]);
      words.push(v2);
      v2 = xor64(v2, ror64(first, 61));
      table.push(v2);
      first = v2;
      second = words.shift();
    }
    let raw = AC.utf8Encode(khronos + "-1588093228-8662");
    const pad = 16 - (raw.length % 16);
    const padded = new Uint8Array(raw.length + pad);
    padded.set(raw, 0);
    for (let i = raw.length; i < padded.length; i++) padded[i] = pad;
    const output = [];
    for (let off = 0; off < padded.length; off += 16) {
      let left = u64FromLE(padded, off);
      let right = u64FromLE(padded, off + 8);
      for (let index = 0; index < 0x22; index++) {
        right = xor64(table[index], add64(left, ror64(right, 8)));
        left = xor64(right, ror64(left, 61));
      }
      output.push(u64ToLE(left), u64ToLE(right));
    }
    const randLE = u8([randValue & 255, (randValue >>> 8) & 255, (randValue >>> 16) & 255, (randValue >>> 24) & 255]);
    return AC.b64FromBytes(concatBytes(randLE, ...output));
  }

  // ================================================================
  // 第二部分: Medusa 链 (hash_f13 三分支 / md5sum_v3 / AES_V3 / proto)
  // ================================================================
  const SBOX = AC.b64ToBytes(HG_TABLES.sbox);
  const BRANCH1_TABLE = AC.b64ToBytes(HG_TABLES.branch1);
  const BRANCH2_ORDERS = AC.b64ToBytes(HG_TABLES.branch2orders);

  function ror32v(v, n) { n %= 32; return ((v >>> n) | (v << (32 - n))) >>> 0; }
  function rl8(x, k) { const s = k & 7; return ((x << s) | (x >>> (8 - s))) & 0xFF; }

  function sumMd5(data) {
    let check = 0x20220420;
    for (let i = 0; i < 12; i++) {
      let temp;
      if (i % 2 === 0) {
        temp = ((check >>> 3) ^ check) >>> 0;
        check = (data[i] ^ (check << 7)) >>> 0;
      } else {
        temp = ((check >>> 5) ^ check) >>> 0;
        check = (data[i] | (check << 11)) >>> 0;
        check = (check ^ 0xFFFFFFFF) >>> 0;
      }
      check = (check ^ temp) >>> 0;
      check = check & 0xFFFFFFFF;
    }
    check = (check | 4) >>> 0;
    check = (check ^ 0x1000000) >>> 0;
    return check;
  }
  function sumMd5LE(data) {
    const v = sumMd5(data);
    return u8([v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255]);
  }

  function getIv(iv, data) {
    for (let i = 0; i < data.length; i++) {
      if ((i & 1) === 0) iv = ((iv >>> 4) ^ iv ^ (iv << 6) ^ data[i]) >>> 0;
      else iv = (~((iv >>> 7) ^ iv ^ (data[i] | (iv << 12)))) >>> 0;
      iv = iv & 0xFFFFFFFF;
    }
    return iv;
  }

  function hashF13(querySm3, bodyMd5Bytes, tsBytes, khronos) {
    let iv = getIv(0x20230928, querySm3);
    iv = getIv(iv, bodyMd5Bytes);
    iv = getIv(iv, tsBytes);
    const ivV0 = ((iv & 15) * 171) >> 9;
    const branch = (iv & 15) - ((ivV0 * 3) & 0xFF);
    if (branch === 0) return branch0(ivV0, khronos, querySm3, bodyMd5Bytes, tsBytes);
    if (branch === 1) return branch1(ivV0, khronos, querySm3, bodyMd5Bytes, tsBytes);
    if (branch === 2) return branch2(iv, khronos, querySm3, bodyMd5Bytes, tsBytes);
    throw new Error("hashF13 no branch: " + branch);
  }

  // ---- branch_0 ----
  function branch0Xor(data, base, di, tt03, round, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) {
    const d = data.slice();
    for (let i = 0; i < round; i++) {
      let offset = base + i;
      const n0 = di[offset & 127];
      const n1 = (((d[x3] ^ d[x4]) & d[x1]) ^ d[x3]) >>> 0;
      const n2 = (rol32(d[x1], 26) ^ rol32(d[x1], 21) ^ rol32(d[x1], 7)) >>> 0;
      offset = offset & 63;
      const n3 = tt03[offset];
      const n4 = (n0 + n1 + n2 + n3 + d[x5]) >>> 0;
      const n5 = (rol32(d[x2], 30) ^ rol32(d[x2], 19) ^ rol32(d[x2], 10)) >>> 0;
      const n6 = ((d[x2] & d[x6]) | ((d[x2] | d[x6]) & d[x7])) >>> 0;
      const n7 = (n5 + n6) >>> 0;
      const o = d[x9];
      const nd = [d[7], d[0], d[1], d[2], d[3], d[4], d[5], d[6]];
      for (let k = 0; k < 8; k++) d[k] = nd[k];
      d[x10] = (n7 + n4) >>> 0;
      d[x8] = (o + n4) >>> 0;
    }
    return d;
  }
  function branch0(ivV0, khronos, querySm3, bodyMd5Bytes, tsBytes) {
    const tt01 = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1];
    const ivV1 = tt01[ivV0];
    const countV1 = (ivV1 + khronos + 1) & 0xFF;
    let countV2 = (ivV1 + khronos) >>> 0;
    const tt02 = [0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8, 0xf233eb6f,
      0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288, 0x2c077f0a, 0xda0dcad0,
      0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e, 0xcce8b06b, 0x6ad0ed0b, 0xa0522717,
      0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c, 0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032,
      0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3, 0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b,
      0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8, 0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2,
      0xab0b3b86, 0x3d5dfb14, 0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa,
      0x5fb37586];
    const tt03 = tt02.map(v => ror32v(v, countV1));
    const n0 = (countV2 + 2) & 7;
    const pad = new Uint8Array(4);
    const seed = [0xfa, 0x45, 0x61, 0xd7];
    for (let i = 0; i < 4; i++) {
      let v = (seed[i] | (seed[i] << 8)) >>> 0;
      v = v >>> n0;
      pad[i] = v & 0xFF;
    }
    countV2 = countV2 & 0xFF;
    const initValue = [
      ror32v(0x7aba4fc8, countV2), ror32v(0x67166507, countV2),
      ror32v(0x6403fa00, countV2), ror32v(0x340f512f, countV2),
      ror32v(984304912, countV2), ror32v(3005047866, countV2),
      ror32v(2874125293, countV2), ror32v(2152413264, countV2)
    ];
    const data = concatBytes(querySm3, bodyMd5Bytes, tsBytes, pad, u8([0, 0, 0, 0, 0, 0, 0x01, 0xa0]));
    const di = [];
    for (let i = 0; i < data.length / 4; i++) {
      di.push(((data[i * 4] << 24) | (data[i * 4 + 1] << 16) | (data[i * 4 + 2] << 8) | data[i * 4 + 3]) >>> 0);
    }
    let di0 = di[0];
    for (let i = 0; i < 112; i++) {
      const di1 = di[i + 1], di14 = di[i + 14];
      const rDi1 = (rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >>> 3)) >>> 0;
      const rDi2 = (rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >>> 10)) >>> 0;
      di0 = (di0 + di[i + 9] + rDi1 + rDi2) >>> 0;
      di.push(di0);
      di0 = di1;
    }
    let vj;
    if (ivV0 === 5) vj = branch0Xor(initValue, ivV1, di, tt03, 100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5);
    else if (ivV0 === 4) vj = branch0Xor(initValue, ivV1, di, tt03, 96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4);
    else if (ivV0 === 3) vj = branch0Xor(initValue, ivV1, di, tt03, 99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6);
    else if (ivV0 === 2) vj = branch0Xor(initValue, ivV1, di, tt03, 96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5);
    else if (ivV0 === 1) vj = branch0Xor(initValue, ivV1, di, tt03, 96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4);
    else vj = branch0Xor(initValue, ivV1, di, tt03, 101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3);
    const ret = new Uint8Array(32);
    for (let i = 0; i < 8; i++) {
      const v = (vj[i] + initValue[i]) >>> 0;
      ret[i * 4] = (v >>> 24) & 255; ret[i * 4 + 1] = (v >>> 16) & 255;
      ret[i * 4 + 2] = (v >>> 8) & 255; ret[i * 4 + 3] = v & 255;
    }
    const first16 = new Uint8Array(16);
    for (let i = 0; i < 16; i++) first16[i] = ret[i] ^ ret[i + 16];
    return concatBytes(first16, sumMd5LE(first16));
  }

  // ---- md5sum_v3 (branch_2 用) ----
  const SV2 = [0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73,
    0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64,
    0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e,
    0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28,
    0x66c4ff96, 0x51716443, 0x0dd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec,
    0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754,
    0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da,
    0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x03d7b75d, 0xb1fe4af7, 0xa5ab26a3];
  function lcs(k, bits) { bits %= 32; k = k >>> 0; return ((k << bits) | (k >>> (32 - bits))) >>> 0; }
  function md5sumV3(msg, countV2, orders, countV1) {
    const count = countV2 & 0xFF;
    const sv = SV2.map(v => ror32v(v, countV1));
    const start = [ror32v(0x79e0f2fb, count), ror32v(0xc8b52570, count), ror32v(0xebc2f8cd, count), ror32v(0x7c104d93, count)];
    const count2 = (countV2 + 6) & 0xFF;
    const end = [ror32v(0x19be4866, count2), ror32v(0xe85986b4, count2), ror32v(0xe19b326e, count2), ror32v(0x71d1d7d4, count2)];
    let A = start[0], B = start[1], C = start[2], D = start[3];
    let a = A, b = B, c = C, d = D;
    const M = [];
    for (let i = 0; i < 16; i++) {
      M.push((msg[i * 4] | (msg[i * 4 + 1] << 8) | (msg[i * 4 + 2] << 16) | (msg[i * 4 + 3] << 24)) >>> 0);
    }
    const o1 = orders.slice(0, 16), o2 = orders.slice(16, 32), o3 = orders.slice(32, 48), o4 = orders.slice(48, 64);
    const F = (x, y, z) => ((x & y) | ((~x) & z)) >>> 0;
    const G = (x, y, z) => ((x & z) | (y & (~z))) >>> 0;
    const H = (x, y, z) => (x ^ y ^ z) >>> 0;
    const I = (x, y, z) => (y ^ (x | (~z))) >>> 0;
    const FF = (a2, b2, c2, d2, m, s, t) => (b2 + lcs((a2 + F(b2, c2, d2) + m + t) >>> 0, s)) >>> 0;
    const GG = (a2, b2, c2, d2, m, s, t) => (b2 + lcs((a2 + G(b2, c2, d2) + m + t) >>> 0, s)) >>> 0;
    const HH = (a2, b2, c2, d2, m, s, t) => (b2 + lcs((a2 + H(b2, c2, d2) + m + t) >>> 0, s)) >>> 0;
    const II = (a2, b2, c2, d2, m, s, t) => (b2 + lcs((a2 + I(b2, c2, d2) + m + t) >>> 0, s)) >>> 0;
    const S1 = [7, 12, 17, 22], S2 = [5, 9, 14, 20], S3 = [4, 11, 16, 23], S4 = [6, 10, 15, 21];
    for (let i = 0; i < 16; i += 4) {
      a = FF(a, b, c, d, M[o1[i]], S1[0], sv[i]); d = FF(d, a, b, c, M[o1[i + 1]], S1[1], sv[i + 1]);
      c = FF(c, d, a, b, M[o1[i + 2]], S1[2], sv[i + 2]); b = FF(b, c, d, a, M[o1[i + 3]], S1[3], sv[i + 3]);
    }
    for (let i = 0; i < 16; i += 4) {
      a = GG(a, b, c, d, M[o2[i]], S2[0], sv[16 + i]); d = GG(d, a, b, c, M[o2[i + 1]], S2[1], sv[17 + i]);
      c = GG(c, d, a, b, M[o2[i + 2]], S2[2], sv[18 + i]); b = GG(b, c, d, a, M[o2[i + 3]], S2[3], sv[19 + i]);
    }
    for (let i = 0; i < 16; i += 4) {
      a = HH(a, b, c, d, M[o3[i]], S3[0], sv[32 + i]); d = HH(d, a, b, c, M[o3[i + 1]], S3[1], sv[33 + i]);
      c = HH(c, d, a, b, M[o3[i + 2]], S3[2], sv[34 + i]); b = HH(b, c, d, a, M[o3[i + 3]], S3[3], sv[35 + i]);
    }
    for (let i = 0; i < 16; i += 4) {
      a = II(a, b, c, d, M[o4[i]], S4[0], sv[48 + i]); d = II(d, a, b, c, M[o4[i + 1]], S4[1], sv[49 + i]);
      c = II(c, d, a, b, M[o4[i + 2]], S4[2], sv[50 + i]); b = II(b, c, d, a, M[o4[i + 3]], S4[3], sv[51 + i]);
    }
    A = ((A + a) >>> 0) ^ end[0]; B = ((B + b) >>> 0) ^ end[1];
    C = ((C + c) >>> 0) ^ end[2]; D = ((D + d) >>> 0) ^ end[3];
    const out = new Uint8Array(16);
    const words = [A, B, C, D];
    for (let i = 0; i < 4; i++) {
      out[i * 4] = words[i] & 255; out[i * 4 + 1] = (words[i] >>> 8) & 255;
      out[i * 4 + 2] = (words[i] >>> 16) & 255; out[i * 4 + 3] = (words[i] >>> 24) & 255;
    }
    return concatBytes(out, sumMd5LE(out));
  }

  // ---- branch_2 ----
  function branch2(iv, khronos, querySm3, bodyMd5Bytes, tsBytes) {
    const n0 = (iv & 13) * 86; // py 原式 iv & 15 - 2: Python 中 - 优先级高于 &, 即 iv & (15-2)
    const ivV0 = ((n0 >> 15) & 0xFF) + ((n0 >> 8) & 0xFF);
    const t001 = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4];
    const n1 = t001[ivV0];
    const countV1 = (n1 + khronos + 1) & 0xFF;
    const countV2 = (n1 + khronos) >>> 0;
    const n0b = (countV2 + 5) & 7;
    const pad = new Uint8Array(8);
    const seed = [0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];
    for (let i = 0; i < 8; i++) {
      let v = (seed[i] | (seed[i] << 8)) >>> 0;
      v = v >>> n0b;
      pad[i] = v & 0xFF;
    }
    const data = concatBytes(querySm3, bodyMd5Bytes, tsBytes, pad, u8([0xa0, 0x01, 0x00, 0x00]));
    const idx = ivV0 << 6;
    return md5sumV3(data, countV2, BRANCH2_ORDERS.slice(idx, idx + 64), countV1);
  }

  // ---- branch_1 (64 位, BigInt 精确移植) ----
  const MASK64 = (1n << 64n) - 1n;
  function ror64B(v, n) {
    n = ((n % 64n) + 64n) % 64n;
    if (n === 0n) return v & MASK64;
    return ((v >> n) | (v << (64n - n))) & MASK64;
  }
  function branch1TableF(ivV0) {
    const base = ivV0 << 14;
    return function (x) {
      const off = base + Number(x);
      let v = 0n;
      for (let i = 7; i >= 0; i--) v = (v << 8n) | BigInt(BRANCH1_TABLE[off + i]);
      return v;
    };
  }
  function r00(r0, r1, r2, r3, r4, r5, r6, r7, tt, tableF) {
    let x = tableF(8n * (r0 >> 56n));
    r1 = (r1 >> 45n) & 2040n;
    if (tt > 0n) x = x ^ tt;
    x = x ^ tableF(r1 + 2048n);
    r2 = (r2 >> 37n) & 2040n;
    x = x ^ tableF(r2 + 4096n);
    r3 = (r3 >> 29n) & 2040n;
    x = x ^ tableF(r3 + 6144n);
    r4 = (r4 >> 21n) & 2040n;
    x = x ^ tableF(r4 + 8192n);
    r5 = (r5 >> 13n) & 2040n;
    x = x ^ tableF(r5 + 10240n);
    r6 = (r6 >> 8n) & 255n;
    x = x ^ tableF(8n * r6 + 12288n);
    r7 = r7 & 255n;
    x = x ^ tableF(8n * r7 + 14336n);
    return x;
  }
  function swapV0(src, srcXor, tt2, tableF, order1, typ) {
    const da0 = new Array(8);
    let ha0 = srcXor.slice();
    for (let i = 0; i < 8; i++) da0[i] = src[order1[i]] ^ srcXor[i];
    for (let round = 0; round < 10; round++) {
      const rr = [];
      for (let k = 0; k < 8; k++) {
        rr.push(r00(ha0[k % 8], ha0[(k + 1) % 8], ha0[(k + 2) % 8], ha0[(k + 3) % 8], ha0[(k + 4) % 8], ha0[(k + 5) % 8], ha0[(k + 6) % 8], ha0[(k + 7) % 8], 0n, tableF));
      }
      rr[7] = rr[7] ^ tt2[round + 1];
      const d = da0.slice();
      for (let k = 0; k < 8; k++) {
        da0[k] = r00(d[k % 8], d[(k + 1) % 8], d[(k + 2) % 8], d[(k + 3) % 8], d[(k + 4) % 8], d[(k + 5) % 8], d[(k + 6) % 8], d[(k + 7) % 8], rr[k], tableF);
      }
      ha0 = rr;
    }
    if (typ === undefined || typ === null) {
      src[0] = da0[0] ^ srcXor[0] ^ src[0];
      src[1] = da0[7] ^ srcXor[1] ^ src[1];
      src[2] = da0[6] ^ srcXor[2] ^ src[2];
      src[3] = da0[5] ^ srcXor[3] ^ src[3];
      src[4] = da0[4] ^ srcXor[4] ^ src[4];
      src[5] = da0[3] ^ srcXor[5] ^ src[5];
      src[6] = da0[2] ^ srcXor[6] ^ src[6];
      src[7] = da0[1] ^ srcXor[7] ^ src[7];
    } else {
      src[0] = da0[7] ^ typ[1];
      src[1] = da0[6] ^ typ[2];
      src[2] = da0[5] ^ typ[3];
      src[3] = da0[4] ^ typ[4];
      src[4] = da0[3] ^ typ[5];
      src[5] = da0[2] ^ typ[6];
      src[6] = da0[1] ^ typ[7] ^ src[7];
      src[7] = da0[0] ^ typ[0];
    }
    return src;
  }
  function branch1(ivV0, khronos, querySm3, bodyMd5Bytes, tsBytes) {
    const tt1 = [0x808a9c79, 0xf079807e, 0xbadf79c5, 0xa785d3ff, 0x82d8438c];
    const ivV1 = tt1[ivV0];
    let cV1 = (ivV1 + khronos) & 0xFF;
    const cV1Big = ror64B(BigInt(khronos >>> 0), BigInt(cV1));
    const orders = [0x05, 0x07, 0x01, 0x02, 0x04, 0x00, 0x06, 0x03, 0x00, 0x05, 0x02, 0x04, 0x01, 0x03, 0x07, 0x06,
      0x05, 0x07, 0x02, 0x04, 0x01, 0x06, 0x03, 0x00, 0x03, 0x00, 0x02, 0x04, 0x06, 0x07, 0x01, 0x05,
      0x04, 0x05, 0x00, 0x03, 0x06, 0x02, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    const order1 = orders.slice(ivV0 * 8, ivV0 * 8 + 8);
    const ivV1b = (ivV1 + khronos + 1) & 63;
    const tt1b = [0x87aeea5dab37cd6bn, 0x7ff48becb4f54087n, 0xb0724c06706bbd5dn, 0x1fe5dfb1143e328dn,
      0x1a2331d00af4f1f2n, 0xcaff7131bb1e71ban, 0x33385e1042752218n, 0xff01ed65d4a441fbn,
      0x0adb1ec8828c80e8n, 0x62475d12f4e06fe7n, 0xbd0b238da4fe72n];
    const tt2 = tt1b.map(v => ror64B(v, BigInt(ivV1b)));
    const toSign = concatBytes(querySm3, bodyMd5Bytes, tsBytes, u8([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    let src = [];
    for (let i = 0; i < toSign.length / 8; i++) {
      let v = 0n;
      for (let k = 0; k < 8; k++) v = (v << 8n) | BigInt(toSign[i * 8 + k]);
      src.push(v);
    }
    const tableF = branch1TableF(ivV0);
    let srcXor = [cV1Big, cV1Big, cV1Big, cV1Big, cV1Big, cV1Big, cV1Big, cV1Big];
    const swap = swapV0(src, srcXor, tt2, tableF, order1, null);
    const data = [0n, 0n, 0n, 0n, 0n, 0n, 0n, 416n];
    srcXor = [swap[4], swap[3], swap[2], swap[1], swap[0], swap[7], swap[6], swap[5]];
    const swap2 = swapV0(data, srcXor, tt2, tableF, order1, swap);
    const ret = new Uint8Array(32);
    let n = 0;
    for (let i = 7; i >= 0; i--) {
      const le = [];
      let v = swap2[i];
      for (let k = 0; k < 8; k++) { le.push(Number(v & 255n)); v = v >> 8n; }
      ret[n] = le[1]; ret[n + 1] = le[3]; ret[n + 2] = le[5]; ret[n + 3] = le[6];
      n += 4;
    }
    const first16 = new Uint8Array(16);
    for (let i = 0; i < 16; i++) first16[i] = ret[i] ^ ret[i + 16];
    return concatBytes(first16, sumMd5LE(first16));
  }

  // ---- get_key_hash / xmxor ----
  function getKeyHash(key, rand) {
    const le = u8([rand & 255, (rand >>> 8) & 255, (rand >>> 16) & 255, (rand >>> 24) & 255]);
    const digest = sm3Bytes(concatBytes(key, le, key));
    const d1 = (rand >>> 16) & 0xFF;
    let d2 = (((d1 << 11) | (rand >>> 24)) >>> 0);
    d2 = (d2 ^ ((d1 >>> 5) ^ d1)) >>> 0;
    d2 = (~d2) >>> 0;
    return [digest, u8([d2 & 255, (d2 >>> 8) & 255, (d2 >>> 16) & 255, (d2 >>> 24) & 255])];
  }
  function xmxorTwo(data, key) {
    const encoded = new Uint8Array(data.length);
    for (let index = 0; index < data.length; index++) {
      const value = data[index];
      const position = (index * 4) & 28;
      const d0 = key[position], d1 = key[position + 1];
      let d2 = (rl8(value, 4) + d0) ^ d1;
      d2 = rl8((~d2) & 0xFF, 3);
      d2 = ((d2 + d1) & 0xFF) ^ d0;
      encoded[data.length - index - 1] = (~d2) & 0xFF;
    }
    return encoded;
  }
  function xmxor(data, key) {
    const value = xmxorTwo(data, key);
    const len = value.length;
    const lastFlag = value[len - 1] ^ value[len - 2];
    const data0 = value[0];
    value[0] = ((-lastFlag - 1 + value[0]) & 0xFF);
    value[1] = (((value[0] ^ value[len - 1] ^ 254) + value[1]) & 0xFF);
    value[2] = ((value[2] + ((lastFlag - data0) ^ rl8(value[1], 3) ^ 2)) & 0xFF);
    for (let index = 0; index < len - 4; index++) {
      const temp = rl8(value[index + 2], 3) ^ value[index + 1] ^ (index + 3);
      value[index + 3] = ((-temp - 1 + value[index + 3]) & 0xFF);
    }
    value[len - 1] = (value[len - 1] ^ value[len - 2]) & 0xFF;
    let sum = 0;
    for (let i = 1; i < len; i++) sum += value[i];
    value[0] = (((value[0] ^ value[1]) + sum) & 0xFF);
    return value;
  }

  // ---- AES_V3 (只移植 encrypt, 签名链不用 decrypt) ----
  const V3_RCON = [[1, 0, 2, 3], [1, 3, 0, 2], [0, 1, 3, 2], [1, 0, 2, 3]];
  const V3_RCON2 = [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]];
  const V3_RORDERS = [[0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3]];
  function xtime(a) { return (a & 0x80) ? (((a << 1) ^ 0x1B) & 0xFF) : (a << 1); }
  function aesV3Encrypt(data, aesKey, iv, khronos) {
    const wordSize = khronos & 3;
    const sboxAt = b => SBOX[wordSize * 256 + b];
    const initValues = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f];
    const initValue = initValues[wordSize];
    const mk = new Uint8Array(48);
    const le32 = [initValue & 255, (initValue >>> 8) & 255, (initValue >>> 16) & 255, (initValue >>> 24) & 255];
    for (let i = 0; i < 16; i++) mk[i] = le32[i % 4] ^ aesKey[i];
    let rounds = 8;
    for (let i = 4; i < 12; i++) {
      const idx = 4 * (i - 1);
      let k0 = mk[idx], k1 = mk[idx + 1], k2 = mk[idx + 2], k3 = mk[idx + 3];
      if ((i & 3) === 0) {
        const k00 = ((initValue >>> (rounds & 24)) ^ sboxAt(k1)) & 0xFF;
        const nk1 = sboxAt(k2), nk2 = sboxAt(k3), nk3 = sboxAt(k0);
        k0 = k00; k1 = nk1; k2 = nk2; k3 = nk3;
      }
      rounds += 2;
      mk[idx + 4] = k0 ^ mk[idx - 12];
      mk[idx + 5] = k1 ^ mk[idx - 11];
      mk[idx + 6] = k2 ^ mk[idx - 10];
      mk[idx + 7] = k3 ^ mk[idx - 9];
    }
    const keyRows = [];
    for (let r = 0; r < 12; r++) keyRows.push([mk[r * 4], mk[r * 4 + 1], mk[r * 4 + 2], mk[r * 4 + 3]]);
    const con = V3_RCON[wordSize], con2 = V3_RCON2[wordSize], order = V3_RORDERS[wordSize];
    function bytes2matrix(text) {
      const m = [];
      for (let i = 0; i < text.length; i += 4) m.push([text[i], text[i + 1], text[i + 2], text[i + 3]]);
      return m;
    }
    function matrix2bytes(m) {
      const out = [];
      for (const row of m) for (const v of row) out.push(v);
      return out;
    }
    function addRoundKeyCon(s, k, c) {
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) s[i][j] ^= k[i][c[j]];
    }
    function addRoundKey(s, k) {
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) s[i][j] ^= k[i][j];
    }
    function mixSingleColumn(a, i) {
      const t = a[0][i] ^ a[1][i] ^ a[2][i] ^ a[3][i];
      const u = a[0][i];
      a[0][i] ^= t ^ xtime(a[0][i] ^ a[1][i]);
      a[1][i] ^= t ^ xtime(a[1][i] ^ a[2][i]);
      a[2][i] ^= t ^ xtime(a[2][i] ^ a[3][i]);
      a[3][i] ^= t ^ xtime(a[3][i] ^ u);
    }
    function subBytes(s) {
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) s[i][j] = sboxAt(s[i][j]);
      const old = [s[0], s[1], s[2], s[3]];
      s[0] = old[con2[0]]; s[1] = old[con2[1]]; s[2] = old[con2[2]]; s[3] = old[con2[3]];
    }
    function shiftRows(s) {
      const bs = matrix2bytes(s);
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) s[i][j] = bs[order[i * 4 + j]];
    }
    function shiftRowsCon(s, c) {
      for (let i = 0; i < 4; i++) {
        const old = s[i].slice();
        s[i][0] = old[c[0]]; s[i][1] = old[c[1]]; s[i][2] = old[c[2]]; s[i][3] = old[c[3]];
      }
    }
    function encryptBlock(plain) {
      const s = bytes2matrix(plain);
      addRoundKeyCon(s, keyRows.slice(0, 4), con2);
      for (let i = 1; i < 3; i++) {
        subBytes(s);
        shiftRows(s);
        if (i === 1) {
          shiftRowsCon(s, con2);
          for (let c = 0; c < 4; c++) mixSingleColumn(s, c);
        }
        addRoundKeyCon(s, keyRows.slice(i * 4, i * 4 + 4), con2);
      }
      addRoundKey(s, keyRows.slice(4, 8));
      return matrix2bytes(s);
    }
    function sumData(d) {
      const key = new Uint8Array(32);
      const b = j => (j < d.length ? d[j] : 0);
      for (let i = 0; i < 31; i++) {
        const idx = i * 8;
        const n0 = (b(idx) >>> 4) & 2;
        const n1 = n0 | (b(idx + 1) & 64);
        const n2 = n1 | ((b(idx + 2) >>> 2) & 1);
        const n3 = n2 | ((b(idx + 3) << 3) & 0x80);
        const n4 = n3 | ((b(idx + 4) >>> 1) & 4);
        const n5 = n4 | ((b(idx + 5) << 3) & 16);
        const n6 = n5 | ((b(idx + 6) << 5) & 32);
        const n7 = n6 | ((b(idx + 7) >>> 4) & 8);
        key[i] = n7 & 0xFF;
      }
      key[31] = 1;
      return key;
    }
    function mixColumnsStatic(d, key) {
      const out = new Uint8Array(d);
      for (let i = 0; i < 31; i++) {
        const kk = key[i], idx = i * 8;
        if (idx + 7 >= out.length) break;
        out[idx] = (out[idx] & 0xDF) | ((kk << 4) & 32);
        out[idx + 1] = (out[idx + 1] & 0xBF) | (kk & 64);
        out[idx + 2] = (out[idx + 2] & 0xFB) | ((kk * 4) & 4);
        out[idx + 3] = (out[idx + 3] & 0xEF) | ((kk >>> 3) & 16);
        out[idx + 4] = (out[idx + 4] & 0xF7) | ((kk + kk) & 8);
        out[idx + 5] = (out[idx + 5] & 0xFD) | ((kk >>> 3) & 2);
        out[idx + 6] = (out[idx + 6] & 0xFE) | ((kk >>> 5) & 1);
        out[idx + 7] = (out[idx + 7] & 0x7F) | ((kk << 4) & 0x80);
      }
      return out;
    }
    const plaintext = sumData(data);
    const blocks = [];
    let previous = Array.from(iv);
    for (let off = 0; off < plaintext.length; off += 16) {
      const x = [];
      for (let i = 0; i < 16; i++) x.push(plaintext[off + i] ^ previous[i]);
      const block = encryptBlock(x);
      blocks.push(block);
      previous = block;
    }
    const key = blocks.flat();
    const mixedData = mixColumnsStatic(data, key);
    return concatBytes(u8([key[key.length - 1]]), mixedData);
  }

  // ---- protobuf 编码 (py _varint/_sint/_proto_field/_proto) ----
  function varintB(value) {
    let v = BigInt(value);
    if (v < 0n) v = v & ((1n << 64n) - 1n);
    const out = [];
    while (v > 0x7Fn) { out.push(Number((v & 0x7Fn) | 0x80n)); v = v >> 7n; }
    out.push(Number(v));
    return u8(out);
  }
  function sintB(value) {
    const v = BigInt(value);
    return v >= 0n ? (v << 1n) : ((v << 1n) ^ -1n);
  }
  function protoField(field, value, kind) {
    if (value === null || value === undefined || value === "" || value === 0 || value === false) return new Uint8Array(0);
    if (value instanceof Uint8Array && value.length === 0) return new Uint8Array(0);
    if (kind === "sint32" || kind === "sint64") {
      return concatBytes(varintB(BigInt(field << 3)), varintB(sintB(typeof value === "bigint" ? value : BigInt(Math.trunc(Number(value))))));
    }
    if (kind === "float") {
      const buf = new Uint8Array(4);
      new DataView(buf.buffer).setFloat32(0, Number(value), true);
      return concatBytes(varintB(BigInt((field << 3) | 5)), buf);
    }
    let raw;
    if (kind === "bytes" || kind === "message") raw = value instanceof Uint8Array ? value : u8(value);
    else if (kind === "string") raw = AC.utf8Encode(String(value));
    else throw new Error("unknown proto kind: " + kind);
    return concatBytes(varintB(BigInt((field << 3) | 2)), varintB(BigInt(raw.length)), raw);
  }
  function proto(fields) {
    return concatBytes(...fields.map(f => protoField(f[0], f[1], f[2])));
  }
  function encodeRequest() {
    return proto([[1, 111, "sint32"], [2, 10, "sint32"], [3, 694367, "sint32"], [5, 586952199, "sint32"]]);
  }
  function encodeDevice(d) {
    return proto([
      [1, d.d1, "sint32"], [2, d.collect_stat, "sint32"], [3, d.aid, "string"], [4, d.device_id, "string"],
      [5, d.sec_device_token, "string"], [6, d.app_version, "string"], [7, d.battery, "sint32"], [8, d.battery2, "sint32"],
      [9, d.battery_health, "sint32"], [10, d.battery_changed, "sint32"], [11, d.network, "string"], [12, d.tz, "string"],
      [13, d.lan, "string"], [14, d.cpu, "sint32"], [15, d.resolution, "string"], [16, d.sdcard, "float"],
      [17, d.sdcard_used, "float"], [18, d.memory, "float"], [19, d.memory2, "float"], [20, d.data, "float"],
      [21, d.data_used, "float"], [22, d.os_version, "string"], [23, d.brightness, "sint32"], [24, d.volume, "sint32"],
      [25, d.ts, "sint64"], [26, d.ts2, "sint64"], [27, d.ts3, "sint64"], [28, d.ts4, "sint64"],
      [29, d.usb, "sint32"], [30, d.hw_version, "string"], [31, d.brand, "string"], [32, d.board, "string"],
      [33, d.product_name, "string"], [34, d.product_device, "string"], [35, d.product_manufacturer, "string"],
      [36, d.hardware, "string"], [38, d.unknown38, "sint32"], [40, d.unknown40, "sint32"]
    ]);
  }
  function encodeEnv(env) {
    const r = env.report || {};
    return proto([
      [1, env.launch_time, "sint32"], [2, env.unknown2, "sint32"], [3, env.unknown3, "sint32"], [5, env.unknown5, "sint32"],
      [6, env.version, "string"], [7, env.pid, "sint32"], [12, encodeDevice(env.device || {}), "message"],
      [13, proto([[1, r.time, "sint64"], [2, r.state, "sint32"], [4, r.code, "sint32"], [5, r.times, "sint32"], [6, r.unknown6, "sint32"]]), "message"],
      [14, env.app_version, "string"], [15, env.unknown15, "sint32"], [16, env.unknown16, "sint32"],
      [18, env.unknown18, "sint32"], [19, env.unknown19, "sint32"], [20, env.unknown20, "sint32"], [21, env.unknown21, "sint32"]
    ]);
  }
  function encodeMedusa(v) {
    return proto([
      [1, v.magic, "bytes"], [2, v.version, "sint32"], [3, v.rand, "sint32"], [4, v.ms_app_id, "string"],
      [5, v.device_id, "string"], [6, v.license_id, "string"], [7, v.app_version, "string"], [8, v.sdk_version_str, "string"],
      [9, v.sdk_version, "sint32"], [10, v.xg_seed_bytes, "bytes"], [12, v.time, "sint32"], [13, v.query_body_ts_hash, "bytes"],
      [14, v.query_sm3, "bytes"], [15, encodeRequest(), "message"], [16, v.sec_device_token, "string"], [17, v.time2, "sint32"],
      [18, v.lanusk_hash, "bytes"], [19, v.query_body_hash_sm3, "bytes"], [20, v.psk_version, "string"], [21, v.call_type, "sint32"],
      [23, encodeEnv(v.env || {}), "message"], [24, v.unknown24, "string"], [26, v.original, "string"]
    ]);
  }

  // ---- _gen_medusa_proto / _gen_medusa ----
  function genMedusaProto(url, urlParams, devices, data, khronos, dataType, rng, nowSec) {
    const bodyMd5 = data ? jsonBodyMd5(data, dataType).toLowerCase() : "";
    const bodyMd5Bytes = bodyMd5 ? AC.hexToBytes(bodyMd5) : new Uint8Array(16);
    const tsBytes = u8([khronos & 255, (khronos >>> 8) & 255, (khronos >>> 16) & 255, (khronos >>> 24) & 255]);
    const qi = url.indexOf("?");
    const query = qi >= 0 ? url.slice(qi + 1) : "";
    const querySm3 = sm3Bytes(AC.utf8Encode(query));
    const queryBodyHash = sm3Bytes(concatBytes(AC.utf8Encode(query), bodyMd5Bytes, AC.utf8Encode("none")));
    const deviceId = String(devices.device_id || urlParams.device_id || urlParams.did || "");
    const versionName = String(devices.version_name || urlParams.version_name || "7.1.3.32");
    const deviceModel = String(devices.device_model || urlParams.device_type || "");
    const brand = String(devices.device_brand || urlParams.device_brand || "");
    const secDeviceToken = String(devices.sec_device_token || "");
    const deviceSecToken = String(devices.device_sec_device_token || "");
    const protoRand = rng.u32();
    const launchTime = rng.range(100, 120);
    const processId = rng.range(10001, 12000);
    const reportTs = 1728388016635;
    const device = {
      d1: 1, collect_stat: 2, aid: "8662", device_id: deviceId,
      sec_device_token: deviceSecToken, app_version: "!noperm!", battery: -888888, battery2: -888888,
      battery_health: 3, battery_changed: -888888, network: "!notset!",
      tz: "Asia/Shanghai,8", lan: "zh_CN", cpu: 4,
      sdcard: 255.24993896484375, sdcard_used: 35.58599090576172,
      memory: 3.467449188232422, memory2: 3.467449188232422,
      data: 255.1754913330078, data_used: 42.17544174194336,
      os_version: String(devices.os_version || urlParams.os_version || ""),
      brightness: 41, volume: 36, ts: reportTs, ts2: reportTs,
      ts3: reportTs, ts4: reportTs + 2, usb: -1, hw_version: deviceModel,
      brand: brand, board: deviceModel, product_name: deviceModel,
      product_device: String(devices.device_manufacturer || brand),
      product_manufacturer: brand, hardware: brand, unknown38: 31
    };
    const env = {
      launch_time: launchTime, unknown2: 146331399, unknown3: 146331396, unknown5: 7,
      version: "v04.06.04.03-bugfix", pid: processId, device: device,
      report: { time: nowSec, state: -2, code: 200, times: 0, unknown6: 0 },
      app_version: versionName
    };
    const qbHash = hashF13(querySm3, bodyMd5Bytes, tsBytes, khronos);
    const values = {
      magic: u8([0xf7, 0xe8, 0x5f, 0xfa, 0xd7, 0xd7, 0xdc, 0x3b, 0xd6, 0x2a, 0xc8, 0x70, 0x57, 0xcf, 0x61, 0x18]),
      version: 3, rand: protoRand, ms_app_id: "8662",
      device_id: deviceId, license_id: "1588093228", app_version: versionName,
      sdk_version_str: "v04.06.04-ml-android", sdk_version: 67503104,
      xg_seed_bytes: u8([320 & 255, (320 >>> 8) & 255, 0, 0, 0, 0, 0, 0]), time: khronos,
      query_body_ts_hash: qbHash,
      query_sm3: querySm3.slice(0, 6), sec_device_token: secDeviceToken, time2: khronos,
      lanusk_hash: new Uint8Array(0), query_body_hash_sm3: queryBodyHash, psk_version: "none",
      call_type: 312, env: env,
      unknown24: '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}'
    };
    return { protoBytes: encodeMedusa(values), querySm3: querySm3, bodyHash: qbHash };
  }

  const MEDUSA_CONFIG_KEY = AC.hexToBytes("f1593376766ea98d34f31b057a9d5be4");
  const MEDUSA_CONFIG_IV = AC.hexToBytes("1fe109a4125283f418de9e051a969e12");
  const MEDUSA_SIGN_KEY = AC.hexToBytes("8ebd" + "fa38" + "06ec" + "c5ce" + "e794" + "23e6" + "029e" + "d825" + "40bc" + "2218" + "bb7e" + "aef7" + "1cb6" + "91f7" + "aa8a" + "a2f5");
  function genMedusa(url, urlParams, devices, data, khronos, dataType, rng, nowSec) {
    const p = genMedusaProto(url, urlParams, devices, data, khronos, dataType, rng, nowSec);
    const hashRand = rng.u32();
    const xmRand = rng.u32();
    const kh = getKeyHash(MEDUSA_SIGN_KEY, hashRand);
    const key = kh[0], seed = kh[1];
    let mixed = xmxor(p.protoBytes, key);
    mixed = concatBytes(u8([320 & 255, (320 >>> 8) & 255, 0, 0, 0, 0, 0, 0]), mixed);
    mixed = new Uint8Array(Array.from(mixed).reverse());
    for (let i = 0; i < mixed.length; i++) mixed[i] = mixed[i] ^ seed[3 - (i & 3)];
    const hashBytes = u8([hashRand & 255, (hashRand >>> 8) & 255, (hashRand >>> 16) & 255, (hashRand >>> 24) & 255]);
    const checkBit = (((p.querySm3[0] & 63) << 14) | 0x18000001 | ((p.bodyHash[0] & 63) << 8)) >>> 0;
    mixed = concatBytes(u8([0x35]),
      u8([xmRand & 255, (xmRand >>> 8) & 255, (xmRand >>> 16) & 255, (xmRand >>> 24) & 255]),
      u8([checkBit & 255, (checkBit >>> 8) & 255, (checkBit >>> 16) & 255, (checkBit >>> 24) & 255]),
      mixed, hashBytes.slice(2));
    const enc = aesV3Encrypt(mixed, MEDUSA_CONFIG_KEY, MEDUSA_CONFIG_IV, khronos);
    const version = AC.hexToBytes("03000000f7e85ffad7d7dc3bd62ac87057cf6118");
    const versionOr = new Uint8Array(20);
    for (let i = 0; i < 20; i += 4) {
      const w = ((version[i] | (version[i + 1] << 8) | (version[i + 2] << 16) | (version[i + 3] << 24)) >>> 0) ^ (khronos >>> 0);
      versionOr[i] = w & 255; versionOr[i + 1] = (w >>> 8) & 255; versionOr[i + 2] = (w >>> 16) & 255; versionOr[i + 3] = (w >>> 24) & 255;
    }
    return AC.b64FromBytes(concatBytes(versionOr, hashBytes.slice(0, 2), u8([256 & 255, (256 >>> 8) & 255]), enc));
  }

  // ---- _get_params_encrypturl / _core_sixgod ----
  function getParamsEncryptUrl(url, params, devices, nowSec, rticketMs) {
    const result = {};
    for (const k of Object.keys(params)) result[k] = params[k];
    for (const k of Object.keys(devices)) {
      if (k in result) result[k] = devices[k];
      else if (k === "device_id" && ("did" in result)) result["did"] = devices[k];
    }
    result["ts"] = nowSec;
    result["_rticket"] = (typeof rticketMs === "number" && isFinite(rticketMs)) ? rticketMs : nowSec * 1000;
    const base = url.split("?")[0];
    return [base + "?" + urlEncode(result), result];
  }
  // branch-0 _rticket 搜索 (HGTV-Orange 实测口径: 服务端只接受 medusa branch==0 的请求;
  // branch 由 hashF13 的 iv 决定, iv 链 = querySm3 → bodyMd5 → tsBytes, 全部本地可算,
  // 递增 _rticket 毫秒直到 (iv&15)%3===0; 与 hashF13 的 branch 公式同源)。
  function findBranch0Rticket(url, params, devices, data, dataType, nowSec) {
    const bodyMd5 = data ? jsonBodyMd5(data, dataType).toLowerCase() : "";
    const bodyMd5Bytes = bodyMd5 ? AC.hexToBytes(bodyMd5) : new Uint8Array(16);
    const tsBytes = u8([nowSec & 255, (nowSec >>> 8) & 255, (nowSec >>> 16) & 255, (nowSec >>> 24) & 255]);
    for (let d = 0; d < 128; d++) {
      const rt = nowSec * 1000 + d;
      const ep = getParamsEncryptUrl(url, params, devices, nowSec, rt);
      const q = ep[0].slice(ep[0].indexOf("?") + 1);
      let iv = getIv(0x20230928, sm3Bytes(AC.utf8Encode(q)));
      iv = getIv(iv, bodyMd5Bytes);
      iv = getIv(iv, tsBytes);
      if ((iv & 15) % 3 === 0) return rt;
    }
    return nowSec * 1000;
  }
  function coreSixgod(url, params, devices, data, header, rng, nowSec, rticketMs) {
    const dataType = String((header && (header["content-type"] || header["Content-Type"])) || "");
    const xgRand = rng.u16();
    const ep = getParamsEncryptUrl(url, params, devices, nowSec, rticketMs);
    const encryptedUrl = ep[0], urlParams = ep[1];
    const khronos = nowSec;
    const encodedQuery = urlEncode(urlParams);
    const signs = {
      "x-ladon": AC.b64FromBytes(u8([(khronos >>> 24) & 255, (khronos >>> 16) & 255, (khronos >>> 8) & 255, khronos & 255])),
      "x-khronos": String(khronos),
      "x-argus": AC.b64FromBytes(u8([khronos & 255, (khronos >>> 8) & 255, (khronos >>> 16) & 255, (khronos >>> 24) & 255])),
      "x-gorgon": encryptGorgon(data, encodedQuery, khronos, xgRand, dataType),
      "x-helios": encryptHelios(khronos, rng.u32()),
      "x-medusa": genMedusa(encryptedUrl, urlParams, devices, data, khronos, dataType, rng, nowSec)
    };
    if (data) signs["x-ss-stub"] = jsonBodyMd5(data, dataType);
    const resultHeaders = {};
    if (header) for (const k of Object.keys(header)) resultHeaders[String(k).toLowerCase()] = String(header[k]);
    for (const k of Object.keys(signs)) resultHeaders[k] = signs[k];
    if (devices.ua) resultHeaders["user-agent"] = String(devices.ua);
    resultHeaders["x-tt-dt"] = String(devices.x_tt_dt || "");
    return { headers: resultHeaders, url: encryptedUrl };
  }

  // ---- SHA-512 (spade URL 解密链用; BigInt 实现, 常量表程序生成) ----
  const SHA512_K = [], SHA512_H0 = [];
  for (let i = 0; i < 80; i++) SHA512_K.push(BigInt("0x" + HG_TABLES.sha512k.slice(i * 16, i * 16 + 16)));
  for (let i = 0; i < 8; i++) SHA512_H0.push(BigInt("0x" + HG_TABLES.sha512h.slice(i * 16, i * 16 + 16)));
  function rotrB(x, n) { return ((x >> n) | (x << (64n - n))) & MASK64; }
  function sha512Bytes(data) {
    const H = SHA512_H0.slice();
    const len = data.length;
    let total = len + 1;
    while (total % 128 !== 112) total++;
    total += 16;
    const msg = new Uint8Array(total);
    msg.set(data, 0);
    msg[len] = 0x80;
    const bitLen = BigInt(len) * 8n;
    for (let i = 0; i < 8; i++) msg[total - 1 - i] = Number((bitLen >> BigInt(i * 8)) & 255n);
    const w = new Array(80);
    for (let off = 0; off < total; off += 128) {
      for (let t = 0; t < 16; t++) {
        let v = 0n;
        for (let k = 0; k < 8; k++) v = (v << 8n) | BigInt(msg[off + t * 8 + k]);
        w[t] = v;
      }
      for (let t = 16; t < 80; t++) {
        const s0 = rotrB(w[t - 15], 1n) ^ rotrB(w[t - 15], 8n) ^ (w[t - 15] >> 7n);
        const s1 = rotrB(w[t - 2], 19n) ^ rotrB(w[t - 2], 61n) ^ (w[t - 2] >> 6n); // σ1: 19/61/6 (勿与 SHA-256 的 17/19/10 混)
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & MASK64;
      }
      let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (let t = 0; t < 80; t++) {
        const S1 = rotrB(e, 14n) ^ rotrB(e, 18n) ^ rotrB(e, 41n);
        const ch = (e & f) ^ ((~e & MASK64) & g);
        const t1 = (h + S1 + ch + SHA512_K[t] + w[t]) & MASK64;
        const S0 = rotrB(a, 28n) ^ rotrB(a, 34n) ^ rotrB(a, 39n);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = (S0 + maj) & MASK64;
        h = g; g = f; f = e; e = (d + t1) & MASK64;
        d = c; c = b; b = a; a = (t1 + t2) & MASK64;
      }
      H[0] = (H[0] + a) & MASK64; H[1] = (H[1] + b) & MASK64; H[2] = (H[2] + c) & MASK64; H[3] = (H[3] + d) & MASK64;
      H[4] = (H[4] + e) & MASK64; H[5] = (H[5] + f) & MASK64; H[6] = (H[6] + g) & MASK64; H[7] = (H[7] + h) & MASK64;
    }
    const out = new Uint8Array(64);
    for (let i = 0; i < 8; i++) {
      let v = H[i];
      for (let k = 7; k >= 0; k--) { out[i * 8 + k] = Number(v & 255n); v = v >> 8n; }
    }
    return out;
  }

  // ---- spade: 派生内容密钥 + URL 解密 (py L1124 / L4038) ----
  function deriveContentKey(spadeB64) {
    const raw = AC.b64ToBytes(String(spadeB64 || ""));
    if (raw.length < 3) return null;
    let v8 = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47;
    if (v8 <= 0 || 1 + v8 > raw.length) v8 = raw.length - 1;
    if (v8 < 33) return null;
    const value = new Uint8Array(raw.slice(1, 1 + v8));
    let va = 85, vb = 246;
    for (let index = 0; index < v8; index++) {
      const previous = (index & 1) ? va : vb;
      const orig = value[index];
      if (index & 1) va = orig; else vb = orig;
      let pc = 0, nn = index;
      while (nn) { pc += nn & 1; nn >>= 1; }
      value[index] = (-21 - pc + (previous ^ orig)) & 0xFF;
    }
    const hexStr = AC.utf8Decode(value.slice(1, 33));
    if (!/^[0-9a-fA-F]{32}$/.test(hexStr)) return null;
    return AC.hexToBytes(hexStr);
  }
  const SPADE_CONSTANTS = AC.hexToBytes(
    "4dd4c2e6b83162090e52b3c7a6733ba4" + "1cb2462b829ab58a196b39db57177524" +
    "f49baf7f08e8d68d26a72e37c1a95a2f" + "1f05a51892aef2949732b62a38aadd58");
  function decryptSpadeUrl(value, keySeed) {
    const raw = AC.b64ToBytes(String(value || ""));
    if (raw.length < 20 || raw[0] !== 0xA8 || raw[2] !== 0x01 || raw[3] !== 0x00) return null;
    const cipher = raw.slice(4, raw.length - ((raw.length - 4) % 16));
    if (!cipher.length) return null;
    const first = sha512Bytes(keySeed);
    const second = sha512Bytes(concatBytes(first, SPADE_CONSTANTS));
    let plain;
    try { plain = AC.aesCbcDecrypt(second.slice(0, 16), second.slice(16, 32), cipher); } catch (e) { return null; }
    if (!plain || !plain.length) return null;
    let end = plain.length;
    while (end > 0 && plain[end - 1] === 0) end--;
    const text = AC.utf8Decode(plain.slice(0, end));
    return text || null;
  }

  // ---- video_model 结构工具 (py L3930-4068) ----
  function firstText() {
    for (const v of arguments) {
      if (v !== null && v !== undefined && String(v) !== "") return String(v);
    }
    return "";
  }
  function videoListFromModel(model) {
    if (!model || typeof model !== "object") return null;
    for (const key of ["video_list", "dynamic_video_list"]) {
      if (model[key] !== null && model[key] !== undefined) return model[key];
    }
    const dynamic = model.dynamic_video;
    if (dynamic && typeof dynamic === "object") {
      for (const key of ["dynamic_video_list", "video_list", "list"]) {
        if (dynamic[key] !== null && dynamic[key] !== undefined) return dynamic[key];
      }
    }
    const videoInfo = model.video_info;
    if (videoInfo && typeof videoInfo === "object") {
      const data = videoInfo.data;
      if (data && typeof data === "object") return videoListFromModel(data);
    }
    const data = model.data;
    if (data && typeof data === "object") return videoListFromModel(data);
    return null;
  }
  function qualityOf(value) {
    const text = String(value === null || value === undefined ? "" : value).toLowerCase();
    const m = /(2160|1440|1080|720|576|540|480|360)/.exec(text);
    return m ? m[1] : "1080";
  }
  function selectQualityRows(videoList) {
    function rowsFrom(value, hinted) {
      if (Array.isArray(value)) {
        let out = [];
        for (const item of value) out = out.concat(rowsFrom(item, hinted));
        return out;
      }
      if (!value || typeof value !== "object") return [];
      if (["main_url", "backup_url", "backup_url_1", "play_addr", "spade_a", "encrypt_info"].some(k => k in value)) {
        return [[hinted, value]];
      }
      let out = [];
      for (const key of Object.keys(value)) {
        const item = value[key];
        if (["dynamic_video", "video_info", "data"].includes(key) && item && typeof item === "object") {
          out = out.concat(rowsFrom(item, hinted));
          continue;
        }
        if (["video_list", "dynamic_video_list", "list"].includes(key)) {
          out = out.concat(rowsFrom(item, qualityOf(key)));
          continue;
        }
        if (item && typeof item === "object") out = out.concat(rowsFrom(item, qualityOf(key)));
      }
      return out;
    }
    const rows = {};
    for (const pair of rowsFrom(videoList, "")) {
      const item = pair[1];
      const definition = qualityOf(item.definition || item.vheight || (item.video_meta || {}).definition || pair[0]);
      rows[definition] = item;
    }
    return rows;
  }
  function mediaUrl(item) {
    return firstText(item.main_url, item.backup_url, item.backup_url_1, item.play_addr, item.url);
  }
  function spadeValue(item) {
    const enc = (item.encrypt_info && typeof item.encrypt_info === "object") ? item.encrypt_info : {};
    return firstText(item.spade_a, enc.spade_a);
  }
  function keySeedFromModel(model) {
    if (!model || typeof model !== "object") return new Uint8Array(0);
    const value = model.key_seed ? String(model.key_seed) : "";
    if (value) return AC.b64ToBytes(value);
    for (const key of ["dynamic_video", "video_info", "data"]) {
      const nested = model[key];
      if (nested && typeof nested === "object") {
        const result = keySeedFromModel(nested);
        if (result.length) return result;
      }
    }
    return new Uint8Array(0);
  }

  // ---- PlayerSign (v2.11.0): JSTV 播放路四头签名, 逐行移植
  // luoyan333/JSTV-myself 的 PlayerSign (用户 2026-11-11 拍板
  // 按 JSTV 实现)。X-Gorgon 变体 + X-Argus (protobuf 风消息 ->
  // 72 轮 Feistel 变体 -> AES-128-CBC) + X-Ladon (Feistel 变
  // 体)。nonce 由调用方注入 (金标准对拍需固定 nonce 验签)。
  const _PS_MASK = (1n << 64n) - 1n;
  function _psRot(x, n) { n = ((n % 64) + 64) % 64; const bn = BigInt(n); return ((x << bn) | (x >> BigInt(64 - n))) & _PS_MASK; }
  function _psVi(n) { let v = BigInt(n); const a = []; while (v > 127n) { a.push(Number(v & 127n) | 128); v >>= 7n; } a.push(Number(v)); return a; }
  function _psField(n, v) { return _psVi(BigInt(n) * 8n).concat(_psVi(BigInt(v))); }
  function _psBytes(n, v) { const b = Array.from(v); return _psVi(BigInt(n) * 8n + 2n).concat(_psVi(BigInt(b.length)), b); }
  function _psU64le(buf, off) { let x = 0n; for (let i = 7; i >= 0; i--) x = (x << 8n) | BigInt(buf[off + i] & 255); return x; }
  function _psW64le(out, off, x) { let v = BigInt(x); for (let i = 0; i < 8; i++) { out[off + i] = Number(v & 255n); v >>= 8n; } }
  function _psPad16(arr) { const n = 16 - (arr.length % 16); const out = arr.slice(); for (let i = 0; i < n; i++) out.push(n); return out; }
  function _psRev8(x) { let n = 0; for (let j = 0; j < 8; j++) n = (n << 1) | ((x >> j) & 1); return n; }
  function _psArgus(query, bodyBytes, ts, device, nonce) {
    const AC = AGG_CRYPTO;
    const key = Array.from(AC.hexToBytes("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c"));
    const bh = sm3Bytes((bodyBytes && bodyBytes.length) ? AC.md5Bytes(bodyBytes) : new Uint8Array(16));
    const qh = sm3Bytes(AC.utf8Encode(query));
    const counters = [].concat(_psField(1, 1), _psField(2, 1), _psField(3, 1), _psField(7, 3348294860));
    const env = [].concat(_psBytes(1, AC.utf8Encode("25053RT47C")), _psBytes(2, AC.utf8Encode("16")), _psBytes(3, AC.utf8Encode("update_64")), _psField(4, 2147483648));
    const nonceField = ((nonce[6] & 255) | ((nonce[7] & 255) << 8) | ((nonce[8] & 255) << 16) | ((nonce[9] & 255) << 24)) & 0x7fffffff;
    let msg = [];
    msg = msg.concat(_psField(1, 0x20200929 * 2));
    msg = msg.concat(_psField(2, 2));
    msg = msg.concat(_psField(3, nonceField));
    msg = msg.concat(_psBytes(4, AC.utf8Encode("8662")));
    msg = msg.concat(_psBytes(5, AC.utf8Encode(String(device || ""))));
    msg = msg.concat(_psBytes(6, AC.utf8Encode("1611921764")));
    msg = msg.concat(_psBytes(7, AC.utf8Encode("7.3.5.32")));
    msg = msg.concat(_psBytes(8, AC.utf8Encode("v04.07.01-ml-android")));
    msg = msg.concat(_psField(9, 135135744));
    msg = msg.concat(_psBytes(10, [0, 0, 0, 0, 0, 0, 0, 0]));
    msg = msg.concat(_psField(11, 0));
    msg = msg.concat(_psField(12, BigInt(ts) * 2n));
    msg = msg.concat(_psBytes(13, Array.from(bh.slice(0, 6))));
    msg = msg.concat(_psBytes(14, Array.from(qh.slice(0, 6))));
    msg = msg.concat(_psBytes(15, counters));
    msg = msg.concat(_psBytes(16, []));
    msg = msg.concat(_psBytes(20, AC.utf8Encode("none")));
    msg = msg.concat(_psField(21, 738));
    msg = msg.concat(_psBytes(23, env));
    msg = msg.concat(_psField(25, 2));
    let data = _psPad16(msg);
    const derived = sm3Bytes(concatBytes(key, [0x3c, 0xcc, 0x56, 0x7b], key));
    const rounds = [];
    for (let i = 0; i < 4; i++) rounds.push(_psU64le(derived, i * 8));
    for (let i = 4; i < 72; i++) {
      let mixed = _psRot(rounds[i - 1], -3) ^ rounds[i - 3];
      mixed ^= _psRot(mixed, -1);
      rounds.push(((~rounds[i - 4]) ^ mixed ^ ((0x3dc94c3a046d678bn >> BigInt((i - 4) % 62)) & 1n) ^ 3n) & _PS_MASK);
    }
    for (let off = 0; off < data.length; off += 16) {
      let l = _psU64le(data, off), r = _psU64le(data, off + 8);
      for (let q = 0; q < rounds.length; q++) { const nl = r; const nr = (l ^ (_psRot(r, 1) & _psRot(r, 8)) ^ _psRot(r, 2) ^ rounds[q]) & _PS_MASK; l = nl; r = nr; }
      _psW64le(data, off, l); _psW64le(data, off + 8, r);
    }
    const xorPat = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
    for (let i = 0; i < data.length; i++) data[i] ^= xorPat[i % 8];
    const rev = xorPat.concat(data).reverse();
    const container = _psPad16([0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18].concat(rev, [0x56, 0x7b]));
    const rk = AC._expandKey(Array.from(AC.md5Bytes(key.slice(0, 16))));
    const ivb = Array.from(AC.md5Bytes(key.slice(16, 32)));
    const cipher = [];
    let prev = ivb.slice();
    for (let off = 0; off < container.length; off += 16) {
      const block = []; for (let i = 0; i < 16; i++) block.push((container[off + i] ^ prev[i]) & 255);
      const enc = AC._encryptBlock(rk, block);
      for (let i = 0; i < 16; i++) { cipher.push(enc[i]); prev[i] = enc[i]; }
    }
    return AC.b64FromBytes([0x3c, 0xcc].concat(cipher));
  }
  function _psLadon(aid, ts, prefix) {
    const AC = AGG_CRYPTO;
    const digest = Array.from(AC.utf8Encode(AC.bytesToHex(AC.md5Bytes(concatBytes(Array.from(prefix), AC.utf8Encode(String(aid)))))));
    let l = _psU64le(digest, 0), r = _psU64le(digest, 8);
    const queue = [_psU64le(digest, 16), _psU64le(digest, 24)];
    const keys = [];
    for (let i = 0; i < 34; i++) {
      keys.push(l);
      const mix = ((_psRot(r, -8) + l) & _PS_MASK) ^ BigInt(i);
      queue.push(mix);
      l = (mix ^ _psRot(l, 3)) & _PS_MASK;
      r = queue.shift();
    }
    let data = _psPad16(Array.from(AC.utf8Encode(String(ts) + "-1611921764-" + String(aid))));
    for (let off = 0; off < data.length; off += 16) {
      let bl = _psU64le(data, off), br = _psU64le(data, off + 8);
      for (let q = 0; q < keys.length; q++) { br = (keys[q] ^ ((bl + _psRot(br, -8)) & _PS_MASK)) & _PS_MASK; bl = (br ^ _psRot(bl, 3)) & _PS_MASK; }
      _psW64le(data, off, bl); _psW64le(data, off + 8, br);
    }
    return AC.b64FromBytes(Array.from(prefix).concat(data));
  }
  function playerSignJstv(url, bodyBytes, ts, nonce) {
    const AC = AGG_CRYPTO;
    const s = String(url);
    const qi = s.indexOf("?");
    const query = qi < 0 ? "" : s.slice(qi + 1);
    const p = new Array(20).fill(0);
    const qm = AC.md5Bytes(AC.utf8Encode(query));
    for (let i = 0; i < 4; i++) p[i] = qm[i];
    if (bodyBytes && bodyBytes.length) { const bm = AC.md5Bytes(bodyBytes); for (let i = 0; i < 4; i++) p[4 + i] = bm[i]; }
    p[13] = 6; p[14] = 11; p[15] = 28;
    p[16] = (ts >>> 24) & 255; p[17] = (ts >>> 16) & 255; p[18] = (ts >>> 8) & 255; p[19] = ts & 255;
    const gk = AC.hexToBytes("44b9b9d9a4aef9fca493aa757ca3c2c4a496938f");
    for (let i = 0; i < 20; i++) p[i] ^= gk[i];
    for (let i = 0; i < 20; i++) { const x = (((p[i] << 4) | (p[i] >> 4)) & 255) ^ p[(i + 1) % 20]; p[i] = _psRev8(x) ^ 255 ^ 20; }
    let device = "", aid = "8662";
    for (const pair of query.split("&")) { const eq = pair.indexOf("="); if (eq < 0) continue; const k = pair.slice(0, eq), v = pair.slice(eq + 1); if (k === "device_id") device = decodeURIComponent(v); else if (k === "aid") aid = decodeURIComponent(v); }
    return {
      "X-Khronos": String(ts),
      "X-Gorgon": AC.bytesToHex([0x84, 4, 0x40, 0x1c, 0, 0].concat(p)),
      "X-Argus": _psArgus(query, bodyBytes, ts, device, nonce),
      "X-Ladon": _psLadon(aid, ts, nonce.slice(2, 6))
    };
  }
  function _psGetIv(iv, data) {
    let value = iv;
    for (let i = 0; i < data.length; i++) {
      const d = data[i] & 0xff;
      if ((i & 1) === 0) value = ((value >>> 4) ^ value ^ (value << 6) ^ d) | 0;
      else value = ~((value >>> 7) ^ value ^ (d | (value << 12)));
    }
    return value;
  }
  function playerBranchOf(url, bodyBytes, ts) {
    const AC = AGG_CRYPTO;
    const bodyMd5 = (bodyBytes && bodyBytes.length) ? AC.md5Bytes(bodyBytes) : new Uint8Array(16);
    const s = String(url);
    const qi = s.indexOf("?");
    const q = sm3Bytes(AC.utf8Encode(qi < 0 ? "" : s.slice(qi + 1)));
    const le = [ts & 255, (ts >>> 8) & 255, (ts >>> 16) & 255, (ts >>> 24) & 255];
    const iv = _psGetIv(_psGetIv(_psGetIv(0x20230928, q), bodyMd5), le);
    const low = iv & 15;
    return low - (((low * 171) >> 9) * 3);
  }

  return {
    sm3Bytes, sm3Hex, jsonBodyMd5, urlEncode,
    xgRc4, reverseBits, encryptGorgon, encryptHelios,
    _u64: { ror64, add64, xor64, u64FromLE, u64ToLE },
    _bytes: { concatBytes },
    _f13: { hashF13, branch0, branch2, md5sumV3, sumMd5, getIv },
    _v3: { aesV3Encrypt, getKeyHash, xmxor, branch1 },
    genMedusaProto, genMedusa, getParamsEncryptUrl, coreSixgod, findBranch0Rticket,
    sha512Bytes, deriveContentKey, decryptSpadeUrl,
    videoListFromModel, selectQualityRows, mediaUrl, spadeValue, keySeedFromModel,
    playerSignJstv, playerBranchOf
  };
})();


// ============================================================
// HG_CORE · 自现行 engines/hg.js 逐字抽出 (常量对齐现行 ENG_HG)
// 引擎 ctx 的 storage 在 Worker 侧垫为 isolate 内存 Map (画像/
// 记账本/退避键都只活在本 isolate 内——身份本就是一次性消耗
// 品, 跨 isolate 不需要任何持久化; 唯一落 KV 的是 hg_reg_at)。
// ============================================================
const HG_CORE = {
  _PLAY_HOSTS: ["api5-normal-sinfonlineb.fqnovel.com", "api5-normal-hl.fqnovel.com"],
  _PLAY_PATH: "/novel/player/multi_video_model/v1/",
  _PLAY_SINGLE_PATH: "/novel/player/video_model/v1/",
  _PLAYBACK_UA: "com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/W528JS)",
  _REG_URL_BASE: "https://log5-applog-lf.fqnovel.com/service/2/device_register/",
  _PROFILE_HW: {
    device_type: "25053RT47C", device_brand: "Redmi", channel: "69310258a",
    dragon_device_type: "phone", os_version: "16", os_api: "36",
    rom_version: "W528JS release-keys", rom: "1135", carrier: "CHINA MOBILE",
    mcc_mnc: "46000", resolution: "2772*1280", dpi: "520", is_android_pad_screen: "1"
  },
  _cookieNames: ["store-region", "store-region-src", "install_id", "ttreq"],
  _POOL_MAX: 3,
  _BATCH_W: 15,

  _randBytes(n) {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 256);
    return out;
  },
  _uuid() {
    const b = this._randBytes(16);
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    const h = AGG_CRYPTO.bytesToHex(b);
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  },
  async _postRaw(ctx, url, body, headers) {
    if (typeof ctx.httpPostRaw === "function") {
      const r = await ctx.httpPostRaw(url, body, headers);
      return { status: (r && typeof r.status === "number") ? r.status : 0, text: (r && r.text !== null && r.text !== undefined) ? String(r.text) : "", via: "raw", headers: (r && r.headers) || null };
    }
    if (typeof body === "string" && typeof ctx.httpPostFull === "function") {
      const r = await ctx.httpPostFull(url, body, headers);
      return { status: (r && typeof r.status === "number") ? r.status : 0, text: (r && r.text !== null && r.text !== undefined) ? String(r.text) : "", via: "raw", headers: (r && r.headers) || null };
    }
    throw new Error("ctx.httpPostRaw 未提供 (外壳待补)");
  },
  // v2.5.4: 正文 gzip (CF Workers / 现代 Node 均有
  // CompressionStream; Rex 侧不调 _playBatch, 无此依赖)。
  async _gzipBody(str) {
    const stream = new Blob([str]).stream().pipeThrough(new CompressionStream("gzip"));
    const buf = await new Response(stream).arrayBuffer();
    return new Uint8Array(buf);
  },
  _regId(json, name) {
    const pref = json[name + "_str"];
    const v = (pref === undefined || pref === null || pref === "") ? json[name] : pref;
    if (typeof v === "number") return (isFinite(v) && Math.floor(v) === v && v > 0 && v <= 9007199254740991) ? String(v) : "";
    return (typeof v === "string" && /^\d{1,30}$/.test(v) && /[1-9]/.test(v)) ? v : "";
  },
  _parseCookies(headers) {
    const out = {};
    if (!headers) return out;
    const raws = [];
    const pushVal = (v) => {
      if (Array.isArray(v)) { for (const x of v) pushVal(x); return; }
      if (typeof v === "string" && v) raws.push(v);
    };
    if (Array.isArray(headers)) {
      for (const e of headers) {
        if (typeof e === "string") { const m = /^set-cookie\s*:\s*(.+)$/i.exec(e); if (m) raws.push(m[1]); }
        else if (Array.isArray(e) && /^set-cookie$/i.test(String(e[0] || ""))) pushVal(e[1]);
      }
    } else if (typeof headers === "object") {
      for (const k of Object.keys(headers)) if (/^set-cookie$/i.test(k)) pushVal(headers[k]);
    }
    for (const raw of raws) {
      for (const part of String(raw).split(/,(?=\s*[A-Za-z0-9_-]+=)/)) {
        const seg = part.split(";")[0];
        const eq = seg.indexOf("=");
        if (eq <= 0) continue;
        const name = seg.slice(0, eq).trim();
        if (this._cookieNames.indexOf(name) < 0) continue;
        out[name] = seg.slice(eq + 1).trim();
      }
    }
    return out;
  },
  _ckClean(ck) {
    const out = {};
    if (ck && typeof ck === "object") {
      for (const n of this._cookieNames) if (typeof ck[n] === "string" && ck[n]) out[n] = ck[n];
    }
    return out;
  },
  async _stage(ctx, token, reset) {
    try {
      let s = reset ? "" : String((await ctx.storeGet("hg_stage")) || "");
      s = s ? (s + ">" + token) : String(token);
      if (s.length > 480) s = s.slice(s.length - 480);
      await ctx.storeSet("hg_stage", s);
    } catch (e) {}
  },
  async _regFail(ctx, why) {
    await this._stage(ctx, "reg-fail " + String(why).slice(0, 60));
    // v2.7.2: 不再写 10s 内存注册退避 (采纳分享版 2.6.1 实锤):
    // 单集路逐集独立注册, 一次失败写退避会毒化同 isolate 后
    // 续整窗; 上游保护由 _fetchAndFilter 的 KV 退避承担。
    throw new Error("注册失败: " + why);
  },
  _REG_SALT: "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58",
  // 强注册 (v2.6.0, /device 专用): 真 SDK 形态——log5
  // ?tt_data=a + ttEncrypt(gzip(JSON)) 二进制体 (jackotom
  // playback-device 同形, 字段逐字)。JSON 明文注册的身份被
  // 上游判低信任 (2026-11-10 真机+沙箱实测: 注册照过、
  // multi 恒空), 强注册身份供客户端在住宅出口消费; 本端
  // (机房出口) 只铸造不消费。成功回 {device_id, iid, cdid,
  // klink}, 失败抛错 (调用方记账)。
  async _registerDeviceStrong(ctx) {
    const now = Date.now();
    const cdid = this._uuid();
    const header = {
      display_name: "红果免费短剧", update_version_code: 73932, manifest_version_code: 73932,
      app_version_minor: "7.3.9.32", aid: 8662, channel: "update_64", package: "com.phoenix.read",
      app_version: "7.3.9.32", version_code: 73932, sdk_version: "3.7.0-rc.34-fanqie-xiaoshuo",
      sdk_target_version: 29, git_hash: "3a88f4e", os: "Android", os_version: "16", os_api: 36,
      device_model: "25053RT47C", device_brand: "Redmi", device_manufacturer: "Redmi",
      cpu_abi: "arm64-v8a", release_build: "b5e187f", density_dpi: 520, display_density: "mdpi",
      resolution: "1280x2772", language: "zh", timezone: 8, access: "wifi", not_request_sender: 0,
      carrier: "CHINA MOBILE", mcc_mnc: "46000", rom: "eng.root.20231116.160340",
      rom_version: "W528JS release-keys", cdid: cdid,
      sig_hash: "56a962410c494bbaf0b58dba20cae56f", openudid: AGG_CRYPTO.bytesToHex(this._randBytes(8)),
      clientudid: this._uuid(), ipv6_list: [], region: "CN", tz_name: "Asia/Shanghai",
      tz_offset: 28800, sim_region: "cn", sim_serial_number: [], oaid_may_support: false,
      req_id: this._uuid(), device_platform: "android",
      custom: { account_region_src: "fallback", account_region: "cn", host_bit: 64, dragon_device_type: "phone" }, pre_installed_channel: "",
      apk_first_install_time: now, is_system_app: 0, sdk_flavor: "china", guest_mode: 0
    };
    const jsonStr = JSON.stringify({ magic_tag: "ss_app_log", header: header, _gen_time: now });
    const compressed = await this._gzipBody(jsonStr);
    const random = this._randBytes(32);
    const derived = HG_CRYPTO.sha512Bytes(HG_CRYPTO._bytes.concatBytes(
      HG_CRYPTO.sha512Bytes(random), AGG_CRYPTO.hexToBytes(this._REG_SALT)));
    const plain = HG_CRYPTO._bytes.concatBytes(HG_CRYPTO.sha512Bytes(compressed), compressed);
    const cipher = AGG_CRYPTO.aesCbcEncrypt(derived.slice(0, 16), derived.slice(16, 32), plain);
    const data = HG_CRYPTO._bytes.concatBytes(AGG_CRYPTO.hexToBytes("746305100000"), random, cipher);
    const stub = HG_CRYPTO.jsonBodyMd5(data).toUpperCase();
    const url = this._REG_URL_BASE + "?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1";
    const resp = await this._postRaw(ctx, url, data, {
      "User-Agent": "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
      "Accept": "application/json", "Content-Type": "application/octet-stream;tt-data=a",
      "log-encode-type": "gzip", "x-ss-dp": "8662", "x-ss-req-ticket": String(now),
      "x-vc-bdturing-sdk-version": "4.0.3.cn", "lc": "101", "sdk-version": "2",
      "passport-sdk-version": "5051452", "x-neptune": "-8|50:51:59:30:40:47:49:39",
      "x-ss-stub": stub
    });
    if (!resp || resp.status !== 200 || !resp.text) throw new Error("strong 注册 HTTP " + (resp && resp.status));
    let json = null;
    try { json = JSON.parse(resp.text); } catch (e) {}
    if (!json || typeof json !== "object") throw new Error("strong 注册回包非 JSON");
    const code = (json.code !== undefined && json.code !== null) ? json.code : json.Code;
    if (Number(code || 0) !== 0) throw new Error("strong 注册业务拒绝 code=" + code);
    const device_id = this._regId(json, "device_id");
    const iid = this._regId(json, "install_id");
    if (!device_id || !iid) throw new Error("strong 注册回包缺有效 id");
    return { device_id: device_id, iid: iid, cdid: cdid, klink: (typeof json.klink_egdi === "string") ? json.klink_egdi : "" };
  },
  _genProfile() {
    const pf = Object.assign({}, this._PROFILE_HW);
    pf.profile_format = "official-v1";
    pf.cdid = this._uuid();
    // openudid: 无真机 android_id 可读, 走 HGTV 派生 a() 的
    // fallback 分支 (80-bit 随机 hex), 来源标记记 fallback。
    pf.openudid = AGG_CRYPTO.bytesToHex(this._randBytes(10));
    pf.openudid_source = "fallback";
    pf.clientudid = this._uuid();
    pf.apk_first_install_time = String(Date.now() - 3 * 86400000);
    return pf;
  },
  _profileSanitize(o) {
    if (!o || typeof o !== "object") return null;
    const str = (v) => (typeof v === "string" && v) ? v : "";
    if (!str(o.cdid) || !str(o.openudid) || !str(o.clientudid) || !str(o.device_type) || !str(o.os_version) || !str(o.rom_version)) return null;
    const pf = Object.assign({}, this._PROFILE_HW);
    const keys = ["device_type", "device_brand", "channel", "dragon_device_type", "os_version", "os_api", "rom_version", "rom", "carrier", "mcc_mnc", "resolution", "dpi", "is_android_pad_screen", "cdid", "openudid", "clientudid"];
    for (const k of keys) if (str(o[k])) pf[k] = o[k];
    pf.profile_format = "official-v1";
    pf.openudid_source = str(o.openudid_source) || "fallback";
    const aft = o.apk_first_install_time;
    pf.apk_first_install_time = (typeof aft === "number" && isFinite(aft) && aft > 0) ? String(Math.floor(aft)) : (str(aft) || String(Date.now() - 3 * 86400000));
    return pf;
  },
  async _ensureProfile(ctx) {
    if (this._profileMem) return this._profileMem;
    if (!this._profilePromise) {
      const self = this;
      const p = (async () => {
        let pf = null;
        let raw = "";
        try { raw = await ctx.storeGet("hg_profile_v1"); } catch (e) {}
        if (raw && typeof raw === "string") { try { pf = self._profileSanitize(JSON.parse(raw)); } catch (e) { pf = null; } }
        if (!pf) {
          pf = self._genProfile();
          try { await ctx.storeSet("hg_profile_v1", JSON.stringify(pf)); } catch (e) {}
        }
        self._profileMem = pf;
        return pf;
      })();
      this._profilePromise = p;
      const clear = () => { if (self._profilePromise === p) self._profilePromise = null; };
      p.then(clear, clear);
    }
    return this._profilePromise;
  },
  _pf() {
    return this._profileMem || Object.assign({}, this._PROFILE_HW, { cdid: "", openudid: "", clientudid: "", apk_first_install_time: "0" });
  },
  _manufacturerOf(brand) {
    const map = { redmi: "Xiaomi", xiaomi: "Xiaomi", samsung: "Samsung", huawei: "HUAWEI", honor: "HUAWEI", oppo: "OPPO", vivo: "vivo" };
    const b = String(brand || "");
    return map[b.toLowerCase()] || b;
  },
  _resNorm(resolution, sep) {
    const parts = String(resolution || "").split(/[*x]/).map(x => Number(x)).filter(n => isFinite(n) && n > 0);
    if (parts.length < 2) return String(resolution || "");
    return Math.min.apply(null, parts) + sep + Math.max.apply(null, parts);
  },
  _uaBase(pf) {
    const romFirst = String(pf.rom_version || "BP2A.250605.031.A3").split(" ")[0] || "BP2A.250605.031.A3";
    return "com.phoenix.read/73932 (Linux; U; Android " + (pf.os_version || "16") + "; zh_CN; " + (pf.device_type || "25053RT47C") + "; Build/" + romFirst;
  },
  _regUA(pf) { return this._uaBase(pf) + "; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)"; },
  // v2.5.4: 播放 UA 升 74332 (jackotom PLAYBACK_UA 同法: 基
  // UA 只换版本号); _regUA 继续用 _uaBase 的 73932, 注册不动。
  _playbackUA(pf) { return this._uaBase(pf).replace("com.phoenix.read/73932", "com.phoenix.read/74332") + ")"; },
  _regHeader(pf, trio, old) {
    const aft = Number(pf.apk_first_install_time);
    const header = {
      display_name: "红果免费短剧", update_version_code: 73932, manifest_version_code: 73932,
      app_version_minor: "7.3.9.32", aid: 8662, channel: pf.channel, package: "com.phoenix.read",
      app_version: "7.3.9.32", version_code: 73932, sdk_version: "3.7.0-rc.34-fanqie-xiaoshuo",
      sdk_target_version: 29, os: "Android", os_version: pf.os_version, os_api: Number(pf.os_api) || 0,
      device_model: pf.device_type, device_brand: pf.device_brand, device_manufacturer: this._manufacturerOf(pf.device_brand),
      cpu_abi: "arm64-v8a", density_dpi: Number(pf.dpi) || 0, display_density: "mdpi", resolution: this._resNorm(pf.resolution, "x"),
      language: "zh", timezone: 8, access: "wifi", not_request_sender: 0,
      carrier: pf.carrier, mcc_mnc: pf.mcc_mnc, rom: pf.rom, rom_version: pf.rom_version,
      git_hash: "3a88f4e", sig_hash: "56a962410c494bbaf0b58dba20cae56f", release_build: "b5e187f",
      cdid: trio.cdid, openudid: trio.openudid, clientudid: trio.clientudid
    };
    if (old) {
      if (old.device_id) header.device_id = String(old.device_id);
      if (old.iid) header.install_id = String(old.iid);
      if (old.klink) header.klink_egdi = String(old.klink);
    }
    header.ipv6_list = [];
    header.region = "CN";
    header.tz_name = "Asia/Shanghai";
    header.tz_offset = 28800;
    header.sim_region = "cn";
    header.sim_serial_number = [];
    header.oaid_may_support = false;
    header.req_id = this._uuid();
    header.device_platform = "android";
    header.custom = { account_region_src: "fallback", host_bit: 64, account_region: "cn", dragon_device_type: pf.dragon_device_type || "phone" };
    header.pre_installed_channel = "";
    header.apk_first_install_time = (isFinite(aft) && aft > 0) ? aft : Date.now();
    header.is_system_app = 0;
    header.sdk_flavor = "china";
    header.guest_mode = 0;
    return header;
  },
  async _registerDevice(ctx, opts) {
    opts = opts || {};
    await this._stage(ctx, "reg-start");
    // v2.7.2: 不再读 hg_reg_retry_after (见 _regFail 注)。
    const now = Date.now();
    const pf = opts.pf || (await this._ensureProfile(ctx));
    const trio = opts.trio || { cdid: pf.cdid, openudid: pf.openudid, clientudid: pf.clientudid };
    const header = this._regHeader(pf, trio, opts.old || null);
    const url = this._REG_URL_BASE + "?req_id=" + this._uuid() + "&_rticket=" + now;
    const body = JSON.stringify({ magic_tag: "ss_app_log", header: header, _gen_time: now });
    let resp = null;
    try {
      resp = await this._postRaw(ctx, url, body, {
        "User-Agent": this._regUA(pf),
        "Accept": "application/json",
        "Content-Type": "application/json; charset=utf-8"
      });
    } catch (e) {
      await this._regFail(ctx, "传输失败 " + (e && e.message));
    }
    // _regFail 的各判定点 (HTTP/空回包/非 JSON/业务拒绝/缺 id) 都在此行
    // 之后, 故 resp 一到手先记阶段, 死在哪一判定点由后续 reg-fail 标记区分。
    await this._stage(ctx, "reg-resp via=" + ((resp && resp.via) || "raw") + " status=" + (resp ? resp.status : 0) + " len=" + (resp && resp.text ? String(resp.text).length : 0));
    // 回包形态记账 (成功失败都记): 只记顶层字段名 (排序、逗号拼
    // 接, 绝不含值), 与沙箱基线比对签发形态——真机后段出现过
    // 「注册回包不再带有效 id」, 靠此行区分站方签发形态变化与
    // 本地解析问题。
    {
      let fj = null;
      try { fj = JSON.parse(resp && resp.text ? resp.text : ""); } catch (e) {}
      if (fj && typeof fj === "object") ctx.log("hg 注册回包字段 " + Object.keys(fj).sort().join(","));
      else ctx.log("hg 注册回包字段 <非JSON len=" + (resp && resp.text ? String(resp.text).length : 0) + ">");
    }
    if (!resp || resp.status !== 200) await this._regFail(ctx, "HTTP " + (resp && resp.status));
    if (!resp.text || !resp.text.trim()) await this._regFail(ctx, "空回包");
    let json = null;
    try { json = JSON.parse(resp.text); } catch (e) {}
    if (!json || typeof json !== "object") await this._regFail(ctx, "回包非 JSON");
    const code = (json.code !== undefined && json.code !== null) ? json.code : json.Code;
    if (Number(code || 0) !== 0) await this._regFail(ctx, "业务拒绝 code=" + code);
    const device_id = this._regId(json, "device_id");
    const iid = this._regId(json, "install_id");
    if (!device_id || !iid) await this._regFail(ctx, "回包缺有效 id");
    // Cookie 保持 (v0.2.8): 收下响应 Set-Cookie 的 4 个目标名随
    // 身份入池; 只记个数 (值不入 log)——真机若恒为 0, 即 Rex 侧
    // 未透传 Set-Cookie, Cookie 保持在该端自动降级。
    const ck = this._parseCookies(resp.headers);
    ctx.log("hg 注册回包 Cookie " + Object.keys(ck).length + " 个 (仅计数)");
    // klink_egdi 随身份落盘 (字段名在回包 8 字段基线内): 换身份
    // 重注册时作条件键回带 (见 _regHeader); 缺失记空串。
    const klink = (typeof json.klink_egdi === "string") ? json.klink_egdi : "";
    return { device_id: device_id, iid: iid, klink: klink, cdid: trio.cdid, openudid: trio.openudid, clientudid: trio.clientudid, ck: ck };
  },
  _parseV2(raw) {
    if (!raw || typeof raw !== "string") return null;
    let o = null;
    try { o = JSON.parse(raw); } catch (e) { return null; }
    if (!o || typeof o !== "object") return null;
    const s = (v) => (typeof v === "string" && v) ? v : ((typeof v === "number" && isFinite(v) && v > 0) ? String(Math.floor(v)) : "");
    const d = s(o.d), i = s(o.i), c = s(o.c);
    if (!d || !i || !c) return null;
    const tn = (typeof o.t === "number") ? o.t : Number(o.t);
    const t = (isFinite(tn) && tn > 0) ? tn : Date.now();
    return { device_id: d, iid: i, cdid: c, t: t };
  },
  _poolRecord(o) {
    if (!o || typeof o !== "object") return null;
    const s = (v) => (typeof v === "string" && v) ? v : ((typeof v === "number" && isFinite(v) && v > 0) ? String(Math.floor(v)) : "");
    const d = s(o.d), i = s(o.i), c = s(o.c);
    if (!d || !i || !c) return null;
    const num = (v, dft) => {
      const n = (typeof v === "number") ? v : ((typeof v === "string" && v.trim() !== "") ? Number(v) : NaN);
      return (isFinite(n) && n > 0) ? n : dft;
    };
    const born = num(o.born, num(o.t, Date.now()));
    // 三件套补造 (v0.2.9): 0.2.8 旧记录只有 c——cdid 沿用 c,
    // openudid/clientudid 加载时新造, 随下次 _persistPool 写回
    // (从此稳定)。klink 旧记录恒无, 记空串 (条件键回带时缺省
    // 不带该键)。
    const ou = (typeof o.o === "string" && o.o) ? o.o : AGG_CRYPTO.bytesToHex(this._randBytes(10));
    const cu = (typeof o.u === "string" && o.u) ? o.u : this._uuid();
    return {
      device_id: d, iid: i, cdid: c, openudid: ou, clientudid: cu,
      klink: (typeof o.k === "string") ? o.k : "",
      t: num(o.t, born), ck: this._ckClean(o.ck), born: born, lastOk: num(o.lastOk, 0), lastFail: num(o.lastFail, 0),
      used: (o.used === 1 || o.used === true) ? 1 : 0
    };
  },
  async _readPool(ctx) {
    let raw = "";
    try { raw = await ctx.storeGet("hg_pool_v1"); } catch (e) { return []; }
    if (!raw || typeof raw !== "string") return [];
    let arr = null;
    try { arr = JSON.parse(raw); } catch (e) { return []; }
    if (!Array.isArray(arr)) return [];
    const out = [];
    for (const o of arr) { const r = this._poolRecord(o); if (r) out.push(r); }
    return out.slice(0, this._POOL_MAX);
  },
  _knownAdd(rec) {
    if (!rec || !rec.device_id) return;
    if (!this._poolKnown) this._poolKnown = new Map();
    this._poolKnown.set(rec.device_id, rec);
  },
  _knownSeed(pool) { for (const r of pool || []) this._knownAdd(r); },
  _evictMerged(merged) {
    while (merged.length > this._POOL_MAX) {
      let victim = merged.length - 1, low = Infinity;
      for (let k = 1; k < merged.length; k++) {
        const sc = Math.max(merged[k].lastOk || 0, merged[k].born || 0);
        if (sc <= low) { low = sc; victim = k; }
      }
      merged.splice(victim, 1);
    }
    return merged;
  },
  _evictMerged(merged) {
    while (merged.length > this._POOL_MAX) {
      let victim = merged.length - 1, low = Infinity;
      for (let k = 1; k < merged.length; k++) {
        const sc = Math.max(merged[k].lastOk || 0, merged[k].born || 0);
        if (sc <= low) { low = sc; victim = k; }
      }
      merged.splice(victim, 1);
    }
    return merged;
  },
  _poolSerialize(pool) {
    return pool.map(idn => ({
      d: idn.device_id, i: idn.iid, c: idn.cdid,
      o: idn.openudid || "", u: idn.clientudid || "", k: idn.klink || "",
      t: idn.t || idn.born || Date.now(),
      ck: this._ckClean(idn.ck), born: idn.born || idn.t || Date.now(),
      lastOk: idn.lastOk || 0, lastFail: idn.lastFail || 0, used: idn.used ? 1 : 0
    }));
  },
  async _persistPool(ctx) {
    const job = (this._persistChain || Promise.resolve()).then(() => this._persistPoolNow(ctx));
    this._persistChain = job.catch(() => {});
    return job;
  },
  async _persistPoolNow(ctx) {
    try {
      const mem = (this._poolMem || []).slice(0, this._POOL_MAX);
      let stored = [];
      try { stored = await this._readPool(ctx); } catch (e) { stored = []; }
      if (!stored.length) {
        // 合并读为空先复读一次: 与载池读不一致即留证据行, 空读
        // 不直接采信 (真机存储层瞬时空读正是退化覆写的入口)。
        let again = [];
        try { again = await this._readPool(ctx); } catch (e) { again = []; }
        if (again.length) {
          ctx.log("hg 池读回不一致 (合并读首读空、复读 " + again.length + " 份)");
          stored = again;
        }
      }
      const seen = new Set();
      const merged = [];
      for (const r of mem) if (r && !seen.has(r.device_id)) { seen.add(r.device_id); merged.push(r); }
      for (const r of stored) if (r && !seen.has(r.device_id)) { seen.add(r.device_id); merged.push(r); }
      if (this._poolKnown) for (const r of this._poolKnown.values()) if (r && !seen.has(r.device_id)) { seen.add(r.device_id); merged.push(r); }
      this._evictMerged(merged);
      this._knownSeed(merged);
      if (this._poolMem) { this._poolMem.length = 0; for (const r of merged) this._poolMem.push(r); }
      else this._poolMem = merged;
      await ctx.storeSet("hg_pool_v1", JSON.stringify(this._poolSerialize(merged)));
      // 写后校验: 复读若缺了刚写的成员 (存储层写后读不一致),
      // 以「意图 ∪ 复读」再合并写一次; 仍缺只记行留证, 不循环。
      let back = null;
      try { back = await this._readPool(ctx); } catch (e) { back = null; }
      if (back) {
        const backIds = new Set(back.map(r => r.device_id));
        const missing = merged.filter(r => !backIds.has(r.device_id));
        if (missing.length) {
          const seen2 = new Set();
          const repaired = [];
          for (const r of merged) if (!seen2.has(r.device_id)) { seen2.add(r.device_id); repaired.push(r); }
          for (const r of back) if (!seen2.has(r.device_id)) { seen2.add(r.device_id); repaired.push(r); }
          this._evictMerged(repaired);
          this._knownSeed(repaired);
          if (this._poolMem) { this._poolMem.length = 0; for (const r of repaired) this._poolMem.push(r); }
          await ctx.storeSet("hg_pool_v1", JSON.stringify(this._poolSerialize(repaired)));
          ctx.log("hg 池落盘校验修复 (写后复读缺 " + missing.length + " 份已合并重写)");
        }
      }
    } catch (e) {
      ctx.log("hg 身份池落盘失败 (不影响本程取流): " + (e && e.message));
    }
  },
  async _poolAdd(ctx, idn) {
    this._knownAdd(idn);
    const pool = this._poolMem || (this._poolMem = []);
    const at = pool.findIndex(x => x.device_id === idn.device_id);
    if (at >= 0) pool.splice(at, 1);
    pool.unshift(idn);
    while (pool.length > this._POOL_MAX) {
      let victim = pool.length - 1, oldest = Infinity;
      for (let k = 1; k < pool.length; k++) {
        if (pool[k].lastFail > 0 && pool[k].lastFail < oldest) { oldest = pool[k].lastFail; victim = k; }
      }
      pool.splice(victim, 1);
    }
    await this._persistPool(ctx);
  },
  async _ensurePool(ctx) {
    if (this._poolMem) return this._poolMem;
    if (!this._poolPromise) {
      const self = this;
      const p = (async () => {
        let pool = await self._readPool(ctx);
        if (!pool.length) {
          // 首读为空复读一次再下结论: 真机存储层瞬时空读会让本程
          // 误判空池、冷注册后落盘抹掉存量成员 (0.2.9 真机丢员
          // 疑案入口之一)。两次不一致留证据行。
          const again = await self._readPool(ctx);
          if (again.length) {
            ctx.log("hg 池 init 首读空、复读 " + again.length + " 份 (读回不一致)");
            pool = again;
          }
        }
        self._poolFrom = pool.length ? "storage" : "";
        let imp = "无";
        if (!pool.length) {
          let rawV2 = "";
          try { rawV2 = await ctx.storeGet("hg_device_v2"); } catch (e) {}
          if (rawV2) {
            const v2 = self._parseV2(rawV2);
            const rec = v2 ? self._poolRecord({ d: v2.device_id, i: v2.iid, c: v2.cdid, t: v2.t, ck: {}, born: v2.t, lastOk: 0, lastFail: 0 }) : null;
            if (rec) {
              pool = [rec];
              imp = "成";
              self._poolFrom = "v2导入";
              self._poolMem = pool;
              await self._persistPool(ctx);
            } else imp = "败";
          }
        }
        self._poolMem = pool;
        self._knownSeed(pool);
        // 池初始化记账 (v0.2.9): 导入成败/份数/各成员年龄一行进
        // log 与 hg_stage——0.2.8 真机 pool1 之谜正因缺此行, 无
        // 从分辨是导入失败还是落盘竞态冲掉。只记形态不记原值。
        const ages = pool.map(x => self._idAge(x)).join(", ");
        const line = "池 init 导入=" + imp + " 份数=" + pool.length + " 年龄=[" + ages + "]";
        ctx.log("hg " + line);
        await self._stage(ctx, line);
        return pool;
      })();
      this._poolPromise = p;
      const clear = () => { if (self._poolPromise === p) self._poolPromise = null; };
      p.then(clear, clear);
    }
    return this._poolPromise;
  },
  _idAge(idn) {
    const t = (idn && typeof idn.t === "number" && isFinite(idn.t)) ? idn.t : 0;
    return t > 0 ? Math.max(0, Math.floor((Date.now() - t) / 1000)) : 0;
  },
  _startRegistration(ctx) {
    const self = this;
    const p = (async () => {
      const pf = await self._ensureProfile(ctx);
      const poolNow = self._poolMem || [];
      const trio = poolNow.length === 0
        ? { cdid: pf.cdid, openudid: pf.openudid, clientudid: pf.clientudid }
        : { cdid: self._uuid(), openudid: AGG_CRYPTO.bytesToHex(self._randBytes(10)), clientudid: self._uuid() };
      const raw = await self._registerDevice(ctx, { pf: pf, trio: trio, old: null });
      const now = Date.now();
      const idn = {
        device_id: raw.device_id, iid: raw.iid, cdid: trio.cdid,
        openudid: trio.openudid, clientudid: trio.clientudid, klink: raw.klink || "",
        t: now, ck: self._ckClean(raw.ck), born: now, lastOk: 0, lastFail: 0, used: 0
      };
      if (!self._poolMem) self._poolMem = [];
      await self._poolAdd(ctx, idn);
      return idn;
    })();
    this._regPromise = p;
    const clear = () => { if (self._regPromise === p) self._regPromise = null; };
    p.then(clear, clear);
    return p;
  },
  // ---- 单集取流 (v2.6.0, multi 已死后的主路) ----
  // POST /novel/player/video_model/v1/ {video_id, biz_param},
  // 回 {code:0, data:{video_model: 对象或字符串化 JSON}}。
  // 与 _playBatch 同一套参数/签名/UA, 只换路径与请求体; 地
  // 区头强制 cn/did (注册 Cookie 的 store-region 随出口 IP
  // 变 us/cn-gd, 用它会判死, 实测)。同一身份只发一集: 匿名
  // 身份第 2 发起同身份回空, 故调用方每集现注册 (见
  // _fetchWindowSingle), 本函数只保证单发、置 used=1。
  async _playSingle(ctx, identity, vid, host) {
    if (!identity || typeof identity !== "object") return { kind: "fail", model: null };
    if (!identity._acct) {
      if (identity._singleFired || identity.used === 1) { ctx.log("hg 单集纪律拦截: 身份已消耗"); return { kind: "fail", model: null }; }
      identity._singleFired = 1;
      identity.used = 1;
    }
    const base = "https://" + host + this._PLAY_SINGLE_PATH;
    const pf = identity._pfFixed || this._pf();
    const playUA = identity._uaFixed || this._playbackUA(pf);
    const params = {
      ac: "wifi", channel: "update_64", aid: "8662", app_name: "novelread",
      version_code: "73932", version_name: "7.3.9.32", device_platform: "android", os: "android",
      ssmix: "a", device_type: pf.device_type, device_brand: pf.device_brand, language: "zh", os_api: String(pf.os_api),
      os_version: pf.os_version, manifest_version_code: "73932", resolution: this._resNorm(pf.resolution, "*"), dpi: String(pf.dpi),
      update_version_code: "73932", host_abi: "arm64-v8a", dragon_device_type: pf.dragon_device_type || "phone", pv_player: "73932",
      compliance_status: "0", need_personal_recommend: "1", player_so_load: "1", is_android_pad_screen: "0",
      device_id: identity.device_id, iid: identity.iid, cdid: identity.cdid
    };
    const devices = {
      device_id: identity.device_id, iid: identity.iid, install_id: identity.iid, cdid: identity.cdid,
      device_brand: pf.device_brand, device_model: pf.device_type, device_type: pf.device_type,
      device_manufacturer: this._manufacturerOf(pf.device_brand), os_version: pf.os_version, version_name: "7.3.9.32",
      x_tt_dt: "", sec_device_token: "", device_sec_device_token: "", ua: playUA
    };
    const payload = {
      video_id: String(vid),
      biz_param: {
        detail_page_version: 0, device_level: 3, disable_digg_stat: false,
        need_all_video_definition: true, need_mp4_align: false,
        use_os_player: false, use_server_dns: false, video_platform: 1024
      }
    };
    const nowSec = Math.floor(Date.now() / 1000);
    const ct = "application/json; charset=UTF-8";
    const rng = {
      u16: () => Math.floor(Math.random() * 65536),
      u32: () => Math.floor(Math.random() * 4294967296),
      range: (a, b) => a + Math.floor(Math.random() * (b - a + 1))
    };
    let signed;
    try {
      const rticket = HG_CRYPTO.findBranch0Rticket(base, params, devices, payload, ct, nowSec);
      const baseHeaders = {
        "User-Agent": playUA,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "Content-Type": ct,
        "x-ss-req-ticket": String(rticket),
        "sdk-version": "2",
        "x-xs-from-web": "0",
        "x-tt-store-region": "cn",
        "x-tt-store-region-src": "did"
      };
      signed = HG_CRYPTO.coreSixgod(base, params, devices, payload, baseHeaders, rng, nowSec, rticket);
    } catch (e) {
      ctx.log("hg 单集六神签名失败: " + (e && e.message));
      return { kind: "fail", model: null };
    }
    const headers = Object.assign({}, signed.headers);
    if (identity._cookieFull) {
      headers["Cookie"] = identity._cookieFull; // v2.8.0 账号模式: 完整会话 cookie
    } else {
      const ck = (identity && identity.ck && typeof identity.ck === "object") ? identity.ck : {};
      const parts = [];
      for (const n of ["install_id", "ttreq", "store-region", "store-region-src"]) if (ck[n]) parts.push(n + "=" + ck[n]);
      if (parts.length) headers["Cookie"] = parts.join("; ");
    }
    let resp;
    try {
      resp = await this._postRaw(ctx, signed.url, JSON.stringify(payload), headers);
    } catch (e) {
      ctx.log("hg 单集 video_model 请求失败: " + (e && e.message));
      return { kind: "fail", model: null };
    }
    if (resp.status !== 200) { ctx.log("hg 单集 video_model HTTP " + resp.status + " @" + host); return { kind: "fail", model: null }; }
    if (!resp.text || !resp.text.trim()) { ctx.log("hg 单集 video_model 空回包 @" + host + " vid=" + vid); return { kind: "empty", model: null }; }
    let json = null;
    try { json = JSON.parse(resp.text); } catch (e) {}
    if (!json || typeof json !== "object") { ctx.log("hg 单集回包非 JSON vid=" + vid); return { kind: "fail", model: null }; }
    const code = (json.Code !== undefined && json.Code !== null) ? json.Code : json.code;
    if (Number(code || 0) !== 0) { ctx.log("hg 单集业务拒绝 code=" + code + " vid=" + vid); return { kind: "fail", model: null }; }
    const data = (json.data && typeof json.data === "object") ? json.data : {};
    let model = data.video_model;
    if (typeof model === "string") { try { model = JSON.parse(model); } catch (e) { model = null; } }
    if (!model || typeof model !== "object") { ctx.log("hg 单集无 video_model vid=" + vid); return { kind: "fail", model: null }; }
    return { kind: "ok", model: model };
  },

  // ---- 单集窗 (v2.6.0): 逐集现注册+单发, 顺序执行 ----
  // 每集一枚新身份 (匿名身份只能播 1 集, 复用回空); 并行注
  // 册会撞坏 (共享 _regPromise/画像), 故顺序。空/失败集换
  // 新身份切主机重发 1 次。返回与 _fetchWindow 同形
  // {kind, models, regs}: ≥1 集出线 → ok; 全空 → empty;
  // 注册本身失败 (regs=0) → fail (供上层记退避)。
  // v2.7.0 生产硬化: 单集身份用完即弃 → 瞬时铸造, 不入池:
  // 省掉逐枚 _poolAdd 的 Cache/KV 写 (子请求配额与 KV 日写
  // 量双省); 字段口径与 _startRegistration 的 idn 同形。
  async _mintSingle(ctx) {
    const pf = await this._ensureProfile(ctx);
    const trio = { cdid: this._uuid(), openudid: AGG_CRYPTO.bytesToHex(this._randBytes(10)), clientudid: this._uuid() };
    const raw = await this._registerDevice(ctx, { pf: pf, trio: trio, old: null });
    const now = Date.now();
    return { device_id: raw.device_id, iid: raw.iid, cdid: trio.cdid, openudid: trio.openudid, clientudid: trio.clientudid, klink: raw.klink || "", t: now, ck: this._ckClean(raw.ck), born: now, lastOk: 0, lastFail: 0, used: 0 };
  },

  // ---- JSTV 形态单集取流 (v2.11.0) ----
  // 2026-11-11 中午上游收紧: 旧 73932 代参数形态 (六神签名 +
  // video_platform:1024) 对一切身份全回 HTTP 200 空包; JSTV 形
  // 态 (73532 代参数 + PlayerSign 四头 + video_platform:3 +
  // content_type:1) 沙箱隔离实验验通 (匿名/账号身份均可)。
  // 身份: {device_id, iid, cookie|null}; 账号备用路传完整会话
  // Cookie (Exp2 验通: 73532 参数 + 账号身份/会话可通)。
  _JSTV_UA: "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
  async _playSingleJstv(ctx, identity, vid, host) {
    if (!identity || !identity.device_id || !identity.iid) return { kind: "fail", model: null };
    const payload = { video_id: String(vid), content_type: 1, biz_param: { need_all_video_definition: true, video_platform: 3 } };
    const bodyStr = JSON.stringify(payload);
    const bodyBytes = AGG_CRYPTO.utf8Encode(bodyStr);
    const base = "https://" + host + this._PLAY_SINGLE_PATH;
    const qs = new URLSearchParams({
      aid: "8662", app_name: "novelread", version_code: "73532", version_name: "7.3.5.32",
      manifest_version_code: "73532", update_version_code: "73532", channel: "update_64",
      device_platform: "android", os: "android", ssmix: "a", device_type: "25053RT47C",
      device_brand: "Redmi", language: "zh", os_api: "36", os_version: "16",
      resolution: "1280*2772", dpi: "520", ac: "wifi",
      device_id: String(identity.device_id), iid: String(identity.iid)
    });
    qs.sort();
    const tsSec = Math.floor(Date.now() / 1000);
    let rticket = Date.now(), url = "";
    for (let n = 0; n < 24; n++) {
      url = base + "?" + qs.toString() + "&_rticket=" + rticket;
      if (HG_CRYPTO.playerBranchOf(url, bodyBytes, tsSec) !== 1) break;
      rticket++;
    }
    let signed;
    try { signed = HG_CRYPTO.playerSignJstv(url, bodyBytes, tsSec, this._randBytes(11)); }
    catch (e) { ctx.log("hg JSTV 签名失败: " + (e && e.message)); return { kind: "fail", model: null }; }
    const headers = {
      "User-Agent": this._JSTV_UA, "Accept": "application/json", "Content-Type": "application/json; charset=utf-8",
      "X-XS-From-Web": "0", "Sdk-Version": "2", "X-SS-Req-Ticket": String(Date.now()),
      "X-SS-STUB": AGG_CRYPTO.bytesToHex(AGG_CRYPTO.md5Bytes(bodyBytes)).toUpperCase()
    };
    Object.assign(headers, signed);
    if (identity.cookie) headers["Cookie"] = identity.cookie;
    let resp;
    try { resp = await this._postRaw(ctx, url, bodyStr, headers); }
    catch (e) { ctx.log("hg JSTV video_model 请求失败: " + (e && e.message)); return { kind: "fail", model: null }; }
    if (resp.status !== 200) { ctx.log("hg JSTV video_model HTTP " + resp.status + " @" + host); return { kind: "fail", model: null }; }
    if (!resp.text || !resp.text.trim()) { ctx.log("hg JSTV video_model 空回包 @" + host + " vid=" + vid); return { kind: "empty", model: null }; }
    let json = null;
    try { json = JSON.parse(resp.text); } catch (e) {}
    if (!json || typeof json !== "object") { ctx.log("hg JSTV 回包非 JSON vid=" + vid); return { kind: "fail", model: null }; }
    const code = (json.Code !== undefined && json.Code !== null) ? json.Code : json.code;
    if (Number(code || 0) !== 0) { ctx.log("hg JSTV 业务拒绝 code=" + code + " vid=" + vid); return { kind: "fail", model: null }; }
    const data = (json.data && typeof json.data === "object") ? json.data : {};
    let model = data.video_model;
    if (typeof model === "string") { try { model = JSON.parse(model); } catch (e) { model = null; } }
    if ((!model || typeof model !== "object") && data.video_list) model = data;
    if (!model || typeof model !== "object") { ctx.log("hg JSTV 无 video_model vid=" + vid); return { kind: "fail", model: null }; }
    return { kind: "ok", model: model };
  },

  // JSTV 匿名身份: isolate 内单枚复用 (强注册 _registerDevice
  // Strong, 与 JSTV 同盐同端点同 ttEncrypt 构造); 并发首铸用
  // promise 合并, 被拒换新由 _fetchWindowSingle 置空触发。
  async _ensureJstvAnon(ctx) {
    if (this._jstvIdn) return this._jstvIdn;
    if (!this._jstvRegPromise) {
      const self = this;
      const p = (async () => {
        // v3.0.0: 先读 KV 持久身份 (冷 isolate 免注册; 身份可弃置, 24h 内复用)
        // v3.0.1 (监工 F1/F2): 本 isolate 已判死的身份 (self._jstvKvBan,
        // 按 device_id) 不许再从 KV 捡回, 命中即删 KV 防他 isolate 续捡;
        // KV 读写经 ctx.budget 预扣 (cap 同 ctx.budgetCap 口径)。
        const kv = (ctx && ctx.env && ctx.env.HG_KV) || null;
        const kvCharge = (n) => {
          if (!ctx || !ctx.budget) return true;
          const cap = ctx.budgetCap || HG_FETCH_BUDGET;
          if (ctx.budget.fetches + n > cap) return false;
          ctx.budget.fetches += n;
          return true;
        };
        if (kv && kvCharge(1)) {
          try {
            const rawKv = await kv.get("hg_jstv_idn");
            if (rawKv) {
              const o = JSON.parse(rawKv);
              if (o && o.d && self._jstvKvBan && String(o.d) === String(self._jstvKvBan)) {
                if (kvCharge(1)) { try { await kv.delete("hg_jstv_idn"); } catch (e) {} }
              } else if (o && o.d && o.i && (Date.now() - (o.t || 0)) < 24 * 3600 * 1000) {
                const idnKv = { device_id: String(o.d), iid: String(o.i), cookie: null };
                self._jstvIdn = idnKv;
                return idnKv;
              }
            }
          } catch (e) {}
        }
        self._jstvRegTotal = (self._jstvRegTotal || 0) + 1;
        const raw = await self._registerDeviceStrong(ctx);
        const idn = { device_id: String(raw.device_id), iid: String(raw.iid), cookie: null };
        self._jstvIdn = idn;
        if (kv && kvCharge(1)) { try { await kv.put("hg_jstv_idn", JSON.stringify({ d: idn.device_id, i: idn.iid, t: Date.now() })); } catch (e) {} }
        return idn;
      })();
      this._jstvRegPromise = p;
      const clear = () => { if (self._jstvRegPromise === p) self._jstvRegPromise = null; };
      p.then(clear, clear);
    }
    return this._jstvRegPromise;
  },

  // v3.0.0 单集快铸 (/tap 热路): 无闸门抖动——匿名两发 (双
  // host) -> 整集落空换一枚身份再两发 -> 账号备用两发。每发
  // 与注册都经 ctx.budget 记账 (HG_FETCH_BUDGET), 预算尽即
  // 停 (回 lastKind)。健康字段口径同窗路 acctStat。
  async _mintOneFast(ctx, vid, acct) {
    const charge = (n) => {
      if (!ctx.budget) return true;
      const cap = ctx.budgetCap || HG_FETCH_BUDGET;
      if (ctx.budget.fetches + n > cap) return false;
      ctx.budget.fetches += n;
      return true;
    };
    let regs = 0, lastKind = "fail";
    const tryAnon = async () => {
      let idn = this._jstvIdn;
      if (!idn) {
        if (!charge(1)) return null;
        const before = this._jstvRegTotal || 0;
        try { idn = await this._ensureJstvAnon(ctx); }
        catch (e) { ctx.log("hg tap 注册失败: " + (e && e.message)); return null; }
        regs += (this._jstvRegTotal || 0) - before;
      }
      if (!idn) return null;
      for (let s = 0; s < 2; s++) {
        if (!charge(1)) return null;
        const r = await this._playSingleJstv(ctx, idn, vid, this._PLAY_HOSTS[s % this._PLAY_HOSTS.length]);
        if (r.kind === "ok" && r.model) return r.model;
        lastKind = r.kind;
      }
      return null;
    };
    let model = await tryAnon();
    if (model) return { model: model, lane: "anon", regs: regs, acctOk: null, anonDead: false, kind: "ok" };
    if (this._jstvIdn) this._jstvKvBan = this._jstvIdn.device_id; // v3.0.1 判死登记 (监工 F1): 不许再从 KV 捡回这枚
    this._jstvIdn = null; // 整集落空: 换身份再试一轮 (与窗路连击换新同口径)
    model = await tryAnon();
    if (model) return { model: model, lane: "anon", regs: regs, acctOk: null, anonDead: false, kind: "ok" };
    if (acct) {
      const acctIdn = { device_id: acct.device_id, iid: acct.iid, cookie: acct._cookieFull };
      let acctTried = false; // v3.0.1 (监工 F3 附带): 预算耗尽没真打过不许记 acctOk=false
      for (let s = 0; s < 2; s++) {
        if (!charge(1)) break;
        acctTried = true;
        const r = await this._playSingleJstv(ctx, acctIdn, vid, this._PLAY_HOSTS[s % this._PLAY_HOSTS.length]);
        if (r.kind === "ok" && r.model) return { model: r.model, lane: "acct", regs: regs, acctOk: true, anonDead: true, kind: "ok" };
        lastKind = r.kind;
      }
      return { model: null, lane: null, regs: regs, acctOk: acctTried ? false : null, anonDead: true, kind: lastKind };
    }
    return { model: null, lane: null, regs: regs, acctOk: null, anonDead: true, kind: lastKind };
  },

  async _fetchWindowSingle(ctx, vids, acct) {
    // v2.11.0 双路 (用户 2026-11-11 拍板): 主路 = JSTV 形态 +
    // 强注册匿名身份 (单枚复用, 空回连击 2 窗换新、每窗至多换
    // 2 枚); 备用 = 用户账号会话 (同 JSTV 形态 + 完整 Cookie,
    // 连失 2 集判失效)。两路在飞 <=2 + 每发 120-400ms 抖动。
    // 返回契约不变 {kind, models, regs, acct}: acct 增
    // anonUsed/anonDead 供健康记账分路。
    const models = {};
    let regs = 0, regFailed = false, stopped = false;
    const t0 = Date.now();
    const charge = (n) => {
      if (!ctx.budget) return true;
      if (ctx.budget.fetches + n > HG_FETCH_BUDGET) { stopped = true; ctx.log("hg 单集窗配额见底, 余集留待点播 invocation 补取"); return false; }
      ctx.budget.fetches += n;
      return true;
    };
    let inFlight = 0;
    const gate = async () => {
      while (inFlight >= 2) await _sleepMs(60);
      inFlight++;
      await _sleepMs(120 + Math.floor(Math.random() * 280));
    };
    const shot = async (idn, vid, host) => {
      await gate();
      try { return await this._playSingleJstv(ctx, idn, vid, host); }
      finally { inFlight--; }
    };
    let anonUsed = 0, anonStrikes = 0, anonSwaps = 0, anonDead = false;
    let acctUsed = 0, acctStrikes = 0, acctDead = !acct;
    const acctIdn = acct ? { device_id: acct.device_id, iid: acct.iid, cookie: acct._cookieFull } : null;
    let idx = 0;
    const lane = async () => {
      while (idx < vids.length && !stopped) {
        const vid = vids[idx++];
        if (Date.now() - t0 > 13000) { stopped = true; ctx.log("hg 单集窗软截止, 余集留待点播补取"); break; }
        let got = null;
        if (!anonDead) {
          for (let s = 0; s < 2 && !got && !stopped; s++) {
            let idn = null;
            if (!this._jstvIdn) {
              if (!charge(1)) break;
              const regBefore = this._jstvRegTotal || 0;
              try { idn = await this._ensureJstvAnon(ctx); }
              catch (e) { ctx.log("hg JSTV 注册失败: " + (e && e.message)); regFailed = true; anonDead = true; break; } // 注册层故障本窗不再重试 (防超时吃满软截止), 下窗自愈
              regs += (this._jstvRegTotal || 0) - regBefore;
            } else idn = this._jstvIdn;
            if (!idn) { regFailed = true; break; }
            if (!charge(1)) break;
            const r = await shot(idn, vid, this._PLAY_HOSTS[s % this._PLAY_HOSTS.length]);
            if (r.kind === "ok" && r.model) { got = r.model; anonUsed++; anonStrikes = 0; }
          }
          if (!got && !stopped) {
            anonStrikes++;
            if (anonStrikes >= 2) {
              if (anonSwaps < 2) { anonSwaps++; if (this._jstvIdn) this._jstvKvBan = this._jstvIdn.device_id; this._jstvIdn = null; anonStrikes = 0; ctx.log("hg JSTV 匿名身份疑似被拒, 换新身份"); }
              else { anonDead = true; ctx.log("hg JSTV 匿名路判死, 本窗余集走账号备用"); }
            }
          }
        }
        if (!got && !acctDead && !stopped) {
          for (let s = 0; s < 2 && !got && !stopped; s++) {
            if (!charge(1)) break;
            const r = await shot(acctIdn, vid, this._PLAY_HOSTS[s % this._PLAY_HOSTS.length]);
            if (r.kind === "ok" && r.model) { got = r.model; acctUsed++; acctStrikes = 0; }
          }
          if (!got && !stopped) {
            acctStrikes++;
            if (acctStrikes >= 2) { acctDead = true; ctx.log("hg 账号备用路疑似失效"); }
          }
        }
        if (got) models[String(vid)] = got;
      }
    };
    await Promise.all([lane(), lane()]);
    if (anonUsed) ctx.log("hg JSTV 匿名出窗 " + anonUsed + " 集");
    if (acctUsed) ctx.log("hg 账号备用出窗 " + acctUsed + " 集");
    const acctStat = { had: !!acct, used: acctUsed, dead: acctDead && !!acct, anonUsed: anonUsed, anonDead: anonDead };
    if (Object.keys(models).length) return { kind: "ok", models: models, regs: regs, acct: acctStat };
    if (stopped && regs === 0 && !regFailed) return { kind: "empty", models: {}, regs: regs, acct: acctStat };
    if (regFailed) return { kind: "fail", models: {}, regs: regs, acct: acctStat };
    return { kind: "empty", models: {}, regs: regs, acct: acctStat };
  },
  async _fetchWindow(ctx, vids) {
    const job = (this._batchChain || Promise.resolve()).then(() => this._fetchWindowNow(ctx, vids));
    this._batchChain = job.catch(() => {});
    return job;
  },
  async _fetchWindowNow(ctx, vids) {
    try { await this._ensureProfile(ctx); } catch (e) {}
    try { await this._ensurePool(ctx); } catch (e) {}
    let regs = 0;
    for (let shot = 0; shot < 2; shot++) {
      let idn = null;
      try {
        const rp = this._regPromise || this._startRegistration(ctx);
        idn = await rp;
        regs++;
      } catch (e) {
        ctx.log("hg batch 注册失败: " + (e && e.message));
        return { kind: "fail", models: {}, regs: regs };
      }
      if (!idn) return { kind: "fail", models: {}, regs: regs };
      // used 不在此预置: 由 _playBatch 入口在发请求前同步置位
      // (单发纪律的结构性标记), 本发结束的 ok/fail 落盘分支随
      // 即写盘。进程若恰在 multi 在途时死掉, 盘上 used 可能未
      // 及写入——可接受: 池在 v0.3.0 只是注册记账本, play 永
      // 不从池选身份, 纪律由入口置标 + play 恒新注册保证。
      const host = this._PLAY_HOSTS[shot % this._PLAY_HOSTS.length];
      const r = await this._playBatch(ctx, idn, vids, host);
      if (r.kind === "ok") {
        idn.lastOk = Date.now();
        await this._persistPool(ctx);
        return { kind: "ok", models: r.models, regs: regs };
      }
      idn.lastFail = Date.now();
      await this._persistPool(ctx);
      if (r.kind !== "empty") return { kind: r.kind, models: {}, regs: regs };
      if (shot === 0) ctx.log("hg batch 首发空回包, 换新身份切主机重发同窗");
    }
    return { kind: "empty", models: {}, regs: regs };
  },
  async _playBatch(ctx, identity, vids, host) {
    // 单发纪律的结构性拦截 (协议监工 FAIL 修复): 一生一发由
    // 本入口强制, 不靠调用方约定。进入即同步置标 (第一个
    // await 之前完成, 并发进入也只有一个能过): 同一身份对
    // 象第二次进入 (含经 _playOnce 包装、绕过 _fetchWindow
    // 串行链的直调、并发直调 _fetchWindowNow 共用同一枚身份)
    // 在发请求前直接拒绝; 落盘复原的记录 used=1 (无进程内
    // 标记) 同样拒绝——它的那一发已在先前进程打过。used 的
    // 置位收归此处, _fetchWindowNow 不再预置。
    if (!identity || typeof identity !== "object") return { kind: "fail", models: {} };
    if (identity._multiFired || identity.used === 1) {
      ctx.log("hg 单发纪律拦截: 身份已消耗, 拒绝第二发 multi");
      return { kind: "fail", models: {} };
    }
    identity._multiFired = 1;
    identity.used = 1;
    const base = "https://" + host + this._PLAY_PATH;
    // 公共参数与 UA (v0.2.9 立 73932; v2.5.4 起播放系升
    // 74332、注册仍 73932——jackotom 6.6 的注册/播放分代)、设备
    // 字段与 UA 均从持久画像现取 (三处同源); 身份三值取池成员
    // 记录 (cdid = 该成员三件套的 cdid)。channel 沿 app-source
    // 存量缺省 update_64 (探针已验形态, 不随画像 channel 变)。
    const pf = this._pf();
    const playUA = this._playbackUA(pf);
    const params = {
      ac: "wifi", channel: "update_64", aid: "8662", app_name: "novelread",
      version_code: "74332", version_name: "7.4.3.32", device_platform: "android", os: "android",
      ssmix: "a", device_type: pf.device_type, device_brand: pf.device_brand, language: "zh", os_api: String(pf.os_api),
      os_version: pf.os_version, manifest_version_code: "74332", resolution: this._resNorm(pf.resolution, "*"), dpi: String(pf.dpi),
      update_version_code: "74332", host_abi: "arm64-v8a", dragon_device_type: pf.dragon_device_type || "phone", pv_player: "74332",
      compliance_status: "0", need_personal_recommend: "1", player_so_load: "1", is_android_pad_screen: "0",
      device_id: identity.device_id, iid: identity.iid, cdid: identity.cdid
    };
    const devices = {
      device_id: identity.device_id, iid: identity.iid, install_id: identity.iid, cdid: identity.cdid,
      device_brand: pf.device_brand, device_model: pf.device_type, device_type: pf.device_type,
      device_manufacturer: this._manufacturerOf(pf.device_brand), os_version: pf.os_version, version_name: "7.4.3.32",
      x_tt_dt: "", sec_device_token: "", device_sec_device_token: "", ua: playUA
    };
    const payload = {
      biz_param: {
        detail_page_version: 0, device_level: 3, disable_digg_stat: false,
        need_all_video_definition: true, need_mp4_align: false,
        use_os_player: false, use_server_dns: false, video_platform: 1024
      },
      mixed_video_id_map: { "1004": vids.map(String) }
    };
    const nowSec = Math.floor(Date.now() / 1000);
    const ct = "application/json; charset=UTF-8";
    const rng = {
      u16: () => Math.floor(Math.random() * 65536),
      u32: () => Math.floor(Math.random() * 4294967296),
      range: (a, b) => a + Math.floor(Math.random() * (b - a + 1))
    };
    // v2.5.4 新请求格式 (jackotom 6.6 口径): 正文先 gzip, 六
    // 神签名/x-ss-stub/branch 搜索全对实际发送的压缩字节算
    // (HG_CRYPTO 的 jsonBodyMd5 对 Uint8Array 直取原始字节)。
    // 压缩只算一次, 搜索与发送共用同一份字节; 无
    // CompressionStream 的宿主退回明文旧形态。
    const rawBody = JSON.stringify(payload);
    let bodyData = rawBody;
    if (typeof CompressionStream === "function") {
      try { bodyData = await this._gzipBody(rawBody); } catch (e) { bodyData = rawBody; }
    }
    const gzipped = bodyData !== rawBody;
    let signed;
    try {
      const rticket = HG_CRYPTO.findBranch0Rticket(base, params, devices, bodyData, ct, nowSec);
      // store-region 两头 (v0.2.8): 身份带 Cookie 时按 HGTV 形态
      // 由 cookie 派生 (store-region / store-region-src 的值);
      // 身份完全无 cookie (v2 导入的老身份等) 时沿用 app-source
      // 静态值 cn/did (即 v0.2.7 的实际发送形态); 有 cookie 但缺
      // 对应名则不带该头, 不伪造。
      const ck = (identity && identity.ck && typeof identity.ck === "object") ? identity.ck : {};
      const hasCk = Object.keys(ck).length > 0;
      const baseHeaders = {
        "User-Agent": playUA,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "Content-Type": ct,
        "x-ss-req-ticket": String(rticket),
        "sdk-version": "2",
        "x-xs-from-web": "0",
        "passport-sdk-version": "5051452",
        "x-ss-dp": String(params.aid)
      };
      if (gzipped) baseHeaders["Content-Encoding"] = "gzip";
      const region = ck["store-region"] || (hasCk ? "" : "cn");
      const regionSrc = ck["store-region-src"] || (hasCk ? "" : "did");
      if (region) baseHeaders["x-tt-store-region"] = region;
      if (regionSrc) baseHeaders["x-tt-store-region-src"] = regionSrc;
      signed = HG_CRYPTO.coreSixgod(base, params, devices, bodyData, baseHeaders, rng, nowSec, rticket);
    } catch (e) {
      ctx.log("hg 六神签名失败: " + (e && e.message));
      return { kind: "fail", models: {} };
    }
    const headers = Object.assign({}, signed.headers);
    // Cookie 头 (v0.2.8): 身份 ck 里有哪个带哪个 (HGTV 回带形
    // 态); 签名完成后附加, 不进六神签名头集合 (签名输入与既有
    // 已验形态保持一致, 只多回带这一头)。
    {
      const ck = (identity && identity.ck && typeof identity.ck === "object") ? identity.ck : {};
      const parts = [];
      for (const n of ["install_id", "ttreq", "store-region", "store-region-src"]) if (ck[n]) parts.push(n + "=" + ck[n]);
      if (parts.length) headers["Cookie"] = parts.join("; ");
    }
    let resp;
    try {
      resp = await this._postRaw(ctx, signed.url, bodyData, headers);
    } catch (e) {
      ctx.log("hg multi_video_model 请求失败: " + (e && e.message));
      return { kind: "fail", models: {} };
    }
    if (resp.status !== 200) { ctx.log("hg multi_video_model HTTP " + resp.status + " @" + host); return { kind: "fail", models: {} }; }
    // 空回包记原始形态 (v0.2.8 起带 st/len): 设备侧被拒的原始形
    // 态 (HGTV 实测为 200+0B) 靠这行看清, 不再只有 kind=empty。
    if (!resp.text || !resp.text.trim()) { ctx.log("hg multi_video_model 空回包 @" + host + " st=" + resp.status + " len=" + (resp.text ? String(resp.text).length : 0) + " 身份年龄=" + this._idAge(identity) + " 窗口集数=" + vids.length); return { kind: "empty", models: {} }; }
    let json = null;
    try { json = JSON.parse(resp.text); } catch (e) {}
    if (!json || typeof json !== "object") { ctx.log("hg multi_video_model 回包非 JSON"); return { kind: "fail", models: {} }; }
    const code = (json.Code !== undefined && json.Code !== null) ? json.Code : json.code;
    if (Number(code || 0) !== 0) { ctx.log("hg multi_video_model 业务拒绝 code=" + code); return { kind: "fail", models: {} }; }
    // 逐集收 model: 回包 data 以 vid 为键; 缺条目/空 model 的集
    // 跳过 (部分回包不整窗作废——窗口内其余集照常成线钉存)。
    const data = (json.data && typeof json.data === "object") ? json.data : {};
    const models = {};
    for (const v of vids) {
      const entry = data[String(v)];
      if (!entry || typeof entry !== "object") continue;
      let model = entry.video_model;
      if (typeof model === "string") {
        try { model = JSON.parse(model); } catch (e) { model = null; }
      }
      if (model && typeof model === "object") models[String(v)] = model;
    }
    if (!Object.keys(models).length) { ctx.log("hg 回包 data 无可用 video_model (请求 " + vids.length + " 集)"); return { kind: "fail", models: {} }; }
    return { kind: "ok", models: models };
  },
};

// ============================================================
// Worker ctx: Rex 侧 ctx 契约 (httpPostRaw/storeGet/storeSet/
// log) 垫到 fetch + isolate 内存 Map。httpPostRaw 透传响应头
// (set-cookie 数组), 供注册链收 Cookie (引擎 _parseCookies)。
// ============================================================
const _memStore = new Map();
// v2.5.1: 最近日志环形缓冲 (仅内存, 供注册失败时随
// hg_last_fail 一并落 KV 定因; 每行截 200 字, 留尾 8 行)。
let _lastLogs = [];
function _noteLog(m) {
  try { _lastLogs.push(String(m).slice(0, 200)); if (_lastLogs.length > 8) _lastLogs.shift(); } catch (e) {}
}
function _workerCtx() {
  return {
    httpPostRaw: async (url, body, headers) => {
      const res = await fetch(url, {
        method: "POST",
        headers: headers || {},
        body: (body === null || body === undefined) ? "" : body,
        signal: AbortSignal.timeout(30000)
      });
      const text = await res.text();
      const hdrs = {};
      try {
        const sc = (typeof res.headers.getSetCookie === "function") ? res.headers.getSetCookie() : [];
        if (sc && sc.length) hdrs["set-cookie"] = sc;
      } catch (e) {}
      return { status: res.status, text: text, headers: hdrs };
    },
    storeGet: async (k) => (_memStore.has(k) ? _memStore.get(k) : ""),
    storeSet: async (k, v) => { _memStore.set(k, String(v)); },
    log: (m) => { _noteLog(m); try { console.log("[hg-relay] " + m); } catch (e) {} }
  };
}

function _json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" }
  });
}

// 一窗取 model: 引擎 _fetchWindow 串行链 (每发新注册 + 一发
// 批量 + 空回包换新身份重发 1 次) 原样复用, 终点改回 models。
// hg_reg_at 存储: CF 走 KV 绑定 HG_KV; 无 KV 绑定时 (Deno
// 备胎) 退化为 isolate 内存时间戳 (节流强度弱一档, 功能等价)。
let _regAtMem = 0;
async function _regAtGet(env) {
  if (env && env.HG_KV) {
    try { return parseInt((await env.HG_KV.get("hg_reg_at")) || "0", 10) || 0; } catch (e) { return 0; }
  }
  return _regAtMem;
}
async function _regAtPut(env) {
  const now = Date.now();
  if (env && env.HG_KV) { try { await env.HG_KV.put("hg_reg_at", String(now)); } catch (e) {} }
  _regAtMem = now;
}
// ---- model 健全性检查 (v2.1.0; v2.2.0 按协议监工 FAIL 对
// 齐): 达标 ≡ 模块侧 _pickTopLine 能出线。判定逐项复刻模块
// 口径 (engines/hg.js 为准, 勿凭印象改): 条目收集同
// _collectItems (只认 main_url/backup_url/backup_url_1/
// play_addr/spade_a/encrypt_info 键); codec 直挂优先
// (item.codec_type || video_meta.codec_type), bytevc2/bvc2
// 排除、其余 (bytevc1/h264/hevc/无 codec) 都是候选; 只在最
// 高像素组内要求至少一条 mediaUrl+spadeValue 非空且
// deriveContentKey 成功。旧口径 (见 video_meta.codec_type
// 且必须恰有 bytevc1) 双向都有反例: codec-only 节点假达标、
// h264/hevc-only 完好集被误杀进 bad (协议监工实跑复现)。
function _sanePixels(item) {
  const meta = (item.video_meta && typeof item.video_meta === "object") ? item.video_meta : {};
  const pairs = [[item.vwidth, item.vheight], [item.width, item.height], [meta.vwidth, meta.vheight], [meta.width, meta.height]];
  for (const pr of pairs) {
    const w = Number(pr[0]) || 0, h = Number(pr[1]) || 0;
    if (w > 0 && h > 0) return Math.min(w, h);
  }
  const text = String(item.definition || item.quality_desc || meta.definition || "");
  const m = /(2160|1440|1080|720|576|540|480|360)/.exec(text);
  if (m) return parseInt(m[1], 10);
  const vh = parseInt(item.vheight || meta.vheight || 0, 10) || 0;
  return vh > 0 ? vh : 0;
}
function _saneCollect(value, out) {
  if (Array.isArray(value)) { for (const v of value) _saneCollect(v, out); return; }
  if (!value || typeof value !== "object") return;
  if (["main_url", "backup_url", "backup_url_1", "play_addr", "spade_a", "encrypt_info"].some(k => k in value)) { out.push(value); return; }
  for (const k of Object.keys(value)) _saneCollect(value[k], out);
}
function _modelSane(model) {
  if (!model || typeof model !== "object") return false;
  let vl = null;
  try { vl = HG_CRYPTO.videoListFromModel(model); } catch (e) { vl = null; }
  if (!vl) return false;
  const items = [];
  _saneCollect(vl, items);
  const cands = [];
  for (const item of items) {
    const codec = String(item.codec_type || (item.video_meta || {}).codec_type || "").toLowerCase();
    if (codec === "bytevc2" || codec === "bvc2") continue;
    cands.push({ item: item, pixels: _sanePixels(item) });
  }
  if (!cands.length) return false;
  let top = 0;
  for (const c of cands) if (c.pixels > top) top = c.pixels;
  for (const c of cands) {
    if (c.pixels !== top) continue;
    if (!HG_CRYPTO.mediaUrl(c.item) || !HG_CRYPTO.spadeValue(c.item)) continue;
    let key = null;
    try { key = HG_CRYPTO.deriveContentKey(HG_CRYPTO.spadeValue(c.item)); } catch (e) { key = null; }
    if (key) return true;
  }
  return false;
}

// ---- model 缓存: v2.5.3 起整窗一条存 Cache API (键
// v2/win/<首 vid>, 值 {models}); v2.5.2 及以前逐 vid 一条,
// 每窗探 15＋写 15 把免费版 50 子请求配额吃穿 (见文件头
// v2.5.2/v2.5.3 注)。TTL 口径不变: min(1800, 窗内各 model
// 的 url_expire-5-now), ≤0 不写。缓存只存达标 model; bad
// 集永不入缓存。平台无 caches 时整体禁用、退化为纯 KV/
// 现取行为, 不影响正确性。
function _modelCache() {
  try { return (typeof caches !== "undefined" && caches.default) ? caches.default : null; } catch (e) { return null; }
}
function _winCacheKey(firstVid) {
  return new Request("https://hg-relay.model-cache/v2/win/" + firstVid, { method: "GET" });
}
async function _winCacheGet(firstVid) {
  const c = _modelCache();
  if (!c || !firstVid) return null;
  try {
    const res = await c.match(_winCacheKey(firstVid));
    if (!res) return null;
    const j = await res.json();
    return (j && typeof j === "object" && j.models && typeof j.models === "object") ? j.models : null;
  } catch (e) { return null; }
}
async function _winCachePut(firstVid, models) {
  const c = _modelCache();
  if (!c || !firstVid) return;
  const vids = Object.keys(models || {});
  if (!vids.length) return;
  try {
    let ttl = 1800;
    const nowS = Date.now() / 1000;
    for (const v of vids) {
      const ue = Number((models[v] || {}).url_expire);
      if (isFinite(ue) && ue > 0) { const cap = Math.floor(ue - 5 - nowS); if (cap < ttl) ttl = cap; }
    }
    if (ttl <= 0) return; // 窗内有地址已临期/过期, 整窗不入缓存 (与 KV 批次同口径)
    await c.put(_winCacheKey(firstVid), new Response(JSON.stringify({ models: models }), {
      headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=" + ttl }
    }));
  } catch (e) {}
}

// ---- model KV 全局镜像 (v2.5.0): Cache API 按 colo 存——
// 预热暖在 A 节点、用户请求落 B 节点即白暖 (2026-11-10 活
// 体实锤: 同节点复打 90ms 命中、跨节点必重注册)。故注册取
// 回的整窗达标 model 另以「一窗一条」镜像进 HG_KV (键
// hg_mwin:<首 vid>, 值 {exp, models}), 全节点可读; 写量
// 一窗一次 (逐 vid 写一窗 15 次, 免费版写配额吃不消)。
// TTL 与 Cache API 同口径: min(1800, 各 model 的
// url_expire-5-now), <60 不写 (KV expirationTtl 下限);
// payload 内 exp 双保险, 读侧过期视同未命中。无 KV 绑定
// 时整体跳过 (退化为纯 Cache API 行为)。
async function _kvBatchPut(env, firstVid, models) {
  if (!env || !env.HG_KV || !firstVid) return;
  const vids = Object.keys(models || {});
  if (!vids.length) return;
  try {
    let ttl = 1800;
    const nowS = Date.now() / 1000;
    for (const v of vids) {
      const ue = Number((models[v] || {}).url_expire);
      if (isFinite(ue) && ue > 0) { const cap = Math.floor(ue - 5 - nowS); if (cap < ttl) ttl = cap; }
    }
    if (ttl < 60) return;
    await env.HG_KV.put("hg_mwin:" + firstVid, JSON.stringify({ exp: Math.floor(nowS) + ttl, models: models }), { expirationTtl: ttl });
  } catch (e) {}
}
async function _kvBatchGet(env, firstVid) {
  if (!env || !env.HG_KV || !firstVid) return null;
  try {
    const s = await env.HG_KV.get("hg_mwin:" + firstVid);
    if (!s) return null;
    const j = JSON.parse(s);
    if (!j || typeof j !== "object" || !j.models || typeof j.models !== "object") return null;
    if (j.exp && j.exp <= Math.floor(Date.now() / 1000)) return null;
    return j.models;
  } catch (e) { return null; }
}
// 用 KV 批次填 models: 先试键 vids[0]、再试 missVids[0]
// (原取数首 vid 可能不同); 命中的批次顺带回填本节点
// Cache API (后续同节点读走快路)。回实际填入数。
async function _fillFromKv(env, vids, missVids, models) {
  const tried = {};
  let filled = 0;
  for (const k of [vids[0], missVids[0]]) {
    if (!k || tried[k]) continue;
    tried[k] = true;
    const batch = await _kvBatchGet(env, k);
    if (!batch) continue;
    await _winCachePut(k, batch); // v2.5.3: 整窗回填本节点缓存 (一条)
    for (const v of missVids) if (!models[v] && batch[v]) { models[v] = batch[v]; filled++; }
    if (filled >= missVids.length) break;
  }
  return filled;
}

// ---- 注册节流闸参数 (v2.2.0): 生产定版闸长 5s、闸内最
// 长等待 10s、每 2s 复查一轮。做成可注入常量: env 同名键
// (HG_GATE_MS/HG_WAIT_MS/HG_POLL_MS, 毫秒) 注入合法值时覆
// 盖——本地 harness 以秒级小参数加速验证等待语义, 生产不注
// 入即缺省。模块侧契约不变 (回包形与 429 形态都不动)。
const GATE_MS = 5000, WAIT_MS = 10000, POLL_MS = 2000;
function _gateParam(env, name, dft) {
  const n = parseInt(String((env && env[name]) || ""), 10);
  return (isFinite(n) && n > 0) ? n : dft;
}
function _sleepMs(ms) { return new Promise(r => setTimeout(r, ms)); }

// ---- 注册失败指数退避 (v2.2.0 追加): 只挂注册失败路径——
// _fetchWindow 回 kind=fail 且 regs=0 即注册本身失败 (regs>=1
// 的任何结果都证明注册已通: ok/empty/下游 fail 均清账)。
// 连续失败 30s 起 doubling、300s 封顶, KV hg_reg_backoff 存
// {failures, retryAt, kind}; 冷却期内 /play 直接回 kind=fail
// 不试探注册 (全窗缓存命中的调用在冷却检查之前已直出, 不
// 受影响)。无 KV (Deno 备胎未绑) 时内存兜底。
let _backoffMem = null;
async function _backoffGet(env) {
  if (env && env.HG_KV) {
    try {
      const s = await env.HG_KV.get("hg_reg_backoff");
      if (s) { const j = JSON.parse(s); if (j && typeof j === "object" && j.retryAt) return j; }
    } catch (e) {}
    return null;
  }
  return _backoffMem;
}
async function _backoffPut(env, obj) {
  _backoffMem = obj;
  if (env && env.HG_KV) {
    try { await env.HG_KV.put("hg_reg_backoff", obj ? JSON.stringify(obj) : ""); } catch (e) {}
  }
}
async function _backoffRecord(env) {
  const prev = await _backoffGet(env);
  const n = ((prev && prev.failures) || 0) + 1;
  const delaySec = Math.min(300, 30 * Math.pow(2, n - 1));
  await _backoffPut(env, { failures: n, retryAt: Date.now() + delaySec * 1000, kind: "fail" });
}

// 注册+批量取+逐集过滤 (达标入缓存) 的共享段: 同窗 (未命中
// 集集合相同) 的并发调用经 _playFlights 合并为一发——先到者
// 真注册, 后到者直接用其结果, 不重复烧身份。跨 isolate 不
// 共享 (CF 多实例各自一份), 那一层靠闸戳+缓存收敛。
let _playFlights = {};
// v2.7.0 单集路配额预算: 免费版每 invocation 的 fetch+Cache
// 总量 ≤50; 单集路一集两发 (注册+取流), 45 集全量预热必爆。
// 主窗优先、预热共享同一 env 上的预算袋, 耗尽即停: 部分窗
// 照常交付, 缺集由模块点播时另起 invocation 补取。
const _invBudgets = new WeakMap();
const HG_FETCH_BUDGET = 36;
// v3.0.1 (监工 F2): /tap 路全子请求预算顶——fetch 与 Cache/KV
// 操作同袋预扣, cap 46 (CF 免费版每 invocation 50 留 4 余量)。
const HG_OP_BUDGET = 46;
// v2.8.0 账号模式: HG_SESSION (secret) = {device_id, iid, cdid, jar}
// 短信登录换来的会话; 带会话 cookie 的身份可无限复用 (实测
// 15/15), 整窗零注册。会话失效时 _fetchWindowSingle 自动回
// 落匿名逐集铸造, 不中断服务。
function _acctFromEnv(env) {
  try {
    const s = env && env.HG_SESSION ? JSON.parse(env.HG_SESSION) : null;
    if (!s || !s.device_id || !s.iid || !s.jar) return null;
    const jar = s.jar;
    const parts = [];
    for (const n of ["sessionid", "sessionid_ss", "sid_tt", "sid_guard", "uid_tt", "uid_tt_ss", "odin_tt", "d_ticket"]) if (jar[n]) parts.push(n + "=" + jar[n]);
    if (!parts.length) return null;
    parts.push("store-region=cn", "store-region-src=did");
    return {
      device_id: String(s.device_id), iid: String(s.iid), cdid: String(s.cdid || ""), ck: {},
      _acct: true, _cookieFull: parts.join("; "),
      _pfFixed: { device_type: "PGT-AN10", device_brand: "HONOR", os_api: 32, os_version: "12", resolution: "1080*1920", dpi: 480, dragon_device_type: "phone" },
      _uaFixed: "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
    };
  } catch (e) { return null; }
}
// 账号/服务健康: KV 键 hg_acct_health = {ok, acctOk, at,
// used}; v2.11.0 起 ok = 任一路出集 (服务可用性), acctOk =
// 账号备用路存活 (null = 未配置会话)。巡检据 ok=false 报警
// (双路全灭), acctOk=false 仅作备用路失效提示。
// 重登。ok=true 为最近成功窗的时间与账号出集数。
async function _acctHealthRecord(env, acctStat) {
  if (!env || !env.HG_KV || !acctStat) return;
  // v2.11.0 语义: ok = 本窗任一路出集 (服务可用性); acctOk =
  // 账号备用路存活 (未配置会话为 null, 主路失效不算服务故障)。
  const now = Date.now();
  const served = (acctStat.used || 0) + (acctStat.anonUsed || 0);
  const rec = { ok: served > 0, acctOk: acctStat.had ? !acctStat.dead : null, at: now, used: served };
  let prev = null;
  try { const t = await env.HG_KV.get("hg_acct_health"); if (t) prev = JSON.parse(t); } catch (e) {}
  if (!rec.ok) {
    // 故障必记; 同形态故障 1h 内刚记过则跳过, 防抖动刷写
    if (prev && prev.ok === false && prev.acctOk === rec.acctOk && now - (prev.at || 0) < 3600000) return;
    await env.HG_KV.put("hg_acct_health", JSON.stringify(rec));
    return;
  }
  // 成功: 仅翻转 (ok 或 acctOk 变化)、无记录、或 >6h 心跳才写
  if (prev && prev.ok === true && prev.acctOk === rec.acctOk && now - (prev.at || 0) < 6 * 3600000) return;
  await env.HG_KV.put("hg_acct_health", JSON.stringify(rec));
}
async function _acctHealthRead(env) {
  if (!env || !env.HG_KV) return null;
  try { const t = await env.HG_KV.get("hg_acct_health"); return t ? JSON.parse(t) : null; } catch (e) { return null; }
}
// 会话到期 (epoch 秒): sid_guard 明文段 = sid|签发|TTL秒|到期日
// 期串; 解析失败回 null (仅供 /health 展示, 不参与逻辑)。
function _acctExpiryTs(env) {
  try {
    const s = env && env.HG_SESSION ? JSON.parse(env.HG_SESSION) : null;
    const sg = s && s.jar && s.jar.sid_guard ? decodeURIComponent(String(s.jar.sid_guard)) : "";
    const p = sg.split("|");
    const issued = Number(p[1]), ttl = Number(p[2]);
    if (issued > 1000000000 && ttl > 0) return issued + ttl;
    return null;
  } catch (e) { return null; }
}
function _invBudget(env) {
  let b = env ? _invBudgets.get(env) : null;
  if (!b) { b = { fetches: 0 }; if (env) _invBudgets.set(env, b); }
  return b;
}
async function _fetchAndFilter(env, missVids, prewarm) {
  const ctx = _workerCtx();
  ctx.env = env;
  ctx.budget = _invBudget(env);
  const r = await HG_CORE._fetchWindowSingle(ctx, missVids, _acctFromEnv(env)); // v2.11.0: JSTV 形态单集窗 (匿名主路 + 账号备用)
  let out;
  if (r && r.kind === "ok") {
    // 逐集健全性过滤: 达标 → 进 models + 入缓存; 不达标 →
    // 进 bad (不进 models、不入缓存); 上游未回的集保持缺席
    // (模块侧记 no-model, 不与 bad 混淆)。
    const models = {}, bad = [];
    for (const v of missVids) {
      const m = (r.models || {})[v];
      if (m === undefined || m === null) continue;
      if (_modelSane(m)) { models[v] = m; }
      else { bad.push(v); ctx.log("hg relay model 不达标 vid=" + v + " (回 bad, 不入缓存)"); }
    }
    if (Object.keys(models).length) await _winCachePut(missVids[0], models); // v2.5.3: 整窗一条入本节点缓存
    await _kvBatchPut(env, missVids[0], models); // v2.5.0: 整窗镜像进 KV (跨节点可读, 一窗一写)
    out = { kind: "ok", models: models, bad: bad, regs: r.regs || 0 };
  } else {
    out = { kind: (r && r.kind) || "fail", models: {}, bad: [], regs: (r && r.regs) || 0 };
  }
  // v2.10.0 账号健康记账: 每个实拉窗把账号相位结局记进 KV
  // hg_acct_health (失败必记、成功仅状态翻转或 6h 心跳才写,
  // 写量可忽略; 全程 try/catch, 记账故障绝不影响取流)。
  try { await _acctHealthRecord(env, r && r.acct); } catch (e) {}
  // 注册失败退避记账: 只挂注册失败 (kind=fail 且 regs=0);
  // regs>=1 的结果一律清账 (注册健康证明)。v2.5.1: 预热路
  // 不记退避——后台失败不许毒化前台 (前台失败照旧记账);
  // 但两路失败都另写 hg_last_fail 定因快照 (核心 stage 尾
  // + 最近日志行, 一失败一写、失败稀有, 写量可忽略)。
  if (out.kind === "fail" && out.regs === 0) {
    if (!prewarm) await _backoffRecord(env);
    if (env && env.HG_KV) {
      try {
        const stage = await ctx.storeGet("hg_stage");
        await env.HG_KV.put("hg_last_fail", JSON.stringify({ at: Date.now(), prewarm: !!prewarm, stage: String(stage || "").slice(-300), logs: _lastLogs.slice(-5) }));
      } catch (e) {}
    }
  }
  else if (out.regs >= 1) await _backoffPut(env, null);
  return out;
}

// /device (v2.6.0): 强注册身份下发。身份在 KV 缓存 6 小时
// (hg_strong_idn), 命中直接回、不重复注册 (jackotom 口径:
// 一枚身份长期复用, 被拒才换)。铸造失败回 502 regfail。
// 身份字段原值只经本响应回给持 KEY 的客户端, 不入日志。
async function _relayDevice(env) {
  const KV_KEY = "hg_strong_idn";
  try {
    if (env && env.HG_KV) {
      const raw = await env.HG_KV.get(KV_KEY);
      if (raw) {
        const o = JSON.parse(raw);
        if (o && o.d && o.i && o.c && (Date.now() - (o.t || 0)) < 6 * 3600 * 1000) {
          return { status: 200, body: { ok: true, device_id: String(o.d), iid: String(o.i), cdid: String(o.c), klink: String(o.k || ""), cached: true } };
        }
      }
    }
  } catch (e) {}
  const ctx = _workerCtx();
  let idn = null;
  try { idn = await HG_CORE._registerDeviceStrong(ctx); }
  catch (e) { ctx.log("hg strong 注册失败: " + (e && e.message)); }
  if (!idn) return { status: 502, body: { ok: false, kind: "regfail" } };
  try {
    if (env && env.HG_KV) await env.HG_KV.put(KV_KEY, JSON.stringify({ d: idn.device_id, i: idn.iid, c: idn.cdid, k: idn.klink || "", t: Date.now() }));
  } catch (e) {}
  return { status: 200, body: { ok: true, device_id: idn.device_id, iid: idn.iid, cdid: idn.cdid, klink: idn.klink || "", cached: false } };
}

// ---- v3.0.0 逐集 model 缓存 (Cache API, per-PoP) ----
// 旧窗缓存以「窗首 vid」为键: 点播窗口与缓存窗口错位即整窗
// 未命中 (实测单集冷调 3.4s 的主因之一)。逐集键与窗口对齐
// 无关, 命中即 ~百毫秒。TTL 1800s (与旧窗缓存同口径, model
// 地址效期约 6h 内重铸成本低)。入缓存前都过 _modelSane。
const _VID_CACHE_PREFIX = "https://hgc.internal/m/";
async function _vidCacheGet(vid, bag) {
  // v3.0.1 (监工 F2): 带 bag 时先预扣 1 次子请求 (cap HG_OP_BUDGET), 扣不动回未命中
  if (bag) { if (bag.fetches + 1 > HG_OP_BUDGET) return null; bag.fetches += 1; }
  try {
    const hit = await caches.default.match(_VID_CACHE_PREFIX + vid);
    if (!hit) return null;
    const o = await hit.json();
    if (o && o.m && _modelSane(o.m)) return o.m;
  } catch (e) {}
  return null;
}
async function _vidCachePut(vid, model, bag) {
  if (bag) { if (bag.fetches + 1 > HG_OP_BUDGET) return; bag.fetches += 1; }
  try {
    await caches.default.put(_VID_CACHE_PREFIX + vid, new Response(JSON.stringify({ m: model, at: Date.now() }), {
      headers: { "content-type": "application/json", "cache-control": "public, max-age=1800" }
    }));
  } catch (e) {}
}

// /tap 后台补窗: 逐集 (查逐集缓存 -> 快铸 -> 健全 -> 入缓存),
// 与 tap 主路共享同一只 invocation 预算袋, 预算尽即止; 每集
// 间隔 80ms 保持礼貌节奏。全程吞错, 补不满的集点播时自铸。
async function _bgFill(env, vids, bag) {
  // v3.0.1 (监工 F2): 预算袋由 _tapServe 显式传入 (同一对象),
  // 不再按 env 重查——跨 invocation 时 env 袋会被新 invocation
  // 重置, 重查会串袋使 46 顶失效。逐集先按「查+铸+存≈3」预检。
  const ctx = _workerCtx();
  ctx.env = env;
  ctx.budget = bag || _invBudget(env);
  ctx.budgetCap = HG_OP_BUDGET;
  const acct = _acctFromEnv(env);
  for (const vid of vids) {
    try {
      if (ctx.budget.fetches + 3 > HG_OP_BUDGET) break;
      if (await _vidCacheGet(vid, ctx.budget)) continue;
      const r = await HG_CORE._mintOneFast(ctx, vid, acct);
      if (r && r.model && _modelSane(r.model)) await _vidCachePut(vid, r.model, ctx.budget);
      await _sleepMs(80);
    } catch (e) {}
  }
}

// /tap 健康记账 (v3.0.1, 监工 F3): 两连击制。窗路要 ok=false
// 需整窗全灭; tap 是单集粒度, 一次失败 (不存在/下架的集与通
// 路死亡在上游回包上同形) 直接落账会把 /health 打成假的全
// 灭。故: 出集 (含 bad=铸回不达健全、通路是活的) 按出集记账
// 并清 pending; 失败先记 pending (KV hg_tap_failpend), 10 分
// 钟内第二次失败 (期间无出集) 才落失败账。KV 操作经 ctx 袋
// 预扣 (健康记账约 2 次 + pending 读写约 2 次), 扣不动跳过。
const _TAP_PEND_KEY = "hg_tap_failpend";
async function _tapHealth(env, ctx, acct, r, served) {
  const charge = (n) => {
    if (!ctx || !ctx.budget) return true;
    if (ctx.budget.fetches + n > HG_OP_BUDGET) return false;
    ctx.budget.fetches += n;
    return true;
  };
  const kv = (env && env.HG_KV) || null;
  if (served) {
    if (charge(2)) {
      try {
        await _acctHealthRecord(env, {
          had: !!acct,
          used: r && r.lane === "acct" ? 1 : 0,
          dead: false,
          anonUsed: r && r.lane === "anon" ? 1 : 0,
          anonDead: false
        });
      } catch (e) {}
    }
    if (kv && charge(1)) {
      try { const p = await kv.get(_TAP_PEND_KEY); if (p && charge(1)) await kv.delete(_TAP_PEND_KEY); } catch (e) {}
    }
    return;
  }
  // 失败路
  if (!kv) {
    if (charge(2)) {
      try {
        await _acctHealthRecord(env, {
          had: !!acct, used: 0,
          dead: !!(acct && r && r.acctOk === false),
          anonUsed: 0, anonDead: !!(r && r.anonDead)
        });
      } catch (e) {}
    }
    return;
  }
  try {
    if (!charge(1)) return;
    const p = parseInt((await kv.get(_TAP_PEND_KEY)) || "0", 10) || 0;
    if (p && Date.now() - p < 600000) {
      if (charge(2)) {
        try {
          await _acctHealthRecord(env, {
            had: !!acct, used: 0,
            dead: !!(acct && r && r.acctOk === false),
            anonUsed: 0, anonDead: !!(r && r.anonDead)
          });
        } catch (e) {}
      }
      if (charge(1)) await kv.delete(_TAP_PEND_KEY);
    } else if (charge(1)) {
      await kv.put(_TAP_PEND_KEY, String(Date.now()));
    }
  } catch (e) {}
}

// /tap (v3.0.0): 单集快路。回 {ok, model, kind, bad, ms, bg};
// 后台补窗名单经 bgList 交 handler 走 waitUntil。
async function _tapServe(env, body) {
  const t0 = Date.now();
  const clean = (a) => {
    const out = [], seen = {};
    if (Array.isArray(a)) for (const x of a) {
      const s = String(x);
      if (/^\d+$/.test(s) && !seen[s]) { seen[s] = true; out.push(s); }
    }
    return out.slice(0, 15);
  };
  const vid = String((body && body.vid) || "");
  const win = clean(body && body.window), next = clean(body && body.next), next2 = clean(body && body.next2);
  const ctx = _workerCtx();
  ctx.env = env;
  ctx.budget = _invBudget(env);
  ctx.budgetCap = HG_OP_BUDGET; // v3.0.1: tap 路全操作同袋记账 (监工 F2)
  let model = await _vidCacheGet(vid, ctx.budget);
  const cacheMs = Date.now() - t0;
  let mintMs = 0, kind = "ok", bad = false;
  if (!model) {
    const tm = Date.now();
    const acct = _acctFromEnv(env);
    const r = await HG_CORE._mintOneFast(ctx, vid, acct);
    mintMs = Date.now() - tm;
    if (r && r.model && _modelSane(r.model)) {
      model = r.model;
      await _vidCachePut(vid, model, ctx.budget);
    } else if (r && r.model) { bad = true; kind = "bad"; }
    else kind = (r && r.kind) || "fail";
    // 健康记账走两连击制 (v3.0.1, 监工 F3): served = 出集或
    // 铸回不达健全 (通路活); 其余失败先 pending、再犯才落账。
    try { await _tapHealth(env, ctx, acct, r, !!(model || bad)); } catch (e) {}
  }
  // 补窗名单跨窗去重 (监工 F4): 同 vid 只补一次
  const bgSeen = {};
  const bgList = [];
  for (const v of win.concat(next, next2)) {
    if (v !== vid && !bgSeen[v]) { bgSeen[v] = true; bgList.push(v); }
  }
  return {
    status: 200,
    body: { ok: !!model, model: model, kind: model ? "ok" : kind, bad: bad, ms: { cache: cacheMs, mint: mintMs, total: Date.now() - t0 }, bg: bgList.length },
    bgList: bgList,
    bag: ctx.budget // v3.0.1: 显式交 handler 传给 _bgFill (防串袋)
  };
}

async function _relayPlay(env, vids, prewarm) {
  // 重复 vid 去重 (保序): 重复项会让同一集被重复取、bad 重
  // 复 push, 污染模块侧逐集记账的 miss 计数 (边界监工注记)。
  vids = Array.from(new Set(vids));
  // v2.1.0: 先查缓存——命中的 vid 直接装 models 不消耗注册;
  // 全窗命中直接回 (regs=0), 连节流闸都不过。
  const models = {}, bad = [];
  let missVids = [];
  const batch0 = await _winCacheGet(vids[0]); // v2.5.3: 整窗一条探
  for (const v of vids) {
    const m = batch0 && batch0[v];
    if (m) models[v] = m; else missVids.push(v);
  }
  // v2.5.0: 本节点未命中的集再查 KV 全局镜像 (预热可能暖
  // 在别的节点); src 计数 (c=本节点缓存/k=KV 镜像/f=现注
  // 册) 随回包下发供跨节点命中核账, 模块侧不读。
  let cacheHits = vids.length - missVids.length, kvHits = 0;
  if (missVids.length) {
    kvHits = await _fillFromKv(env, vids, missVids, models);
    if (kvHits) missVids = missVids.filter((v) => !models[v]);
  }
  if (!missVids.length) {
    return { status: 200, body: { ok: true, models: models, bad: bad, regs: 0, src: { c: cacheHits, k: kvHits, f: 0 } } };
  }
  // 注册失败退避冷却 (v2.2.0 追加): 上次注册失败的冷却窗内
  // 不试探注册、不占闸, 直接回 kind=fail; 全窗缓存命中的调
  // 用已在上方直出, 部分命中集陪回 fail 是冷却语义优先的取
  // 舍 (冷却最长 300s, 期满自动恢复)。
  const bo = await _backoffGet(env);
  if (bo && bo.retryAt && Date.now() < bo.retryAt) {
    return { status: 200, body: { ok: false, kind: "fail", regs: 0 } };
  }
  // 注册节流闸 (v2.2.0): 只节流真注册 (有未命中集才需要注
  // 册)。闸关着不再立即 429——在 Worker 内等闸: 每 POLL_MS
  // 复查一轮 (先重查缓存: 并发调用已取回的集直接出局、不必
  // 等闸; 再看闸戳: 距上次放行 ≥GATE_MS 即占闸注册), 等满
  // WAIT_MS 闸仍不开才回 429 (形态与 v2.0.0 一致)。占闸后
  // 经 _playFlights 同窗共享, 撞闸并发不重复注册。
  const gateMs = _gateParam(env, "HG_GATE_MS", GATE_MS);
  const waitMs = _gateParam(env, "HG_WAIT_MS", WAIT_MS);
  const pollMs = _gateParam(env, "HG_POLL_MS", POLL_MS);
  const deadline = Date.now() + waitMs;
  for (;;) {
    const last = await _regAtGet(env);
    if (Date.now() - last >= gateMs) { await _regAtPut(env); break; }
    if (Date.now() >= deadline) {
      // 等待超时: 已有缓存命中集时部分下发 (协议监工 FAIL 修
      // 法: 所点集明明在缓存却陪未命中集吃整窗 429 是可用性
      // 浪费); 一集未命中才维持 429 硬回。
      if (Object.keys(models).length) {
        return { status: 200, body: { ok: true, models: models, bad: bad, regs: 0, part: true, src: { c: cacheHits, k: kvHits, f: 0 } } };
      }
      return { status: 429, body: { ok: false, kind: "ratelimit", regs: 0 } };
    }
    await _sleepMs(Math.min(pollMs, Math.max(0, deadline - Date.now())));
    const batch1 = await _winCacheGet(vids[0]);
    const still = [];
    for (const v of missVids) {
      const m = batch1 && batch1[v];
      if (m) { models[v] = m; cacheHits++; } else still.push(v);
    }
    missVids = still;
    if (missVids.length) {
      const kf = await _fillFromKv(env, vids, missVids, models);
      if (kf) { kvHits += kf; missVids = missVids.filter((v) => !models[v]); }
    }
    if (!missVids.length) {
      return { status: 200, body: { ok: true, models: models, bad: bad, regs: 0, src: { c: cacheHits, k: kvHits, f: 0 } } };
    }
  }
  const fkey = missVids.join(",");
  let fr;
  if (_playFlights[fkey]) {
    fr = await _playFlights[fkey];
  } else {
    const flight = _fetchAndFilter(env, missVids, prewarm);
    _playFlights[fkey] = flight;
    try { fr = await flight; }
    finally { if (_playFlights[fkey] === flight) delete _playFlights[fkey]; }
  }
  if (fr.kind === "ok") {
    let freshN = 0;
    for (const v of missVids) { if (fr.models[v]) { models[v] = fr.models[v]; freshN++; } }
    for (const v of fr.bad) bad.push(v);
    return { status: 200, body: { ok: true, models: models, bad: bad, regs: fr.regs, src: { c: cacheHits, k: kvHits, f: freshN } } };
  }
  // 取流失败/空: 已缓存命中集部分下发 (ok:true+part, 模块逐
  // 集钉存命中集、缺集记 no-model 待后重试); 一集未命中才
  // 整窗回 kind (v2.0.0 语义)。
  if (Object.keys(models).length) {
    return { status: 200, body: { ok: true, models: models, bad: bad, regs: fr.regs, part: true, src: { c: cacheHits, k: kvHits, f: 0 } } };
  }
  return { status: 200, body: { ok: false, kind: fr.kind, regs: fr.regs } };
}

// ---- 下一窗预热 (v2.3.0; v2.4.0 链式两窗; v2.5.0 让行+
// KV 镜像): 主窗响应成形后经 ctx.waitUntil 在后台执行——
// 把 next/next2 窗的 model 提前取好, 顺序观看跨窗时模块
// 的 /play 直接命中 (regs=0), 免去跨窗处的注册+排队+一
// 发等待。取数仍走 _relayPlay 主路 (退避/闸/在飞合并/健
// 全检查同源), 取回的 model 同时落本节点 Cache API 与
// KV 全局镜像, 用户请求落任何节点都能命中。
// v2.5.0 让行前台 (v2.4.0 教训: 两窗链注册与用户点播抢
// 同一道闸, 冷进场反而更卡, 真机实锤): 预热动手前先查
// 本窗是否已备好 (KV 批次或本节点缓存全覆盖 → 零动作);
// 未备好则等闸空闲——闸戳距今 ≥HG_PW_IDLE_MS (缺省 8s)
// 才许注册, 轮询上限 HG_PW_WAIT_MS (缺省 24s), 等不到
// 就放弃本窗且断链 (前台正忙, 用户自己会取)。链每步结
// 果回写 KV hg_pw_last (一链一写), 供跨节点回读核账。
// 失败全静默, 绝不影响已成形的主窗响应。
function _prewarmLog(obj) {
  try { console.log(JSON.stringify(obj)); } catch (e) {}
}
const PW_IDLE_MS = 8000, PW_POLL_MS = 2000, PW_WAIT_MS = 24000;
async function _windowReady(env, vids) {
  const batch = await _kvBatchGet(env, vids[0]);
  if (batch && vids.every((v) => batch[v])) return true;
  const wc = await _winCacheGet(vids[0]); // v2.5.3: 整窗一条探本节点
  return !!(wc && vids.every((v) => wc[v]));
}
// v2.7.0: 轮询版就绪探针只查 KV 批次 (KV 不占 fetch+Cache 的
// 50 配额); Cache match 计入配额, 闸轮询里逐轮探会漏掉十几
// 个 op (单集路预算紧, 实测 +17)——Cache 只在入闸前探一次。
async function _windowReadyKv(env, vids) {
  const batch = await _kvBatchGet(env, vids[0]);
  return !!(batch && vids.every((v) => batch[v]));
}
async function _prewarmOne(env, vids) {
  // 回 {regs, got, skipped} 或 null (让行放弃); 异常自吞
  try {
    if (await _windowReady(env, vids)) return { regs: 0, got: vids.length, skipped: 1 };
    const idleMs = _gateParam(env, "HG_PW_IDLE_MS", PW_IDLE_MS);
    const pollMs = _gateParam(env, "HG_PW_POLL_MS", PW_POLL_MS);
    const waitMs = _gateParam(env, "HG_PW_WAIT_MS", PW_WAIT_MS);
    const deadline = Date.now() + waitMs;
    for (;;) {
      const last = await _regAtGet(env);
      if (Date.now() - last >= idleMs) break;
      if (Date.now() >= deadline) return null;
      await _sleepMs(Math.min(pollMs, Math.max(0, deadline - Date.now())));
      if (await _windowReadyKv(env, vids)) return { regs: 0, got: vids.length, skipped: 1 };
    }
    const r = await _relayPlay(env, vids, true);
    const body = (r && r.body) || {};
    const out = { regs: body.regs || 0, got: Object.keys(body.models || {}).length, skipped: 0 };
    if (!body.ok) out.kind = body.kind || "fail";
    return out;
  } catch (e) {
    const why = String((e && e.message) || e).replace(/https?:\/\/\S+/g, "<url>").slice(0, 120);
    return { regs: 0, got: 0, skipped: 0, err: 1, why: why };
  }
}
async function _pwReceipt(env, steps) {
  if (env && env.HG_KV && steps.length) {
    try { await env.HG_KV.put("hg_pw_last", JSON.stringify({ at: Date.now(), steps: steps })); } catch (e) {}
  }
}
// v2.5.2: 一步结果并入 steps 数组; 回是否继续 (让行放弃
// =null 才断链, 与旧 _prewarmChain 的 break 语义一致)。
function _pwStep(steps, w, s) {
  if (s === null) { steps.push({ first: w[0], aborted: 1 }); return false; }
  const step = { first: w[0], regs: s.regs, got: s.got, skipped: s.skipped || 0 };
  if (s.kind) step.kind = s.kind;
  if (s.err) step.err = 1;
  if (s.why) step.why = s.why;
  steps.push(step);
  _prewarmLog({ event: "hg_prewarm", first: w[0], regs: s.regs, got: s.got, skipped: s.skipped || 0, kind: s.kind || "", err: s.err || 0 });
  return true;
}
// v2.5.3: 链恢复同 invocation 直跑 (整窗批次缓存把配额压
// 回安全区, 见文件头 v2.5.3 注); 步进与回执口径沿 v2.5.1:
// 失败步立即落回执, 链尾再落一次完整的。
async function _prewarmChain(env, next, next2) {
  const steps = [];
  for (const w of [next, next2]) {
    if (!w || !w.length) continue;
    const s = await _prewarmOne(env, w);
    const cont = _pwStep(steps, w, s);
    if (!cont) break;
    if (steps[steps.length - 1].got === 0 && !steps[steps.length - 1].skipped) await _pwReceipt(env, steps);
  }
  await _pwReceipt(env, steps);
}
// 后台调度: waitUntil 优先; 同步抛错/无 waitUntil 时降级为
// 不等候的后台承诺 (绝不许穿出 handler 吞掉已成形的响应)。
function _schedulePw(ctx, p) {
  try {
    if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(p);
    else p.catch(() => {});
  } catch (e) { p.catch(() => {}); }
}

// ============================================================
// v2.9.0: 红果 web 兜底清单托管 (模块 app 主路失败时的备引擎;
// 源 = carsonn hongguo v1.2.1 的 web 路, 2026-11-11 全链复现:
// play-info → kid+player_access_key → keyvm 本地派生内容钥 →
// 720p CENC 真解出帧)。模块本机调 play-info 并派生钥后, 把
// play_info 与钥 POST /<KEY>/web/put; 本节拉两轨文件头解析
// sidx、渲染双轨 HLS 清单存 KV (web:<token>, TTL 6h), 回
// master 地址; GET /<KEY>/web/{m,v,a}/<token>.m3u8 出清单。
// 签名地址约 1.5h 过期: v/a 出清单前发现 exp 临期 (<now+120s)
// 即重拉 play-info 刷新地址与清单 (kid 与内容钥已实测跨次
// 稳定; kid 变 → 502 不硬刷, 等模块下次点播重新铸造)。
// 分片行 = 签名址 + "&.mp4" (实测签名址可追加查询参), 播放
// 器直连源站, 清单之外零中转流量; 钥以 SAMPLE-AES data URI
// 内嵌 (base64 去尾 = 再补 =.mp4, 过宿主扩展名门)。
// sidx 布局 (2026-11-11 活体钉死, 非标准): payload 内
// timescale@8、reference_ID@4、reference_count@22、refs@24
// ——标准 reserved 区被撑长 4B; 校验 = 分片字节总和 +
// dataStart 与文件 size 之差落在 [0, 65536] (实测 slack
// 356B), 不合即判解析失败。早期探针曾误读 timescale@4
// (=reference_ID), EXTINF 时长全错位、仅因 ffmpeg 解码不
// 看 EXTINF 才假绿——本节按钉死布局实现, 勿改回。
// ============================================================
const _WEB_TTL_S = 21600;
function _webRange(s) {
  const m = /^(\d+)-(\d+)$/.exec(String(s || ""));
  if (!m) return null;
  const a = Number(m[1]), b = Number(m[2]);
  if (!(b >= a) || b - a > 1048576) return null;
  return [a, b];
}
function _webParseSidx(buf, sidxOff, fileSize, dataStart) {
  const dv = new DataView(buf);
  if (sidxOff < 0 || sidxOff + 8 > buf.byteLength) return null;
  const boxSize = dv.getUint32(sidxOff);
  if (boxSize < 32 || sidxOff + boxSize > buf.byteLength) return null;
  if (String.fromCharCode(dv.getUint8(sidxOff + 4), dv.getUint8(sidxOff + 5), dv.getUint8(sidxOff + 6), dv.getUint8(sidxOff + 7)) !== "sidx") return null;
  const p = sidxOff + 8; // payload 起点
  const timescale = dv.getUint32(p + 8);
  const count = dv.getUint16(p + 22);
  if (!timescale || count < 1 || count > 8192) return null;
  if (p + 24 + count * 12 > sidxOff + boxSize) return null;
  const frags = [];
  let total = 0, durTotal = 0;
  for (let i = 0; i < count; i++) {
    const o = p + 24 + i * 12;
    const sz = dv.getUint32(o) & 0x7fffffff;
    const du = dv.getUint32(o + 4);
    if (!sz) return null;
    frags.push({ size: sz, dur: du / timescale });
    total += sz; durTotal += du / timescale;
  }
  const slack = fileSize - (dataStart + total);
  if (slack < 0 || slack > 65536) return null;
  if (!(durTotal > 0) || durTotal > 86400) return null;
  return frags;
}
function _webKeyUri(keyHex) {
  let bin = "";
  for (let i = 0; i < 16; i++) bin += String.fromCharCode(parseInt(keyHex.substr(i * 2, 2), 16));
  return "data:application/octet-stream;base64," + btoa(bin).replace(/=+$/, "") + "=.mp4";
}
function _webRenderMedia(url, init, dataStart, frags, keyHex) {
  let maxDur = 0;
  for (const f of frags) if (f.dur > maxDur) maxDur = f.dur;
  const lines = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-TARGETDURATION:" + Math.max(1, Math.ceil(maxDur)), "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"];
  lines.push('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="' + _webKeyUri(keyHex) + '"');
  lines.push('#EXT-X-MAP:URI="' + url + '&.mp4",BYTERANGE="' + (init[1] - init[0] + 1) + "@" + init[0] + '"');
  let off = dataStart;
  for (const f of frags) {
    lines.push("#EXTINF:" + f.dur.toFixed(3) + ",");
    lines.push("#EXT-X-BYTERANGE:" + f.size + "@" + off);
    lines.push(url + "&.mp4");
    off += f.size;
  }
  lines.push("#EXT-X-ENDLIST");
  return lines.join("\n") + "\n";
}
async function _webBuildTexts(vInfo, aInfo, keyHex, keyHexA) {
  const build = async (info, key) => {
    const init = _webRange(info.init_range), idx = _webRange(info.index_range);
    if (!init || !idx) return null;
    const r = await fetch(info.main_url, { headers: { Range: "bytes=0-" + idx[1], Referer: "https://hongguoduanju.com/" } });
    if (r.status !== 206) return null;
    const buf = await r.arrayBuffer();
    if (buf.byteLength < idx[1] + 1) return null;
    const frags = _webParseSidx(buf, idx[0], Number(info.size) || 0, idx[1] + 1);
    if (!frags) return null;
    return _webRenderMedia(info.main_url, init, idx[1] + 1, frags, key);
  };
  const vtext = await build(vInfo, keyHex);
  if (!vtext) return null;
  const atext = await build(aInfo, keyHexA);
  if (!atext) return null;
  return { vtext: vtext, atext: atext, exp: Math.min(Number(vInfo.expires_at) || 0, Number(aInfo.expires_at) || 0) };
}
async function _webKvGet(env, token) {
  if (env && env.HG_KV) { try { return await env.HG_KV.get("web:" + token); } catch (e) {} }
  return null;
}
async function _webKvPut(env, token, rec) {
  if (env && env.HG_KV) {
    try { await env.HG_KV.put("web:" + token, JSON.stringify(rec), { expirationTtl: _WEB_TTL_S }); return true; } catch (e) {}
  }
  return false;
}
async function _webPut(request, env, key) {
  let j = null;
  try { j = await request.json(); } catch (e) {}
  if (!j) return _json({ ok: false, kind: "badrequest" }, 400);
  const sid = String(j.sid || ""), vid = String(j.vid || ""), def = String(j.def || "");
  const kid = String(j.kid || ""), keyHex = String(j.keyHex || "").toLowerCase(), keyHexA = String(j.keyHexA || j.keyHex || "").toLowerCase();
  if (!/^\d+$/.test(sid) || !/^\d+$/.test(vid) || ["720p", "480p", "360p"].indexOf(def) < 0) return _json({ ok: false, kind: "badrequest" }, 400);
  if (!/^[0-9a-f]{32}$/.test(kid) || !/^[0-9a-f]{32}$/.test(keyHex) || !/^[0-9a-f]{32}$/.test(keyHexA)) return _json({ ok: false, kind: "badkey" }, 400);
  const okInfo = (x) => x && typeof x.main_url === "string" && x.main_url.startsWith("https://") && _webRange(x.init_range) && _webRange(x.index_range) && Number(x.size) > 0;
  if (!okInfo(j.v) || !okInfo(j.a)) return _json({ ok: false, kind: "badinfo" }, 400);
  const built = await _webBuildTexts(j.v, j.a, keyHex, keyHexA);
  if (!built) return _json({ ok: false, kind: "build" }, 502);
  const rb = new Uint8Array(9);
  crypto.getRandomValues(rb);
  const token = Array.from(rb, (b) => b.toString(16).padStart(2, "0")).join("");
  const rec = { sid: sid, vid: vid, def: def, kid: kid, keyHex: keyHex, keyHexA: keyHexA, w: Number(j.w) || 0, h: Number(j.h) || 0, bw: (Number(j.v.bitrate) || 0) + (Number(j.a.bitrate) || 0), vtext: built.vtext, atext: built.atext, exp: built.exp };
  if (!(await _webKvPut(env, token, rec))) return _json({ ok: false, kind: "nokv" }, 501);
  return _json({ ok: true, master: new URL(request.url).origin + "/" + key + "/web/m/" + token + ".m3u8" });
}
async function _webGet(env, key, kind, token) {
  const raw = await _webKvGet(env, token);
  if (!raw) return new Response("not found", { status: 404 });
  let rec = null;
  try { rec = JSON.parse(raw); } catch (e) {}
  if (!rec) return new Response("not found", { status: 404 });
  const H = { "Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store" };
  if (kind === "m") {
    const bw = rec.bw > 0 ? rec.bw : 2000000;
    const res = rec.w && rec.h ? ",RESOLUTION=" + rec.w + "x" + rec.h : "";
    return new Response("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"/" + key + "/web/a/" + token + ".m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=" + bw + res + ",AUDIO=\"aud\"\n/" + key + "/web/v/" + token + ".m3u8\n", { headers: H });
  }
  // v/a 出清单前临期刷新: 签名地址过期后分片全死, 先重拉
  // play-info 换新址重渲染 (kid 变 = 内容钥已轮换, 本节无钥
  // 可派, 回 502 等模块重新铸造)。
  if (rec.exp && rec.exp < Math.floor(Date.now() / 1000) + 120) {
    try {
      const r = await fetch("https://hongguoduanju.com/api/video/protected/play-info", { method: "POST", headers: { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36", Referer: "https://hongguoduanju.com/", "Content-Type": "application/json" }, body: JSON.stringify({ series_id: rec.sid, item_id: rec.vid, definition: rec.def }) });
      const j = r.ok ? await r.json() : null;
      const pi = j && j.play_info;
      if (pi && pi.kid !== rec.kid) return new Response("key rotated", { status: 502 });
      if (pi && pi.audio && pi.audio.kid === rec.kid) {
        const built = await _webBuildTexts(pi, pi.audio, rec.keyHex, rec.keyHexA);
        if (built) {
          rec.vtext = built.vtext; rec.atext = built.atext; rec.exp = built.exp;
          await _webKvPut(env, token, rec);
        }
      }
    } catch (e) {}
  }
  return new Response(kind === "v" ? rec.vtext : rec.atext, { headers: H });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      // v2.10.0: 附账号健康 (最近实拉窗的账号相位结局) 与会话
      // 到期 epoch; 读不到一律 null, 不影响 ok/v 旧字段。
      const acct = await _acctHealthRead(env);
      return _json({ ok: true, v: RELAY_VERSION, acct: acct, acctExp: _acctExpiryTs(env) });
    }
    // KEY: CF 走 env secret 绑定; Deno 备胎走 Deno.env (部署时
    // 以 secret env var 注入同名变量)。
    const key = (env && env.RELAY_KEY) ||
      ((typeof Deno !== "undefined" && Deno.env) ? (Deno.env.get("RELAY_KEY") || "") : "");
    if (request.method === "POST" && key && url.pathname === "/" + key + "/device") {
      const out = await _relayDevice(env);
      return _json(out.body, out.status);
    }
    if (request.method === "POST" && key && url.pathname === "/" + key + "/tap") {
      let tbody = null;
      try { tbody = await request.json(); } catch (e) {}
      if (!tbody || !/^\d+$/.test(String(tbody.vid || ""))) {
        return _json({ ok: false, kind: "badrequest" }, 400);
      }
      _invBudgets.set(env, { fetches: 0 }); // 每 /tap invocation 一只新预算袋 (后台补窗同袋共享)
      const tout = await _tapServe(env, tbody);
      const tresp = _json(tout.body, tout.status);
      if (tout.bgList && tout.bgList.length) {
        _schedulePw(ctx, _bgFill(env, tout.bgList, tout.bag));
      }
      return tresp;
    }
    if (request.method === "POST" && key && url.pathname === "/" + key + "/play") {
      let vids = null, next = [], next2 = [];
      try {
        const j = await request.json();
        if (j && Array.isArray(j.vids)) vids = j.vids.map(String);
        // next (v2.3.0 可选): 下一窗 vids, 清洗口径同 vids
        // (纯数字、保序去重、≤15); 非数组/非法/缺失一律当
        // 无——主窗契约零影响, 绝不因 next 坏了整窗请求。
        if (j && Array.isArray(j.next)) {
          const seenN = {};
          for (const x of j.next) {
            const s = String(x);
            if (/^\d+$/.test(s) && !seenN[s]) { seenN[s] = true; next.push(s); }
          }
          next = next.slice(0, 15);
        }
        // next2 (v2.4.0 可选): 下下窗 vids, 清洗口径同 next
        if (j && Array.isArray(j.next2)) {
          const seenN2 = {};
          for (const x of j.next2) {
            const s2 = String(x);
            if (/^\d+$/.test(s2) && !seenN2[s2]) { seenN2[s2] = true; next2.push(s2); }
          }
          next2 = next2.slice(0, 15);
        }
      } catch (e) {}
      if (!vids || !vids.length || vids.length > 15 || !vids.every(v => /^\d+$/.test(v))) {
        return _json({ ok: false, kind: "badrequest" }, 400);
      }
      _invBudgets.set(env, { fetches: 0 }); // v2.7.0: 每 /play invocation 一只新预算袋 (预热链同 env 共享)
      const out = await _relayPlay(env, vids);
      const resp = _json(out.body, out.status);
      // 主窗响应已成形 (体/状态/耗时与无 next 时一致), 预热
      // 只进 waitUntil 后台; 无 waitUntil 的运行时 (Deno 备
      // 胎) 退化为不等候的后台承诺, 尽力而为、失败无声。
      // 调度本身包 try: waitUntil 若同步抛错 (运行时拒绝登
      // 记等), 绝不许穿出 handler 吞掉已成形的 resp (边界监
      // 工 FAIL 修法), 降级为不等候的后台承诺。
      if (next.length || next2.length) {
        // v2.5.3: 预热链同 invocation 直跑 (整窗批次缓存已把
        // 子请求配额压回安全区, 见文件头 v2.5.3 注)。
        _schedulePw(ctx, _prewarmChain(env, next, next2));
      }
      return resp;
    }
    if (request.method === "POST" && key && url.pathname === "/" + key + "/web/put") {
      return await _webPut(request, env, key);
    }
    const webGetM = key ? /^\/(.+)\/web\/(m|v|a)\/([0-9a-f]{18})\.m3u8$/.exec(url.pathname) : null;
    if (request.method === "GET" && webGetM && webGetM[1] === key) {
      return await _webGet(env, key, webGetM[2], webGetM[3]);
    }
    return new Response("not found", { status: 404 });
  }
};
