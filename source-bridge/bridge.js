// 流萤音乐 - 音乐源桥服务（Node）
// 1) LX Music 自定义音源（kg/kw/tx/wy/mg）：长青SVIP音源
// 2) 汽水音乐（qs）：ly-music-source，QR 扫码登录，session 持久化
// 供 Python 后端采集模块调用（仅监听 127.0.0.1）
const http = require('http');
const fs = require('fs');
const path = require('path');
const { MusicApi } = require('inki-music-api');

const PORT = parseInt(process.env.BRIDGE_PORT || '8789', 10);
const SOURCE_FILE = process.env.SOURCE_FILE || path.join(__dirname, 'source.js');
const QS_SESSION_FILE = process.env.QS_SESSION_FILE || path.join(__dirname, 'qs_session.json');

let api = null;
let ready = false;

// ---------- 汽水音乐（ly-music-source） ----------
let qs = null;
let qsAuthed = false;
let qsPending = null;            // { token } 二维码登录进行中
const qsCache = new Map();       // tid -> { data: Buffer, ext: string }，LRU 上限 12 首

function fmtDur(ms) {
  if (!ms) return '';
  const s = Math.floor(ms / 1000);
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}

async function initQs() {
  try {
    const m = await import('ly-music-source');
    qs = m.createMusicSource({ defaultQuality: 'higher', timeoutMs: 30000 });
    if (fs.existsSync(QS_SESSION_FILE)) {
      qs.importSession(JSON.parse(fs.readFileSync(QS_SESSION_FILE, 'utf8')));
      qsAuthed = !!qs.getAuthState().authenticated;
      if (qsAuthed) console.log('[qs] session restored OK');
      else console.log('[qs] session file exists but not authenticated');
    } else {
      console.log('[qs] no session file, need QR login');
    }
  } catch (e) {
    console.error('[qs] init failed:', e.message);
  }
}

async function qsSearch(kw, limit) {
  const songs = await qs.searchSongs(kw, { limit: limit || 10 });
  return (songs || []).map(s => ({
    songmid: String(s.id),
    name: s.title || '',
    singer: (s.artists || []).map(a => a.name || '').join('/'),
    albumName: s.album || '',
    interval: fmtDur(s.durationMs),
    img: s.coverUrl || '',
    source: 'qs',
  }));
}

async function qsResolve(id) {
  const r = await qs.resolve({ ids: { qishui: String(id) }, quality: 'higher' });
  if (r && r.data && r.data.length > 0) return r;
  return null;
}

async function qsLyric(id) {
  try {
    const l = await qs.getLyric({ ids: { qishui: String(id) } });
    if (l && typeof l.lyric === 'string') return l.lyric;
    if (l && typeof l === 'string') return l;
    return '';
  } catch (e) {
    try {
      const l = await qs.getLyric(String(id));
      return (typeof l === 'string') ? l : (l && l.lyric) || '';
    } catch (e2) { return ''; }
  }
}

// ─── gd 平台：GDAPI 公开聚合（music-api.gdstudio.xyz，网易云源）───
const GD_API = 'https://music-api.gdstudio.xyz/api.php?use_xbridge3=true&loader_name=forest&need_sec_link=1&sec_link_scene=im&theme=light';
async function gdSearch(kw, limit) {
  const r = await fetch(GD_API + '&types=search&source=netease&name=' + encodeURIComponent(kw));
  const arr = await r.json();
  return (Array.isArray(arr) ? arr : []).slice(0, limit || 10).map(s => ({
    songmid: String(s.id),
    name: s.name || '',
    singer: (s.artist || []).join(' / '),
    albumName: s.album || '',
    interval: '',
    img: s.pic_id ? ('https://p1.music.126.net/cover/' + s.pic_id + '.jpg') : '',
    source: 'gd',
  }));
}
async function gdResolve(id) {
  const r = await fetch(GD_API + '&types=url&source=netease&id=' + encodeURIComponent(id) + '&br=128');
  const d = await r.json();
  return (d && d.url) ? d.url : '';
}
async function gdLyric(id) {
  try {
    const r = await fetch(GD_API + '&types=lyric&source=netease&id=' + encodeURIComponent(id));
    const d = await r.json();
    return (d && d.lyric) || '';
  } catch (e) { return ''; }
}

