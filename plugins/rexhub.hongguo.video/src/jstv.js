// 红果 JSTV 取流：73532 代参数 + PlayerSign 四头 + 每集现注册身份。
// 参考：红果播放中转服务 v3.0.1 / 聚合短剧WorkerA v2.6.8。
// 匿名身份只能播 1 集，复用会回 HTTP 200 空包，因此每次请求都重新注册身份；
// 空回包 / 非 200 时换新身份并切主机重发。
import nodeCrypto from 'node:crypto';
import { md5 } from './crypto.js';
import { playerSignJstv, playerBranchOf } from './player-sign.js';

const PLAY_HOSTS = ['api5-normal-sinfonlineb.fqnovel.com', 'api5-normal-hl.fqnovel.com'];
const SINGLE_PATH = '/novel/player/video_model/v1/';
const BATCH_PATH = '/novel/player/multi_video_model/v1/';
const REGISTER_URL = 'https://log5-applog-lf.fqnovel.com/service/2/device_register/';
const JSTV_UA = 'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)';

// 设备画像：与参考 _PROFILE_HW 同形，注册 / 播放共用一套硬件指纹。
const PROFILE_HW = {
  device_type: '25053RT47C',
  device_brand: 'Redmi',
  channel: '69310258a',
  dragon_device_type: 'phone',
  os_version: '16',
  os_api: '36',
  rom_version: 'W528JS release-keys',
  rom: '1135',
  carrier: 'CHINA MOBILE',
  mcc_mnc: '46000',
  resolution: '2772*1280',
  dpi: '520',
};

const uuid = () => nodeCrypto.randomUUID();
const stubOf = (body) => Buffer.from(md5(body)).toString('hex').toUpperCase();

// 播放 query：73532 代参数（aid 8662 / novelread），与参考 _jstvPost 一致。
function playbackQuery(identity) {
  const qs = new URLSearchParams({
    aid: '8662',
    app_name: 'novelread',
    version_code: '73532',
    version_name: '7.3.5.32',
    manifest_version_code: '73532',
    update_version_code: '73532',
    channel: 'update_64',
    device_platform: 'android',
    os: 'android',
    ssmix: 'a',
    device_type: PROFILE_HW.device_type,
    device_brand: PROFILE_HW.device_brand,
    language: 'zh',
    os_api: PROFILE_HW.os_api,
    os_version: PROFILE_HW.os_version,
    resolution: '1280*2772',
    dpi: PROFILE_HW.dpi,
    ac: 'wifi',
    device_id: String(identity.device_id),
    iid: String(identity.iid),
  });
  qs.sort();
  return qs;
}

// 注册 UA 仍是 73932 代（参考：注册不动，播放才升 73532）。
const REGISTER_UA = 'com.phoenix.read/73932 (Linux; U; Android ' + PROFILE_HW.os_version + '; zh_CN; '
  + PROFILE_HW.device_type + '; Build/' + PROFILE_HW.rom_version.split(' ')[0]
  + '; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)';

function registerHeader(trio) {
  const pf = PROFILE_HW;
  return {
    display_name: '红果免费短剧',
    update_version_code: 73932,
    manifest_version_code: 73932,
    app_version_minor: '7.3.9.32',
    aid: 8662,
    channel: pf.channel,
    package: 'com.phoenix.read',
    app_version: '7.3.9.32',
    version_code: 73932,
    sdk_version: '3.7.0-rc.34-fanqie-xiaoshuo',
    sdk_target_version: 29,
    os: 'Android',
    os_version: pf.os_version,
    os_api: Number(pf.os_api),
    device_model: pf.device_type,
    device_brand: pf.device_brand,
    device_manufacturer: 'Xiaomi',
    cpu_abi: 'arm64-v8a',
    density_dpi: Number(pf.dpi),
    display_density: 'mdpi',
    resolution: '1280x2772',
    language: 'zh',
    timezone: 8,
    access: 'wifi',
    not_request_sender: 0,
    carrier: pf.carrier,
    mcc_mnc: pf.mcc_mnc,
    rom: pf.rom,
    rom_version: pf.rom_version,
    git_hash: '3a88f4e',
    sig_hash: '56a962410c494bbaf0b58dba20cae56f',
    release_build: 'b5e187f',
    cdid: trio.cdid,
    openudid: trio.openudid,
    clientudid: trio.clientudid,
    ipv6_list: [],
    region: 'CN',
    tz_name: 'Asia/Shanghai',
    tz_offset: 28800,
    sim_region: 'cn',
    sim_serial_number: [],
    oaid_may_support: false,
    req_id: uuid(),
    device_platform: 'android',
    custom: { account_region_src: 'fallback', host_bit: 64, account_region: 'cn', dragon_device_type: pf.dragon_device_type },
    pre_installed_channel: '',
    apk_first_install_time: Date.now(),
    is_system_app: 0,
    sdk_flavor: 'china',
    guest_mode: 0,
  };
}

