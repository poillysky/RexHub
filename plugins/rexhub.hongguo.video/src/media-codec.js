import { aesCbcDecrypt } from "./crypto.js";
import { concat, hexBytes } from "./signing-hash.js";

export const decode64 = (value) =>
  Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), (c) =>
    c.charCodeAt(0),
  );
export function deriveContentKey(spade) {
  const raw = decode64(spade.trim());
  if (raw.length < 3) throw new Error("Invalid spade");
  let n = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47;
  if (n <= 0 || n > raw.length * 2) throw new Error("Invalid spade length");
  n = Math.min(n, raw.length - 1);
  if (n < 33) throw new Error("Short spade");
  const data = raw.slice(1, n + 1);
  let a = 85,
    b = 246;
  for (let i = 0; i < n; i++) {
    let count = 0;
    for (let x = i; x; x >>>= 1) count += x & 1;
    const old = data[i],
      prev = i & 1 ? a : b;
    if (i & 1) a = old;
    else b = old;
    data[i] = (-21 - count + (prev ^ old)) & 255;
  }
  const hex = new TextDecoder().decode(data.slice(1, 33));
  if (!/^[0-9a-f]{32}$/i.test(hex)) throw new Error("Invalid content key");
  return hexBytes(hex);
}
export async function decodeMediaUrl(value, keySeed) {
  if (/^https?:\/\//.test(value)) return value.replace(/^http:/, "https:");
  const raw = decode64(value),
    plain = new TextDecoder().decode(raw);
  if (/^https?:\/\//.test(plain)) return plain.replace(/^http:/, "https:");
  if (!keySeed) throw new Error("Encrypted URL without key seed");
  const h1 = new Uint8Array(await crypto.subtle.digest("SHA-512", keySeed));
  const suffix = hexBytes(
    "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58",
  );
  const h2 = new Uint8Array(
    await crypto.subtle.digest("SHA-512", concat(h1, suffix)),
  );
  return new TextDecoder()
    .decode(
      await aesCbcDecrypt(raw.slice(4), h2.slice(0, 16), h2.slice(16, 32)),
    )
    .replace(/^http:/, "https:");
}
export async function selectMedia(model, quality = 1080) {
  const entries = Object.values(model.video_list || {})
    .map((v) => ({ ...v, ...v.video_meta, ...v.encrypt_info }))
    .filter((v) => (v.main_url || v.backup_url || v.backup_url_1) &&
      (!v.vtype || v.vtype === "mp4") &&
      (!v.encryption_method || v.encryption_method === "cenc-aes-ctr"));
  entries.sort((a, b) => {
    const h = (v) =>
      Number.parseInt(v.definition) ||
      Math.min(Number(v.vwidth) || 0, Number(v.vheight) || 0);
    const score = (v) => (h(v) <= quality ? 100000 : 0) + h(v);
    return (
      score(b) - score(a) || (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0)
    );
  });
  const item = entries[0];
  if (!item) throw new Error("No MP4 in video model");
  const spade = item.spade_a || model.spade_a;
  const key = spade ? deriveContentKey(spade) : null;
  if (item.encrypt && !key) throw new Error("Encrypted media without spade");
  const values = [item.main_url, item.backup_url, item.backup_url_1].filter(
    Boolean,
  );
  const urls = [];
  for (const v of values) urls.push(await decodeMediaUrl(v, null));
  return {
    urls: [...new Set(urls)],
    key,
    quality: item.definition,
    size: Number(item.size) || 0,
    expiresAt: Math.min(...[model.url_expire, item.url_expire].map(Number).filter(v => Number.isFinite(v) && v > 0), Infinity),
  };
}