// ─── go-music-dl 聚合音源（本机 127.0.0.1:18080，systemd: music-dl.service）───
//   soda       = 汽水音乐（免登录可搜索/解析，音频加密已由其解密）
//   gm_migu    = 咪咕音乐
//   gm_fivesing = 5sing 原创音乐
//   gm_joox    = JOOX 海外
//   gm_kugou/gm_kuwo/gm_qq = 酷狗/酷我/QQ（替代长青源里取流失效的 kg/kw/tx）
const GM_BASE = process.env.GM_BASE || 'http://127.0.0.1:18080/gm';
const GM_MAP = { soda: 'soda', gm_migu: 'migu', gm_fivesing: 'fivesing', gm_joox: 'joox',
                 gm_kugou: 'kugou', gm_kuwo: 'kuwo', gm_qq: 'qq' };

function gmDecode(s) { try { return decodeURIComponent(s); } catch (_e) { return s; } }

async function gmSearch(bridgeSource, kw, limit, page) {
  const gmSrc = GM_MAP[bridgeSource];
  if (!gmSrc) throw new Error('unknown gm source: ' + bridgeSource);
  const url = `${GM_BASE}/search?q=${encodeURIComponent(kw)}&type=song&sources=${gmSrc}&page=${page || 1}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
  const html = await res.text();
  return gmParseSongCards(html, bridgeSource, limit);
}

async function gmResolve(bridgeSource, id) {
  const gmSrc = GM_MAP[bridgeSource];
  try {
    const r = await fetch(`${GM_BASE}/inspect?id=${encodeURIComponent(id)}&source=${gmSrc}`,
      { signal: AbortSignal.timeout(25000) });
    const d = await r.json();
    return (d && d.valid && d.url) ? d.url : '';
  } catch (_e) { return ''; }
}

async function gmLyric(bridgeSource, id) {
  const gmSrc = GM_MAP[bridgeSource];
  try {
    const r = await fetch(`${GM_BASE}/lyric?id=${encodeURIComponent(id)}&source=${gmSrc}`,
      { signal: AbortSignal.timeout(20000) });
    const t = await r.text();
    // 兜底：错误页是 HTML
    return (t && t.charAt(0) !== '<') ? t.trim() : '';
  } catch (_e) { return ''; }
}

// 解析 music-dl SSR 页面里的 song-card 列表（搜索页/榜单详情页通用）
function gmParseSongCards(html, bridgeSource, limit) {
  const blocks = html.split(/class="[^"]*song-card[^"]*"/).slice(1);
  const list = [];
  for (const b of blocks) {
    const tag = b.slice(0, b.indexOf('>') + 1);
    const get = (n) => {
      const m = tag.match(new RegExp('data-' + n + '="([^"]*)"'));
      return m ? gmDecode(m[1]) : '';
    };
    const id = get('id');
    if (!id) continue;
    list.push({
      songmid: id,
      name: get('name'),
      singer: get('artist'),
      albumName: get('album'),
      interval: '',
      img: get('cover'),
      source: bridgeSource,
    });
    if (list.length >= limit) break;
  }
  return list;
}

// 官方热歌榜：拉 music-dl 榜单列表，优先「热歌榜/飙升榜」，返回榜单歌曲
async function gmTop(bridgeSource, limit) {
  const gmSrc = GM_MAP[bridgeSource];
  if (!gmSrc) throw new Error('unknown gm source: ' + bridgeSource);
  const tlRes = await fetch(`${GM_BASE}/toplists?sources=${gmSrc}`,
    { signal: AbortSignal.timeout(30000) });
  const tlHtml = await tlRes.text();
  // 榜单卡片链接：/gm/toplist_songs?...&source=X&toplist_id=Y&toplist_name=Z
  const charts = [];
  const linkRe = /toplist_songs\?([^"'>]+)/g;
  let m;
  while ((m = linkRe.exec(tlHtml)) !== null) {
    const qp = new URLSearchParams(m[1].replace(/&amp;/g, '&'));
    const tid = qp.get('toplist_id');
    const tname = qp.get('toplist_name') || '';
    const tsrc = qp.get('source') || gmSrc;
    if (tid && tsrc === gmSrc) charts.push({ tid, tname });
  }
  if (!charts.length) throw new Error('榜单列表为空: ' + gmSrc);
  // 优先官方热歌榜/飙升榜，其次第一个
  charts.sort((a, b) => {
    const score = (n) => /热歌|飙升|热门/.test(n) ? 0 : 1;
    return score(a.tname) - score(b.tname);
  });
  const picked = charts[0];
  const sRes = await fetch(`${GM_BASE}/toplist_songs?source=${gmSrc}&toplist_id=${encodeURIComponent(picked.tid)}`,
    { signal: AbortSignal.timeout(30000) });
  const sHtml = await sRes.text();
  return { chart: picked.tname, list: gmParseSongCards(sHtml, bridgeSource, limit || 50) };
}

// ─── LRCLIB 社区歌词库兜底（任何源取不到歌词时，按歌名+歌手匹配）───
async function lrcLibFallback(name, singer) {
  if (!name) return '';
  try {
    const r = await fetch(
      `https://lrclib.net/api/get?artist_name=${encodeURIComponent(singer || '')}&track_name=${encodeURIComponent(name)}`,
      { signal: AbortSignal.timeout(12000) });
    if (!r.ok) return '';
    const d = await r.json();
    return d.syncedLyrics || d.plainLyrics || '';
  } catch (_e) { return ''; }
}

