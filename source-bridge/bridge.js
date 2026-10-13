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
      if (st.authenticated || status === 'confirmed') {
        qsAuthed = true;
        try { fs.writeFileSync(QS_SESSION_FILE, JSON.stringify(qs.exportSession())); } catch (_e) {}
        qsPending = null;
      }
      return json(res, 200, { ok: true, authed: qsAuthed, status, message: (r && r.message) || '' });
    }).catch(e => json(res, 200, { ok: false, authed: qsAuthed, status: 'error', err: '等待扫码' }));
    return;
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

    return enqueue(() => Promise.all([
      api.getMusicUrl(source, info, '128k').catch(e => 'ERR:' + e),
      api.getLyric(source, info).catch(e => 'ERR:' + e),
      api.getPic(source, info).catch(e => 'ERR:' + e),
    ]).then(([url, lrc, pic]) => {
      const lyricText = (typeof lrc === 'object' && lrc) ? (typeof lrc.lyric === 'string' ? lrc.lyric : JSON.stringify(lrc)) : String(lrc);
      return json(res, 200, { ok: true, url: String(url), lyric: lyricText, pic: String(pic) });
    }).catch(e => json(res, 200, { ok: false, err: String(e && e.message || e) })));
  }

  if (p === '/hot') {
    const source = q.get('source') || 'wy';
    if (source === 'qs') return bad(res, 'qs hot not supported');
    const page = parseInt(q.get('page') || '1', 10);
    const limit = Math.min(parseInt(q.get('limit') || '10', 10), 30);
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
