(function () {
const { $, num, fmt, roundT, tickSize, esc, cname, icoHTML, isOpen, secsToSwitch, hms, toast, errMsg, armed } = GEM;
const sb = GEM.client();
let CFG = { close_start_h: 0, close_end_h: 8, fee_pct: 0.05, max_lev: 20, start_cash: 1000000, refill_amount: 1000000, refill_thr_pct: 10, refill_cool_h: 24, notice: '', season: '' };
let CARDS = [], ME = null, PEND = {}, LADDER = [], CANDLES = [], LB = [];
let sel = null, tf = 1, tab = 'hold', filt = 'ALL', mode = 'spot', rside = 'buy', busy = false, wasOpen = null;

const card = s => CARDS.find(c => c.sym === s);
const price = s => num(card(s)?.price);
const fee = () => num(CFG.fee_pct) / 100;
const open = () => isOpen(CFG);

/* ---------------- data ---------------- */
async function loadMarket() {
  const [c, g, n] = await Promise.all([
    sb.from('cards').select('*').order('sort'),
    sb.from('config').select('*').eq('id', 1).single(),
    sb.from('news').select('*').order('id', { ascending: false }).limit(1),
  ]);
  if (!c.error && c.data) CARDS = c.data;
  if (!g.error && g.data) CFG = g.data;
  if (!n.error && n.data && n.data[0]) showNews(n.data[0]);
  if (!sel && CARDS.length) { sel = CARDS[0].sym; buildRail(); }
}
async function loadMe() { const r = await sb.rpc('my_summary'); if (!r.error) ME = r.data; return ME; }
async function loadPend() {
  const [p, l] = await Promise.all([sb.rpc('pending_summary'), sel ? sb.rpc('order_ladder', { p_sym: sel }) : { data: [] }]);
  if (!p.error) { PEND = {}; for (const x of p.data || []) PEND[x.sym] = x; }
  if (!l.error) LADDER = l.data || [];
}
async function loadCandles() {
  if (!sel) return;
  const r = await sb.from('candles').select('t,o,h,l,c,v').eq('sym', sel).order('t', { ascending: false }).limit(600);
  if (!r.error) CANDLES = (r.data || []).reverse().map(x => ({ t: new Date(x.t).getTime(), o: num(x.o), h: num(x.h), l: num(x.l), c: num(x.c), v: num(x.v) }));
}
async function loadLB() { const r = await sb.rpc('leaderboard'); if (!r.error) LB = r.data || []; }

async function act(fn, args, okMsg) {
  if (busy) return; busy = true;
  try {
    const r = await sb.rpc(fn, args);
    if (r.error) throw r.error;
    await Promise.all([loadMe(), loadPend(), loadMarket()]);
    render(); if (okMsg) toast(typeof okMsg === 'function' ? okMsg(r.data) : okMsg);
  } catch (e) { toast(errMsg(e)); }
  finally { busy = false; }
}

/* ---------------- render ---------------- */
function showNews(n) {
  const c = n.sym ? card(n.sym) : null;
  $('news').innerHTML = (c ? `<b class="${n.up ? 'up' : 'down'}">${n.up ? '▲' : '▼'} ${esc(c.name)} ${esc(c.rarity)}</b> &nbsp;` : '') + esc(n.body);
}
function chg(c) { const r = num(c.day_ref) || num(c.base_krw); return (num(c.price) / r - 1) * 100; }
function pressOf(s) { const p = PEND[s]; if (!p) return null; const b = num(p.buy_value), v = num(p.sell_value); return b + v > 0 ? { b, v, r: b / (b + v) } : null; }
function buildRail() {
  $('rail').innerHTML = CARDS.filter(c => filt === 'ALL' || c.lang === filt).map(c => `<button class="trow" data-s="${esc(c.sym)}" aria-pressed="${c.sym === sel}">${icoHTML(c)}<div class="tn"><b>${esc(cname(c))}</b><span>${c.lang} · ${esc(c.set_code)}</span><div class="mpress" data-mp></div></div><div class="tp num"><b data-px></b><span data-cx></span></div></button>`).join('');
  $('rail').querySelectorAll('.trow').forEach(b => b.onclick = async () => { sel = b.dataset.s; buildRail(); render(true); await Promise.all([loadCandles(), loadPend()]); render(); });
}
function render(full) {
  if (!ME || !sel) return;
  const isO = open();
  // status
  const st = $('mStatus'); st.className = 'status ' + (isO ? 'open' : 'closed'); st.querySelector('span').textContent = isO ? '장 운영 중' : '장 마감';
  $('closedbar').hidden = isO; $('frozen').hidden = isO;
  const two = n => String(n).padStart(2, '0');
  $('closeHours').textContent = `${two(CFG.close_start_h)}:00~${two(CFG.close_end_h)}:00`;
  $('countdown').textContent = '개장까지 ' + hms(secsToSwitch(CFG));
  for (const id of ['bBuy', 'bSell', 'bLong', 'bShort']) $(id).disabled = !isO;
  $('season').textContent = CFG.season; $('notice').hidden = !CFG.notice; $('notice').textContent = CFG.notice;
  document.querySelectorAll('.feeTxt').forEach(e => e.textContent = num(CFG.fee_pct));
  // rail
  $('rail').querySelectorAll('.trow').forEach(b => {
    const c = card(b.dataset.s); if (!c) return; const ch = chg(c);
    b.querySelector('[data-px]').textContent = fmt(roundT(num(c.price)));
    const cs = b.querySelector('[data-cx]'); cs.textContent = (ch >= 0 ? '+' : '') + ch.toFixed(2) + '%'; cs.className = ch >= 0 ? 'up' : 'down';
    const p = pressOf(c.sym), mp = b.querySelector('[data-mp]');
    mp.innerHTML = p ? `<i style="width:${p.r * 100}%;background:var(--up)"></i><i style="width:${(1 - p.r) * 100}%;background:var(--down)"></i>` : '';
    mp.title = p ? `대기 매수 ${Math.round(p.r * 100)}% · 매도 ${Math.round((1 - p.r) * 100)}%` : '';
  });
  const c = card(sel), p = num(c.price), ch = chg(c);
  if (full) { $('hIcoWrap').innerHTML = icoHTML(c); $('hName').textContent = cname(c); $('hSym').textContent = `${c.lang === 'EN' ? '영문판' : '일판'} · ${c.set_code}`; }
  $('hPrice').textContent = fmt(roundT(p)); $('hPrice').className = 'big num ' + (ch >= 0 ? 'up' : 'down');
  $('hChg').textContent = `${ch >= 0 ? '+' : ''}${fmt(roundT(p) - roundT(num(c.day_ref) || p))} (${ch >= 0 ? '+' : ''}${ch.toFixed(2)}%) · 오늘 시가 대비`; $('hChg').className = 'num ' + (ch >= 0 ? 'up' : 'down');
  $('hBase').textContent = `${fmt(roundT(num(c.base_krw)))}${c.base_usd ? ` (≈ $${num(c.base_usd).toFixed(2)})` : ''}`;
  $('asof').textContent = c.base_asof ? '기준 ' + c.base_asof : '';
  drawChart(); drawPress(); drawLadder(); wallet(); ticket(); ledger(); rank();
}
function wallet() {
  const P = ME.player, e = num(ME.equity), inj = num(P.injected), r = (e / (inj || 1) - 1) * 100;
  $('wEq').textContent = fmt(e); $('wCash').textContent = fmt(P.cash); $('wInv').textContent = fmt(e - num(P.cash));
  $('wRet').textContent = (r >= 0 ? '+' : '') + r.toFixed(2) + '%'; $('wRet').className = 'num ' + (r >= 0 ? 'up' : 'down');
  $('meChip').textContent = `${P.name} · ${P.age_group}`;
  const can = e < num(CFG.start_cash) * num(CFG.refill_thr_pct) / 100, left = P.last_refill ? new Date(P.last_refill).getTime() + num(CFG.refill_cool_h) * 3600000 - Date.now() : 0;
  const rb = $('refillBtn'); rb.hidden = !can;
  if (can) { rb.disabled = left > 0; rb.textContent = left > 0 ? `재충전까지 ${Math.ceil(left / 3600000)}시간` : `파산 지원: ${fmt(CFG.refill_amount)}젬 재충전`; }
}
function css(v) { return getComputedStyle(document.documentElement).getPropertyValue(v).trim(); }
function sizeCanvas(cv) { const dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight; if (cv.width !== W * dpr || cv.height !== H * dpr) { cv.width = W * dpr; cv.height = H * dpr; } const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H); return [g, W, H]; }
function series() {
  let cs = CANDLES.slice();
  const p = price(sel), nowMin = Math.floor(Date.now() / 60000) * 60000;
  if (open() && p && cs.length) { const last = cs[cs.length - 1]; if (last.t === nowMin) { last.c = p; last.h = Math.max(last.h, p); last.l = Math.min(last.l, p); } }
  if (tf === 5) { const out = []; for (const k of cs) { const b = Math.floor(k.t / 300000) * 300000, l = out[out.length - 1]; if (l && l.t === b) { l.h = Math.max(l.h, k.h); l.l = Math.min(l.l, k.l); l.c = k.c; l.v += k.v; } else out.push({ ...k, t: b }); } cs = out; }
  return cs.slice(-100);
}
function drawChart() {
  const [g, W, H] = sizeCanvas($('chart')); if (!W) return;
  const cs = series(), UP = css('--up'), DN = css('--down'), LN = css('--line'), MU = css('--mute'), GM = css('--gem');
  g.font = '11px "IBM Plex Mono",monospace'; g.textBaseline = 'middle';
  if (cs.length < 2) { g.fillStyle = MU; g.textAlign = 'center'; g.fillText('차트 데이터를 모으는 중이에요. 장이 열려 있으면 1분 안에 첫 봉이 그려져요.', W / 2, H / 2); g.textAlign = 'left'; return; }
  const padR = 84, padB = 22, vH = 46, cw = (W - padR - 8) / cs.length;
  let hi = Math.max(...cs.map(x => x.h)), lo = Math.min(...cs.map(x => x.l)); const pad = (hi - lo) * 0.08 || hi * 0.01; hi += pad; lo -= pad;
  const top = 10, bot = H - padB - vH - 6, y = p => top + (hi - p) / (hi - lo) * (bot - top);
  g.textAlign = 'left';
  for (let i = 0; i <= 4; i++) { const p = lo + (hi - lo) * i / 4, yy = y(p); g.strokeStyle = LN; g.globalAlpha = .6; g.beginPath(); g.moveTo(0, yy); g.lineTo(W - padR, yy); g.stroke(); g.globalAlpha = 1; g.fillStyle = MU; g.fillText(fmt(roundT(p)), W - padR + 6, yy); }
  const vmax = Math.max(...cs.map(x => x.v)) || 1;
  cs.forEach((k, i) => { const x = 4 + i * cw + cw / 2, col = k.c >= k.o ? UP : DN; g.strokeStyle = col; g.fillStyle = col;
    g.beginPath(); g.moveTo(x, y(k.h)); g.lineTo(x, y(k.l)); g.stroke();
    const y0 = y(Math.max(k.o, k.c)), y1 = y(Math.min(k.o, k.c)); g.fillRect(x - cw * 0.35, y0, cw * 0.7, Math.max(1, y1 - y0));
    g.globalAlpha = .35; const vh = k.v / vmax * vH; g.fillRect(x - cw * 0.35, H - padB - vh, cw * 0.7, vh); g.globalAlpha = 1; });
  g.strokeStyle = GM; g.lineWidth = 1.5; g.beginPath(); let st = false;
  cs.forEach((k, i) => { if (i < 19) return; const m = cs.slice(i - 19, i + 1).reduce((a, x) => a + x.c, 0) / 20, x = 4 + i * cw + cw / 2; st ? g.lineTo(x, y(m)) : (g.moveTo(x, y(m)), st = true); }); g.stroke(); g.lineWidth = 1;
  const lp = cs[cs.length - 1].c, ly = y(lp), lc = lp >= cs[cs.length - 1].o ? UP : DN;
  g.setLineDash([3, 3]); g.strokeStyle = lc; g.beginPath(); g.moveTo(0, ly); g.lineTo(W - padR, ly); g.stroke(); g.setLineDash([]);
  g.fillStyle = lc; g.fillRect(W - padR + 2, ly - 9, padR - 4, 18); g.fillStyle = '#fff'; g.fillText(fmt(roundT(lp)), W - padR + 6, ly);
  for (const x of ME.positions.filter(x => x.sym === sel)) { const yy = y(num(x.entry)); if (yy < top || yy > bot) continue; g.strokeStyle = GM; g.setLineDash([6, 4]); g.beginPath(); g.moveTo(0, yy); g.lineTo(W - padR, yy); g.stroke(); g.setLineDash([]); g.fillStyle = GM; g.fillText(`${x.side === 'L' ? '롱' : '숏'} 진입 ${x.lev}x`, 6, yy - 9); }
  for (const o of ME.orders.filter(o => o.sym === sel && o.status === 'open')) { const yy = y(num(o.limit_price)); if (yy < top || yy > bot) continue; g.strokeStyle = o.side === 'buy' ? UP : DN; g.globalAlpha = .7; g.setLineDash([2, 4]); g.beginPath(); g.moveTo(0, yy); g.lineTo(W - padR, yy); g.stroke(); g.setLineDash([]); g.globalAlpha = 1; g.fillStyle = g.strokeStyle; g.fillText(`내 예약 ${o.side === 'buy' ? '매수' : '매도'}`, 6, yy - 9); }
  g.fillStyle = MU; g.fillText('MA20', 6, top + 6);
}
function drawPress() {
  const p = PEND[sel], b = num(p?.buy_value), v = num(p?.sell_value), tot = b + v;
  const br = tot ? Math.round(b / tot * 100) : 50;
  $('pbar').innerHTML = (br > 0 ? `<div class="b" style="width:${br}%">${br >= 12 ? '매수 ' + br + '%' : ''}</div>` : '') + (br < 100 ? `<div class="s" style="width:${100 - br}%">${100 - br >= 12 ? '매도 ' + (100 - br) + '%' : ''}</div>` : '');
  $('pBuy').textContent = fmt(b); $('pSell').textContent = fmt(v);
  $('pendN').textContent = p ? `${num(p.traders)}명 · ${num(p.buy_n) + num(p.sell_n)}건` : '';
  let txt = '대기 주문이 아직 없어요. 첫 예약 주문을 걸어 보세요.';
  if (tot) { const c = card(sel), gap = (b - v) / tot * Math.min(0.06, 0.01 + tot / (num(c.base_krw) * 200)) * 100;
    txt = open() ? `지금은 매수 대기 ${br}% · 가격이 예약 가격에 닿는 순간 체결돼요` : `예상 시가 방향: ${gap >= 0 ? '▲ 상승' : '▼ 하락'} 약 ${Math.abs(gap).toFixed(2)}% (지금 대기 주문 기준, 개장 때 달라질 수 있어요)`; }
  $('pExpect').textContent = txt;
}
function drawLadder() {
  const [g, W, H] = sizeCanvas($('ladder')); if (!W) return;
  const MU = css('--mute'), UP = css('--up'), DN = css('--down'), GM = css('--gem');
  g.font = '11px "IBM Plex Mono",monospace'; g.textBaseline = 'middle';
  if (!LADDER.length) { g.fillStyle = MU; g.textAlign = 'center'; g.fillText('아직 이 카드에 걸린 예약 주문이 없어요', W / 2, H / 2); g.textAlign = 'left'; return; }
  const rows = LADDER.slice(0, 12), mx = Math.max(...rows.map(r => Math.max(num(r.buy_qty), num(r.sell_qty)))) || 1;
  const rh = Math.min(22, (H - 12) / rows.length), mid = W / 2, lab = 96, half = (W - lab) / 2 - 52, p = price(sel);
  rows.forEach((r, i) => { const yy = 6 + i * rh + rh / 2, bq = num(r.buy_qty), sq = num(r.sell_qty);
    g.fillStyle = UP; g.globalAlpha = .75; g.fillRect(mid - lab / 2 - bq / mx * half, yy - rh * 0.35, bq / mx * half, rh * 0.7);
    g.fillStyle = DN; g.fillRect(mid + lab / 2, yy - rh * 0.35, sq / mx * half, rh * 0.7); g.globalAlpha = 1;
    g.fillStyle = Math.abs(num(r.price) - p) / p < 0.01 ? GM : MU; g.textAlign = 'center'; g.fillText(fmt(r.price), mid, yy);
    g.textAlign = 'left'; g.fillStyle = MU; if (bq) g.fillText(bq.toFixed(2), 4, yy); g.textAlign = 'right'; if (sq) g.fillText(sq.toFixed(2), W - 4, yy); });
  g.textAlign = 'left';
}
function ticket() {
  const p = price(sel), q = num($('qty').value);
  $('spotEst').textContent = fmt(q * p * (1 + fee())) + ' 젬';
  const h = ME.holdings.find(x => x.sym === sel); $('spotHave').textContent = fmt(h?.qty || 0, 3) + ' 장';
  $('lev').max = CFG.max_lev; if (+$('lev').value > CFG.max_lev) $('lev').value = CFG.max_lev;
  const m = num(String($('margin').value).replace(/,/g, '')), lev = +$('lev').value;
  $('levV').textContent = lev + 'x'; $('futSize').textContent = fmt(m * lev) + ' 젬';
  $('futLiq').textContent = `${fmt(roundT(p * (1 - 0.9 / lev)))} / ${fmt(roundT(p * (1 + 0.9 / lev)))}`;
  if (!$('rPrice').value || $('rPrice').dataset.sym !== sel) { $('rPrice').value = roundT(p); $('rPrice').dataset.sym = sel; }
  const rp = num($('rPrice').value), rq = num($('rQty').value);
  $('rEstK').textContent = rside === 'buy' ? '묶이는 젬 (수수료 포함)' : '묶이는 카드';
  $('rEst').textContent = rside === 'buy' ? fmt(rq * rp * (1 + fee())) + ' 젬' : fmt(rq, 3) + ' 장';
}
function ledger() {
  let h = ''; const tm = d => new Date(d).toLocaleString('ko-KR', { hour12: false, month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  if (tab === 'hold') {
    const rows = ME.holdings.filter(x => card(x.sym));
    if (!rows.length) h = '<div class="empty">아직 보유한 카드가 없어요. 오른쪽 주문창에서 첫 매수를 해 보세요.</div>';
    else { h = '<table><thead><tr><th>카드</th><th>수량</th><th>평균 단가</th><th>현재가</th><th>평가 금액</th><th>평가 손익</th></tr></thead><tbody>';
      for (const x of rows) { const c = card(x.sym), p = num(c.price), q = num(x.qty), a = num(x.avg), pl = (p - a) * q, pr = (p / a - 1) * 100;
        h += `<tr><td>${esc(cname(c))} <small style="color:var(--dim)">${c.lang}</small></td><td class="num">${fmt(q, 3)}</td><td class="num">${fmt(a)}</td><td class="num">${fmt(roundT(p))}</td><td class="num">${fmt(q * p)}</td><td class="num ${pl >= 0 ? 'up' : 'down'}">${pl >= 0 ? '+' : ''}${fmt(pl)} (${pr >= 0 ? '+' : ''}${pr.toFixed(2)}%)</td></tr>`; }
      h += '</tbody></table>'; }
  } else if (tab === 'pos') {
    if (!ME.positions.length) h = '<div class="empty">열린 선물 포지션이 없어요.</div>';
    else { h = '<table><thead><tr><th>포지션</th><th>진입가</th><th>현재가</th><th>청산가</th><th>증거금</th><th>손익 (ROE)</th><th></th></tr></thead><tbody>';
      for (const x of ME.positions) { const c = card(x.sym), p = num(c.price), pl = (x.side === 'L' ? 1 : -1) * (p - num(x.entry)) * num(x.qty), roe = pl / num(x.margin) * 100;
        h += `<tr><td><span class="pill ${x.side === 'L' ? 'l' : 's'}">${x.side === 'L' ? '롱' : '숏'} ${x.lev}x</span>${esc(cname(c))} <small style="color:var(--dim)">${c.lang}</small></td><td class="num">${fmt(roundT(num(x.entry)))}</td><td class="num">${fmt(roundT(p))}</td><td class="num" style="color:var(--warn)">${fmt(roundT(num(x.liq)))}</td><td class="num">${fmt(x.margin)}</td><td class="num ${pl >= 0 ? 'up' : 'down'}">${pl >= 0 ? '+' : ''}${fmt(pl)} (${roe >= 0 ? '+' : ''}${roe.toFixed(1)}%)</td><td><button class="mini" data-close="${x.id}" ${open() ? '' : 'disabled'}>정리</button></td></tr>`; }
      h += '</tbody></table>'; }
  } else if (tab === 'ord') {
    if (!ME.orders.length) h = '<div class="empty">예약 주문이 없어요. 주문창의 "예약" 탭에서 걸 수 있어요.</div>';
    else { h = '<table><thead><tr><th>카드</th><th>구분</th><th>예약 가격</th><th>수량</th><th>상태</th><th>등록</th><th></th></tr></thead><tbody>';
      for (const o of ME.orders) { const c = card(o.sym); const stt = o.status === 'open' ? '<span class="pill w">대기</span>' : o.status === 'filled' ? `<span class="pill k">체결 ${fmt(roundT(num(o.fill_price)))}</span>` : '<span class="pill">취소</span>';
        h += `<tr><td>${c ? esc(cname(c)) : '-'}</td><td><span class="pill ${o.side === 'buy' ? 'l' : 's'}">${o.side === 'buy' ? '매수' : '매도'}</span></td><td class="num">${fmt(o.limit_price)}</td><td class="num">${fmt(o.qty, 3)}</td><td>${stt}</td><td class="num" style="color:var(--dim)">${tm(o.created_at)}</td><td>${o.status === 'open' ? `<button class="mini" data-cancel="${o.id}">취소</button>` : ''}</td></tr>`; }
      h += '</tbody></table>'; }
  } else {
    if (!ME.history.length) h = '<div class="empty">거래 내역이 없어요.</div>';
    else { h = '<table><thead><tr><th>카드</th><th>구분</th><th>수량</th><th>가격</th><th>금액</th><th>시각</th></tr></thead><tbody>';
      for (const x of ME.history) { const c = x.sym ? card(x.sym) : null, a = num(x.amount);
        h += `<tr><td>${c ? esc(cname(c)) : '-'}</td><td>${esc(x.what)}</td><td class="num">${x.qty ? fmt(x.qty, 3) : '-'}</td><td class="num">${x.price ? fmt(roundT(num(x.price))) : '-'}</td><td class="num ${a >= 0 ? 'up' : 'down'}">${a >= 0 ? '+' : ''}${fmt(a)}</td><td class="num" style="color:var(--dim)">${tm(x.at)}</td></tr>`; }
      h += '</tbody></table>'; }
  }
  const el = $('ledger'); if (el.dataset.h !== h) { el.innerHTML = h; el.dataset.h = h;
    el.querySelectorAll('[data-close]').forEach(b => b.onclick = () => act('close_position', { p_id: +b.dataset.close }, d => `포지션 정리 · 손익 ${num(d.pnl) >= 0 ? '+' : ''}${fmt(d.pnl)}젬`));
    el.querySelectorAll('[data-cancel]').forEach(b => b.onclick = () => act('cancel_order', { p_id: +b.dataset.cancel }, '예약 주문을 취소했어요')); }
}
function rank() {
  $('rankMode').textContent = `참가자 ${LB.length}명`;
  const html = LB.slice(0, 30).map(x => { const r = num(x.profit) / num(x.injected) * 100;
    return `<li class="${x.is_me ? 'me' : ''}"><span class="no">${x.rank}</span><span class="who">${x.is_me ? '<b>' : ''}${esc(x.name)}${x.is_me ? ' (나)</b>' : ''}<small>${esc(x.age_group)}${x.refills ? ` · 재충전 ${x.refills}회` : ''}</small></span><span class="num ${num(x.profit) >= 0 ? 'up' : 'down'}">${num(x.profit) >= 0 ? '+' : ''}${fmt(x.profit)}</span><span class="num ${r >= 0 ? 'up' : 'down'}" style="min-width:64px;text-align:right">${r >= 0 ? '+' : ''}${r.toFixed(2)}%</span></li>`; }).join('') || '<li style="grid-template-columns:1fr;color:var(--dim)">아직 참가자가 없어요.</li>';
  const me = LB.find(x => x.is_me);
  const extra = me && me.rank > 30 ? `<li class="me"><span class="no">${me.rank}</span><span class="who"><b>${esc(me.name)} (나)</b></span><span class="num">${fmt(me.profit)}</span><span></span></li>` : '';
  if ($('rank').dataset.h !== html + extra) { $('rank').innerHTML = html + extra; $('rank').dataset.h = html + extra; }
}

/* ---------------- actions ---------------- */
const q3 = v => Math.floor(num(v) * 1000) / 1000;
$('bBuy').onclick = () => act('buy', { p_sym: sel, p_qty: q3($('qty').value) }, d => `${cname(card(sel))} 매수 · ${fmt(d.price)}젬`);
$('bSell').onclick = () => act('sell', { p_sym: sel, p_qty: q3($('qty').value) }, d => `${cname(card(sel))} 매도 · +${fmt(d.total)}젬`);
const openPos = side => act('open_position', { p_sym: sel, p_side: side, p_margin: Math.floor(num(String($('margin').value).replace(/,/g, ''))), p_lev: +$('lev').value }, d => { tab = 'pos'; setTab(); return `${side === 'L' ? '롱' : '숏'} 진입 · 청산가 ${fmt(roundT(num(d.liq)))}`; });
$('bLong').onclick = () => openPos('L'); $('bShort').onclick = () => openPos('S');
$('rGo').onclick = () => act('place_order', { p_sym: sel, p_side: rside, p_qty: q3($('rQty').value), p_price: Math.round(num($('rPrice').value)) }, () => { tab = 'ord'; setTab(); return `예약 ${rside === 'buy' ? '매수' : '매도'} 주문을 걸었어요`; });
$('refillBtn').onclick = () => act('refill', {}, d => `${fmt(d.amount)}젬을 재충전했어요. 랭킹은 순수익 기준이라 재충전 젬은 수익으로 치지 않아요.`);
$('reset').onclick = () => armed($('reset'), '한 번 더 누르면 초기화돼요', () => act('reset_me', {}, '시작 젬으로 새로 시작했어요'));

function setMode(m) { mode = m; for (const [id, k] of [['mSpot', 'spot'], ['mFut', 'fut'], ['mRes', 'res']]) $(id).setAttribute('aria-pressed', m === k); $('spotForm').hidden = m !== 'spot'; $('futForm').hidden = m !== 'fut'; $('resForm').hidden = m !== 'res'; }
function setTab() { document.querySelectorAll('[data-tab]').forEach(b => b.setAttribute('aria-pressed', b.dataset.tab === tab)); $('ledger').dataset.h = ''; }
$('mSpot').onclick = () => setMode('spot'); $('mFut').onclick = () => setMode('fut'); $('mRes').onclick = () => setMode('res');
$('rBuy').onclick = () => { rside = 'buy'; $('rBuy').setAttribute('aria-pressed', 'true'); $('rSell').setAttribute('aria-pressed', 'false'); ticket(); };
$('rSell').onclick = () => { rside = 'sell'; $('rSell').setAttribute('aria-pressed', 'true'); $('rBuy').setAttribute('aria-pressed', 'false'); ticket(); };
document.querySelectorAll('[data-tab]').forEach(b => b.onclick = () => { tab = b.dataset.tab; setTab(); ledger(); });
document.querySelectorAll('[data-f]').forEach(b => b.onclick = () => { filt = b.dataset.f; document.querySelectorAll('[data-f]').forEach(x => x.setAttribute('aria-pressed', x === b)); buildRail(); render(); });
document.querySelectorAll('[data-pq]').forEach(b => b.onclick = () => { const p = price(sel) * 1.001 * (1 + fee()); $('qty').value = q3(num(ME.player.cash) * +b.dataset.pq / p); ticket(); });
document.querySelectorAll('[data-pm]').forEach(b => b.onclick = () => { $('margin').value = Math.floor(num(ME.player.cash) * +b.dataset.pm / (1 + (+$('lev').value) * fee())); ticket(); });
document.querySelectorAll('[data-rp]').forEach(b => b.onclick = () => { $('rPrice').value = roundT(price(sel) * (1 + +b.dataset.rp)); ticket(); });
['qty', 'margin', 'lev', 'rPrice', 'rQty'].forEach(id => $(id).addEventListener('input', ticket));
$('tf1').onclick = () => { tf = 1; $('tf1').setAttribute('aria-pressed', 'true'); $('tf5').setAttribute('aria-pressed', 'false'); drawChart(); };
$('tf5').onclick = () => { tf = 5; $('tf5').setAttribute('aria-pressed', 'true'); $('tf1').setAttribute('aria-pressed', 'false'); drawChart(); };
window.addEventListener('resize', () => { drawChart(); drawLadder(); });

/* ---------------- home-screen shortcut ---------------- */
let deferred = null;
const standalone = () => matchMedia('(display-mode: standalone)').matches || navigator.standalone;
function installUI() {
  let dismissed = false; try { dismissed = localStorage.getItem('gem-install-off') === '1'; } catch (e) {}
  if (standalone() || dismissed) return;
  const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
  $('installHow').textContent = ios ? 'Safari 아래쪽 공유 버튼 → "홈 화면에 추가"를 눌러 주세요.' : '브라우저 메뉴(⋮) → "홈 화면에 추가" 또는 "앱 설치"를 눌러 주세요.';
  $('install').hidden = false;
}
window.addEventListener('beforeinstallprompt', e => { e.preventDefault(); deferred = e; $('installBtn').hidden = false; });
$('installBtn').onclick = async () => { if (!deferred) return; deferred.prompt(); await deferred.userChoice; deferred = null; $('install').hidden = true; };
$('installClose').onclick = () => { $('install').hidden = true; try { localStorage.setItem('gem-install-off', '1'); } catch (e) {} };

/* ---------------- boot ---------------- */
$('gGo').onclick = async () => {
  const name = $('gName').value.trim(), age = parseInt($('gAge').value, 10), err = $('gErr');
  if (name.length < 2) return err.textContent = '닉네임은 2~12자로 정해 주세요.';
  if (!(age >= 1 && age <= 120)) return err.textContent = '나이를 숫자로 입력해 주세요.';
  if (age < 14) return err.textContent = '만 14세 미만은 보호자 동의가 필요해서 지금은 가입할 수 없어요.';
  if (!$('gOk').checked) return err.textContent = '가상 화폐 안내에 동의해 주세요.';
  $('gGo').disabled = true;
  const r = await sb.rpc('join_game', { p_name: name, p_age: age });
  $('gGo').disabled = false;
  if (r.error) return err.textContent = errMsg(r.error);
  err.textContent = ''; await loadMe(); start();
};
function start() {
  $('loading').hidden = true; $('gate').hidden = true; $('app').hidden = false;
  if (!open()) setMode('res');
  buildRail(); render(true); installUI();
  Promise.all([loadCandles(), loadPend(), loadLB()]).then(() => render());
  sb.rpc('is_admin').then(r => { if (r.data === true) $('opLink').hidden = false; });
}
async function boot() {
  if (!sb) { $('loading').textContent = 'config.js에 Supabase 주소와 anon key를 넣어 주세요.'; return; }
  try { await GEM.ensureSession(sb); }
  catch (e) { $('loading').textContent = '접속하지 못했어요. Supabase에서 익명 로그인(Anonymous sign-ins)을 켰는지 확인해 주세요.'; return; }
  await loadMarket();
  if (!CARDS.length) { $('loading').textContent = '종목 데이터가 없어요. supabase.sql을 실행했는지 확인해 주세요.'; return; }
  await loadMe();
  if (ME) start(); else { $('loading').hidden = true; $('gate').hidden = false; $('gName').focus(); }
  setInterval(async () => { if (document.hidden) return; await Promise.all([loadMarket(), ME ? loadMe() : null]); if (ME && !$('app').hidden) render(); }, 5000);
  setInterval(async () => { if (document.hidden || !ME) return; await loadPend(); render(); }, 10000);
  setInterval(async () => { if (document.hidden || !ME) return; await Promise.all([loadCandles(), loadLB()]); render(); }, 20000);
  setInterval(() => { if (!ME || $('app').hidden) return; const o = open(); if (wasOpen !== null && o !== wasOpen) { toast(o ? '장이 열렸어요!' : '장이 마감됐어요. 예약 주문만 받아요.'); loadMarket().then(loadMe).then(() => render()); } wasOpen = o; $('countdown').textContent = '개장까지 ' + hms(secsToSwitch(CFG)); }, 1000);
}
boot();
})();