// ─── qs2：yuntts 托管汽水链接解析（第三方服务器代取流，绕开本机 IP 风控）───
// 仅支持「汽水分享链接 → 音频直链+逐字歌词」，不支持关键词搜索。
// 需要环境变量 QS2_API_KEY（yuntts 开放平台申请后配置进 systemd）。
const QS2_API = process.env.QS2_API_URL || 'https://www.yuntts.com/api/v1/soda';
const QS2_KEY = process.env.QS2_API_KEY || '';

// yuntts 歌词是毫秒 [beginMs,endMs]<...>字 格式，转标准 KRC 秒级 [mm:ss.xxx]<...>字
function qs2LyricToKrc(lrc) {
  if (!lrc || typeof lrc !== 'string') return '';
  if (lrc.indexOf('暂无歌词') !== -1) return '';
  return lrc.split(/\r?\n/).map(line => {
    const m = line.match(/^\[(\d+),(\d+)\](.*)$/);
    if (!m) return line;
    const begin = parseInt(m[1], 10) / 1000;
    const mm = Math.floor(begin / 60);
    const ss = (begin - mm * 60).toFixed(3).padStart(6, '0');
    return `[${String(mm).padStart(2, '0')}:${ss}]${m[3]}`;
  }).join('\n');
}

function qsCachePut(tid, data, ext) {
  qsCache.set(tid, { data, ext });
  while (qsCache.size > 12) {
    const k = qsCache.keys().next().value;
    qsCache.delete(k);
  }
}

// ---------- 串行队列：音源内部避免并发 ----------
let queue = Promise.resolve();
let qsQueue = Promise.resolve();
function enqueue(fn, q) {
  const target = q || queue;
  const p = target.then(fn, fn);
  const nq = p.catch(() => {});
  if (target === qsQueue) qsQueue = nq; else queue = nq;
  return p;
}

function json(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(body);
}