function readId(json, name) {
  const pref = json[name + '_str'];
  const value = pref === undefined || pref === null || pref === '' ? json[name] : pref;
  if (typeof value === 'number') {
    return Number.isInteger(value) && value > 0 && value <= Number.MAX_SAFE_INTEGER ? String(value) : '';
  }
  return typeof value === 'string' && /^\d{1,30}$/.test(value) && /[1-9]/.test(value) ? value : '';
}

async function post(url, body, headers, signal) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  try {
    return await fetch(url, { method: 'POST', headers, body, signal: controller.signal });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

// 注册一枚全新的匿名身份（标准 AppLog 协议）。匿名身份一发即废，不复用。
async function registerIdentity(signal) {
  const trio = { cdid: uuid(), openudid: nodeCrypto.randomBytes(10).toString('hex'), clientudid: uuid() };
  const now = Date.now();
  const url = REGISTER_URL + '?req_id=' + uuid() + '&_rticket=' + now;
  const body = JSON.stringify({ magic_tag: 'ss_app_log', header: registerHeader(trio), _gen_time: now });
  const res = await post(url, body, {
    'User-Agent': REGISTER_UA,
    Accept: 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
  }, signal);
  const text = await res.text();
  if (res.status !== 200) throw new Error('device_register HTTP ' + res.status);
  if (!text.trim()) throw new Error('device_register 空回包');
  const data = JSON.parse(text);
  const code = data.code ?? data.Code ?? 0;
  if (Number(code) !== 0) throw new Error('device_register 业务拒绝 code=' + code);
  const deviceId = readId(data, 'device_id');
  const installId = readId(data, 'install_id');
  if (!deviceId || !installId) throw new Error('device_register 回包缺有效 id: ' + text.slice(0, 200));
  return { device_id: deviceId, iid: installId, ...trio };
}

// 单集 / 批量共用的 JSTV POST：签名四头 + X-SS-STUB，空回包由调用方换身份重发。
async function jstvPost(identity, base, payload, signal) {
  const bodyStr = JSON.stringify(payload);
  const bodyBytes = new TextEncoder().encode(bodyStr);
  const qs = playbackQuery(identity);
  const tsSec = Math.floor(Date.now() / 1000);
  // 签名分支为 1 时上游会拒，递增 _rticket 重算（最多 24 次）。
  let rticket = Date.now();
  let url = '';
  for (let n = 0; n < 24; n++) {
    url = base + '?' + qs.toString() + '&_rticket=' + rticket;
    if (playerBranchOf(url, bodyBytes, tsSec) !== 1) break;
    rticket++;
  }
  const headers = {
    'User-Agent': JSTV_UA,
    Accept: 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
    'X-XS-From-Web': '0',
    'Sdk-Version': '2',
    'X-SS-Req-Ticket': String(Date.now()),
    'X-SS-STUB': stubOf(bodyBytes),
    ...playerSignJstv(url, bodyBytes, tsSec, nodeCrypto.randomBytes(11)),
  };
  const res = await post(url, bodyStr, headers, signal);
  const text = await res.text();
  const diag = {
    status: res.status,
    len: text.length,
    logid: res.headers.get('x-tt-logid') || '',
    ctype: res.headers.get('content-type') || '',
    url,
  };
  if (res.status !== 200) return { kind: 'fail', reason: 'HTTP ' + res.status + ' ' + text.slice(0, 200), diag };
  if (!text.trim()) return { kind: 'empty', diag };
  const json = JSON.parse(text);
  const code = json.Code ?? json.code ?? 0;
  if (Number(code) !== 0) return { kind: 'fail', reason: 'code=' + code + ' ' + (json.message || '') };
  return { kind: 'ok', data: json.data && typeof json.data === 'object' ? json.data : {} };
}

function parseModel(raw) {
  let model = raw;
  if (typeof model === 'string') {
    try { model = JSON.parse(model); } catch { model = null; }
  }
  return model && typeof model === 'object' ? model : null;
}

// 单集路：content_type:1 + video_platform:3。
async function playSingle(identity, vid, host, signal) {
  const result = await jstvPost(identity, 'https://' + host + SINGLE_PATH, {
    video_id: String(vid),
    content_type: 1,
    biz_param: { need_all_video_definition: true, video_platform: 3 },
  }, signal);
  if (result.kind !== 'ok') return result;
  const model = parseModel(result.data.video_model);
  return model ? { kind: 'ok', model } : { kind: 'empty' };
}

// 批量兜底路：上游若对单集接口限流，仍可用 multi_video_model 取单集。
async function playBatch(identity, vid, host, signal) {
  const result = await jstvPost(identity, 'https://' + host + BATCH_PATH, {
    biz_param: {
      detail_page_version: 0,
      device_level: 3,
      disable_digg_stat: false,
      need_all_video_definition: true,
      need_mp4_align: false,
      use_os_player: false,
      use_server_dns: false,
      video_platform: 1024,
    },
    mixed_video_id_map: { 1004: [String(vid)] },
  }, signal);
  if (result.kind !== 'ok') return result;
  const entry = result.data[String(vid)];
  const model = parseModel(entry && typeof entry === 'object' ? entry.video_model : null);
  return model ? { kind: 'ok', model } : { kind: 'empty' };
}

// 换身份重新播放闭环：每一发都用新注册的身份，空回包 / 失败就换身份并切主机。
export async function fetchVideoModel(videoId, { signal, log = () => {} } = {}) {
  const vid = String(videoId);
  const errors = [];
  for (const lane of ['single', 'batch']) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const host = PLAY_HOSTS[attempt % PLAY_HOSTS.length];
      let identity;
      try {
        identity = await registerIdentity(signal);
      } catch (error) {
        errors.push('register: ' + error.message);
        log('hg 注册失败: ' + error.message);
        continue;
      }
      try {
        const result = lane === 'single'
          ? await playSingle(identity, vid, host, signal)
          : await playBatch(identity, vid, host, signal);
        if (result.kind === 'ok') {
          log('hg JSTV ' + lane + ' 取流成功 host=' + host);
          return result.model;
        }
        const d = result.diag;
        const reason = (result.kind === 'empty' ? '空回包' : result.reason)
          + (d ? ' [st=' + d.status + ' len=' + d.len + ' logid=' + d.logid + ' ct=' + d.ctype + ']' : '');
        errors.push(lane + '@' + host + ': ' + reason);
        log('hg JSTV ' + lane + ' ' + reason + '，换身份切主机重发');
        if (d) log('hg 实际请求 url=' + d.url);
      } catch (error) {
        errors.push(lane + '@' + host + ': ' + error.message);
        log('hg JSTV ' + lane + ' 异常: ' + error.message);
      }
    }
  }
  throw new Error('JSTV 取流失败: ' + errors.join(' | '));
}

export function createJstvClient(options = {}) {
  return {
    async play(videoId, signal) {
      const model = await fetchVideoModel(videoId, { ...options, signal });
      return { video_model: JSON.stringify(model), expire_time: Number(model?.url_expire) || 0 };
    },
  };
}
