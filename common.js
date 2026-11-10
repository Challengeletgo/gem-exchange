// Shared helpers for the trading page and the operator page.
(function () {
  const TYPES = { fire: ['#ff7a3d', '#c2361b'], psy: ['#e07bff', '#9a3fd1'], elec: ['#ffd23d', '#d99a00'], dark: ['#5b5f7a', '#23263a'], drag: ['#4bc0c8', '#2a5fa8'] };
  const $ = id => document.getElementById(id);
  const num = v => Number(v) || 0;
  const fmt = (x, d = 0) => { x = num(x); return (x < 0 ? '-' : '') + Math.abs(x).toLocaleString('ko-KR', { minimumFractionDigits: d, maximumFractionDigits: d }); };
  const tickSize = p => p < 10000 ? 10 : p < 100000 ? 50 : 100;
  const roundT = p => Math.max(tickSize(p), Math.round(p / tickSize(p)) * tickSize(p));
  const esc = s => String(s ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
  const cname = c => `${c.name} ${c.rarity}`;
  const icoHTML = c => { const [a, b] = TYPES[c.ptype] || TYPES.dark; return `<div class="ico" style="background:linear-gradient(140deg,${a},${b})"><u>${c.lang}</u>${esc(c.sym.split('-')[0])}<i>${esc(c.rarity)}</i></div>`; };
  function kstParts(d = new Date()) {
    const p = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).formatToParts(d);
    const g = t => +p.find(x => x.type === t).value; return { h: g('hour') % 24, m: g('minute'), s: g('second') };
  }
  function isOpen(cfg, d = new Date()) {
    const h = kstParts(d).h, a = cfg.close_start_h, b = cfg.close_end_h;
    return a <= b ? !(h >= a && h < b) : !(h >= a || h < b);
  }
  // seconds until the next boundary (open or close)
  function secsToSwitch(cfg, d = new Date()) {
    const { h, m, s } = kstParts(d), cur = h * 3600 + m * 60 + s, target = (isOpen(cfg, d) ? cfg.close_start_h : cfg.close_end_h) * 3600;
    let diff = target - cur; if (diff <= 0) diff += 86400; return diff;
  }
  const hms = t => [Math.floor(t / 3600), Math.floor(t / 60) % 60, t % 60].map(x => String(x).padStart(2, '0')).join(':');
  function toast(msg) { const t = $('toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.h); toast.h = setTimeout(() => t.hidden = true, 3600); }
  function errMsg(e) { const m = (e && (e.message || e.error_description)) || '요청을 처리하지 못했어요'; return m.replace(/^.*?ERROR:\s*/, ''); }
  function armed(btn, label, fn) {
    if (!btn.classList.contains('arm')) { btn.dataset.old = btn.textContent; btn.classList.add('arm'); btn.textContent = label;
      setTimeout(() => { if (btn.classList.contains('arm')) { btn.classList.remove('arm'); btn.textContent = btn.dataset.old; } }, 3000); return; }
    btn.classList.remove('arm'); btn.textContent = btn.dataset.old; fn();
  }
  function client() {
    const C = window.GEM_CONFIG || {};
    if (!window.supabase || !C.SUPABASE_URL || C.SUPABASE_URL.includes('YOUR-PROJECT')) return null;
    return window.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true } });
  }
  async function ensureSession(sb) {
    const { data } = await sb.auth.getSession();
    if (data.session) return data.session;
    const r = await sb.auth.signInAnonymously();
    if (r.error) throw r.error;
    return r.data.session;
  }
  window.GEM = { TYPES, $, num, fmt, tickSize, roundT, esc, cname, icoHTML, kstParts, isOpen, secsToSwitch, hms, toast, errMsg, armed, client, ensureSession };
})();