function bad(res, msg) {
  json(res, 400, { ok: false, err: msg });
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const p = u.pathname;
  const q = u.searchParams;

  if (!ready) return bad(res, 'not ready');

  // 汽水音乐下载端点：server.py 采集时 urlopen 此地址拿音频数据
  if (p.startsWith('/dl/')) {
    const tid = decodeURIComponent(p.slice(4));
    const hit = qsCache.get(tid);
    if (!hit) return bad(res, 'not found');
    res.writeHead(200, {
      'Content-Type': 'audio/mpeg',
      'Content-Length': hit.data.length,
      'Cache-Control': 'no-store',
    });
    res.end(hit.data);
    qsCache.delete(tid);
    return;
  }

  if (p === '/ping') {
    const plats = api.getSupportedPlatforms().slice();
    if (qs) plats.push('qs');
    plats.push(...Object.keys(GM_MAP));
    return json(res, 200, { ok: true, platforms: plats, qsAuthed });
  }

  // 汽水音乐登录状态
  if (p === '/qs/status') {
    return json(res, 200, { ok: true, authed: qsAuthed });
  }

  // 汽水音乐二维码登录：生成二维码（查询类接口，不进串行队列）
  if (p === '/qs/qr') {
    if (!qs) return json(res, 200, { ok: false, err: '汽水音乐模块未加载' });
    Promise.resolve().then(() => qs.createQrLogin())
      .then(r => {
        qsPending = { token: r.token };
        return json(res, 200, { ok: true, token: r.token, qrcode: r.qrcode });
      })
      .catch(e => json(res, 200, { ok: false, err: '二维码生成失败:' + (e && e.message || e) }));
    return;
  }

  // 汽水音乐二维码登录：轮询扫码结果（轻量查询，并发执行不排队）
  if (p === '/qs/poll') {
    const token = q.get('token') || (qsPending && qsPending.token);
    if (!token) return bad(res, 'token required');
    Promise.race([
      Promise.resolve().then(() => qs.pollQrLogin('qishui', token)),
      new Promise((_, rej) => setTimeout(() => rej(new Error('等待扫码')), 10000)),
    ]).then((r) => {
      const st = qs.getAuthState();
      const status = (r && r.status) || 'waiting';
      console.error('[qs-poll] upstream:', JSON.stringify({ token: String(token).slice(0, 12), status, message: (r && r.message) || '', authed: st.authenticated }));
      if (st.authenticated || status === 'confirmed') {
        qsAuthed = true;
        try { fs.writeFileSync(QS_SESSION_FILE, JSON.stringify(qs.exportSession())); } catch (_e) {}
        qsPending = null;
      }
      return json(res, 200, { ok: true, authed: qsAuthed, status, message: (r && r.message) || '' });
    }).catch(e => {
      console.error('[qs-poll] error:', (e && e.message) || e);
      return json(res, 200, { ok: false, authed: qsAuthed, status: 'error', err: '等待扫码' });
    });
    return;
  }

  // 汽水音乐短信登录：发送验证码
  if (p === '/qs/sms/send') {
    const mobile = (q.get('mobile') || '').trim();
    Promise.resolve().then(() => qs.sendSmsCode(mobile))
      .then(r => {
        console.error('[qs-sms-send]', mobile.slice(0,3)+'****'+mobile.slice(-4), 'raw=', JSON.stringify(r && r.raw).slice(0, 800));
        // 从上游原始响应里提取图形验证码/风控验证 URL
        let captchaUrl = '';
        try {
          const raw = (r && r.raw) || {};
          const data = raw.data || raw;
          captchaUrl = data.captcha_url || data.verify_url || data.captcha_url_new || data.verification_url || data.url || data.redirect_url || '';
          if (captchaUrl && !/^https?:/i.test(captchaUrl)) captchaUrl = '';
        } catch (_e) {}
        return json(res, 200, { ok: !!(r && r.ok), message: (r && r.message) || (r && r.ok ? '验证码已发送' : '发送失败'), captchaUrl });
      })
      .catch(e => {
        console.error('[qs-sms-send] error:', (e && e.message) || e);
        return json(res, 200, { ok: false, message: (e && e.message) || '发送失败' });
      });
    return;
  }

  // 汽水音乐短信登录：验证码登录
  if (p === '/qs/sms/login') {
    const mobile = (q.get('mobile') || '').trim();
    const code = (q.get('code') || '').trim();
    Promise.resolve().then(() => qs.smsLogin(mobile, code))
      .then(r => {
        const st = qs.getAuthState();
        console.error('[qs-sms-login]', mobile.slice(0,3)+'****'+mobile.slice(-4), JSON.stringify({ok: r && r.ok, authed: st.authenticated, msg: r && r.message}));
        if (st.authenticated || (r && r.ok)) {
          qsAuthed = true;
          try { fs.writeFileSync(QS_SESSION_FILE, JSON.stringify(qs.exportSession())); } catch (_e) {}
          qsPending = null;
        }
        return json(res, 200, { ok: !!(r && r.ok), authed: qsAuthed, message: (r && r.message) || '' });
      })
      .catch(e => {
        console.error('[qs-sms-login] error:', (e && e.message) || e);
        return json(res, 200, { ok: false, authed: qsAuthed, message: (e && e.message) || '登录失败' });
      });
    return;
  }

  // 汽水音乐 Cookie 导入（服务器IP过不了风控时的备用通道）
  if (p === '/qs/cookie/import') {
    const cookie = (q.get('cookie') || '').trim();
    if (!cookie) return bad(res, 'cookie required');
    Promise.resolve().then(() => qs.importCookie('qishui', cookie))
      .then(() => {
        qsAuthed = true;
        try { fs.writeFileSync(QS_SESSION_FILE, JSON.stringify(qs.exportSession())); } catch (_e) {}
        return json(res, 200, { ok: true, authed: true, message: 'Cookie 导入成功，已登录汽水音乐' });
      })
      .catch(e => {
        console.error('[qs-cookie] error:', (e && e.message) || e);
        return json(res, 200, { ok: false, authed: qsAuthed, message: (e && e.message) || 'Cookie 无效：' + ((e && e.message) || e) });
      });
    return;
  }

  // qs2 托管汽水解析状态
  if (p === '/qs2/status') {
    return json(res, 200, { ok: true, configured: !!QS2_KEY });
  }

  // qs2 托管汽水链接解析：?url=汽水分享链接（qishui.douyin.com/s/...）
  // 返回音频直链 + KRC 逐字歌词；不走本机 IP，由 yuntts 代取流。
  if (p === '/qs2/parse') {
    const share = (q.get('url') || '').trim();
    if (!share) return bad(res, 'url required');
    if (!QS2_KEY) return json(res, 200, { ok: false, err: 'qs2 未配置：需要环境变量 QS2_API_KEY（yuntts 开放平台申请）' });
    return enqueue(async () => {
      try {
        const r = await fetch(QS2_API, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + QS2_KEY },
          body: JSON.stringify({ url: share }),
          signal: AbortSignal.timeout(25000),
        });
        const d = await r.json();
        if (!d || d.code !== 200 || !d.data || !d.data.url) {
          return json(res, 200, { ok: false, err: (d && d.message) || '托管解析失败' });
        }
        return json(res, 200, {
          ok: true,
          url: d.data.url,
          lyric: qs2LyricToKrc(d.data.lyric || ''),
          singer: d.data.artistsname || '',
          album: d.data.albumname || '',
          cover: d.data.artistsavatar || '',
          bitrate: d.data.bitrate || 0,
          size: d.data.size || 0,
        });
      } catch (e) {
        return json(res, 200, { ok: false, err: '托管解析错误:' + String(e && e.message || e) });
      }
    });
  }

  if (p === '/search') {
    const source = q.get('source') || 'wy';
    const kw = (q.get('kw') || '').trim();
    const page = parseInt(q.get('page') || '1', 10);
    const limit = Math.min(parseInt(q.get('limit') || '10', 10), 30);
    if (!kw) return bad(res, 'kw required');

    if (source === 'qs') {
      if (!qs) return json(res, 200, { ok: false, err: '汽水音乐模块未加载' });
      return enqueue(() => qsSearch(kw, limit)
        .then(list => json(res, 200, { ok: true, list }))
        .catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })), qsQueue);
    }
    if (source === 'gd') {
      return enqueue(() => gdSearch(kw, limit)
        .then(list => json(res, 200, { ok: true, list }))
        .catch(e => json(res, 200, { ok: false, err: 'GDAPI搜索失败:' + String(e && e.message || e) })));
    }
    if (GM_MAP[source]) {
      return enqueue(() => gmSearch(source, kw, limit, page)
        .then(list => json(res, 200, { ok: true, list }))
        .catch(e => json(res, 200, { ok: false, err: '聚合源搜索失败:' + String(e && e.message || e) })));
    }
    return enqueue(() => api.search(source, kw, { page, limit })
      .then(r => json(res, 200, { ok: true, list: (r.list || []).map(s => ({
        songmid: s.songmid, name: s.name, singer: s.singer, albumName: s.albumName,
        interval: s.interval, img: s.img, source: s.source,
      })) }))
      .catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })));
  }

  if (p === '/song') {
    const source = q.get('source') || 'wy';
    const songmid = (q.get('songmid') || '').trim();
    if (!songmid) return bad(res, 'songmid required');
    const info = {
      songmid, source,
      name: q.get('name') || '', singer: q.get('singer') || '',
      albumName: q.get('album') || '', interval: q.get('interval') || '',
      img: q.get('img') || '',
    };

    if (source === 'qs') {
      if (!qs) return json(res, 200, { ok: false, err: '汽水音乐模块未加载' });
      if (!qsAuthed) return json(res, 200, { ok: false, err: '汽水音乐未登录，请先在后台扫码登录' });
      return enqueue(() => Promise.all([
        qsResolve(songmid),
        qsLyric(songmid),
      ]).then(([rv, lrc]) => {
        if (!rv) return json(res, 200, { ok: false, err: '汽水音乐解析失败（可能仅试听或无版权）' });
        const tid = 'qs_' + songmid;
        qsCachePut(tid, rv.data, rv.ext || 'mp3');
        return json(res, 200, {
          ok: true,
          url: `http://127.0.0.1:${PORT}/dl/${encodeURIComponent(tid)}`,
          lyric: lrc || '',
          pic: info.img || '',
        });
      }).catch(e => json(res, 200, { ok: false, err: '音源错误:' + String(e && e.message || e) })), qsQueue);
    }

    if (source === 'gd') {
      return enqueue(() => Promise.all([
        gdResolve(songmid),
        gdLyric(songmid),
      ]).then(async ([url, lrc]) => {
        if (!url) return json(res, 200, { ok: false, err: 'GDAPI解析播放地址失败（可能无版权或VIP）' });
        if (!lrc) lrc = await lrcLibFallback(info.name, info.singer);
        return json(res, 200, { ok: true, url, lyric: lrc || '', pic: info.img || '' });
      }).catch(e => json(res, 200, { ok: false, err: 'GDAPI错误:' + String(e && e.message || e) })));
    }

    if (GM_MAP[source]) {
      return enqueue(() => Promise.all([
        gmResolve(source, songmid),
        gmLyric(source, songmid),
      ]).then(async ([url, lrc]) => {
        if (!url) return json(res, 200, { ok: false, err: '聚合源解析播放地址失败（可能无版权或VIP）' });
        if (!lrc) lrc = await lrcLibFallback(info.name, info.singer);
        return json(res, 200, { ok: true, url, lyric: lrc || '', pic: info.img || '' });
      }).catch(e => json(res, 200, { ok: false, err: '聚合源错误:' + String(e && e.message || e) })));
    }

    return enqueue(() => Promise.all([
      api.getMusicUrl(source, info, '128k').catch(e => 'ERR:' + e),
      api.getLyric(source, info).catch(e => 'ERR:' + e),
      api.getPic(source, info).catch(e => 'ERR:' + e),
    ]).then(async ([url, lrc, pic]) => {
      const lyricText = (typeof lrc === 'object' && lrc) ? (typeof lrc.lyric === 'string' ? lrc.lyric : JSON.stringify(lrc)) : String(lrc);
      const finalLrc = lyricText && lyricText.indexOf('ERR:') !== 0 ? lyricText : await lrcLibFallback(info.name, info.singer);
      return json(res, 200, { ok: true, url: String(url), lyric: finalLrc || '', pic: String(pic) });
    }).catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })));
  }

  if (p === '/hot') {
    const source = q.get('source') || 'wy';
    const limit = Math.min(parseInt(q.get('limit') || '10', 10), 50);
    // 聚合源走 music-dl 官方热歌榜（免关键词）
    if (GM_MAP[source]) {
      return enqueue(() => gmTop(source, limit)
        .then(r => json(res, 200, { ok: true, chart: r.chart, list: r.list }))
        .catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })));
    }
    if (source === 'qs') return bad(res, 'qs hot not supported');
    const page = parseInt(q.get('page') || '1', 10);
    return enqueue(() => api.getHot(source, { page, limit })
      .then(r => json(res, 200, { ok: true, list: (r.list || []).map(s => ({
        songmid: s.songmid, name: s.name, singer: s.singer, albumName: s.albumName,
        interval: s.interval, img: s.img, source: s.source,
      })) }))
      .catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })));
  }

  bad(res, 'unknown path: ' + p);
});

(async () => {
  api = new MusicApi({ requestTimeout: 25000, initTimeout: 20000 });
  await api.loadSourceFromFile(SOURCE_FILE);
  await initQs();
  ready = true;
  server.listen(PORT, '127.0.0.1', () => {
    const plats = api.getSupportedPlatforms().slice();
    if (qs) plats.push('qs');
    console.log(`[bridge] listening on 127.0.0.1:${PORT}, platforms: ${plats.join(',')}, qsAuthed=${qsAuthed}`);
  });
})().catch(e => {
  console.error('[bridge] init failed:', e);
  process.exit(1);
});
