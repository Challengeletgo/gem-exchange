(function () {
const { $, num, fmt, roundT, esc, cname, isOpen, toast, errMsg, armed } = GEM;
const sb = GEM.client();
let CFG = null, CARDS = [], OV = null, builtPrices = false;

async function load() {
  const [c, g, o] = await Promise.all([sb.from('cards').select('*').order('sort'), sb.from('config').select('*').eq('id', 1).single(), sb.rpc('admin_overview')]);
  if (o.error) throw o.error;
  CARDS = c.data || []; CFG = g.data; OV = o.data;
}
function render() {
  const st = $('mStatus'), o = isOpen(CFG); st.className = 'status ' + (o ? 'open' : 'closed'); st.querySelector('span').textContent = o ? '장 운영 중' : '장 마감';
  const ps = OV.players || [];
  $('oCount').textContent = fmt(ps.length);
  $('oOrders').textContent = `${fmt(OV.open_orders)} · ${fmt(OV.positions)}`;
  $('oRefill').textContent = fmt(ps.reduce((a, x) => a + num(x.refills), 0));
  $('oTotal').textContent = fmt(ps.reduce((a, x) => a + num(x.equity), 0));
  $('tokenState').textContent = OV.token_set ? '토큰이 설정되어 있어요.' : '아직 토큰이 없어요. 예약 작업을 쓰려면 새 토큰을 만들어 주세요.';
  const groups = ['10대', '20대', '30대', '40대', '50대 이상'], cnt = groups.map(g => ps.filter(x => x.age_group === g).length), mx = Math.max(1, ...cnt);
  $('oAges').innerHTML = groups.map((g, i) => `<div><span>${g}</span><i style="width:${cnt[i] / mx * 100}%"></i><span class="num">${cnt[i]}</span></div>`).join('');
  const tb = $('oPrices');
  if (!builtPrices) {
    tb.innerHTML = CARDS.map(c => `<tr><td class="num">${esc(c.sym)}</td><td>${esc(cname(c))} <small style="color:var(--dim)">${c.lang} · ${esc(c.set_code)}</small></td><td><input class="cell" data-usd="${esc(c.sym)}" inputmode="decimal" value="${num(c.base_usd) || ''}" aria-label="${esc(c.sym)} USD"></td><td><input class="cell" data-krw="${esc(c.sym)}" inputmode="numeric" value="${Math.round(num(c.base_krw))}" aria-label="${esc(c.sym)} 기준가"></td><td class="num" data-now="${esc(c.sym)}"></td><td class="num">${OV.pop && OV.pop[c.sym] != null ? fmt(OV.pop[c.sym]) : '-'}</td><td class="num" style="color:var(--dim)">${esc(c.base_asof || '')}</td></tr>`).join('');
    builtPrices = true; fillCfg();
  }
  for (const c of CARDS) { const td = tb.querySelector(`[data-now="${c.sym}"]`); if (td) td.textContent = fmt(roundT(num(c.price))); }
  const rows = ps.map(x => { const pr = num(x.equity) - num(x.injected);
    return `<tr><td>${esc(x.name)}</td><td>${esc(x.age_group)}</td><td class="num">${new Date(x.joined_at).toLocaleDateString('ko-KR')}</td><td class="num">${fmt(x.equity)}</td><td class="num ${pr >= 0 ? 'up' : 'down'}">${pr >= 0 ? '+' : ''}${fmt(pr)}</td><td class="num">${x.refills}</td><td>${x.banned ? '<span class="pill s">정지</span>' : '<span class="pill k">정상</span>'}</td><td><input class="cell" data-bonus="${x.id}" inputmode="numeric" placeholder="젬" aria-label="보너스 젬"> <button class="mini" data-give="${x.id}">지급</button></td><td><button class="mini" data-ban="${x.id}" data-b="${x.banned ? 0 : 1}">${x.banned ? '정지 해제' : '거래 정지'}</button> <button class="mini danger" data-wipe="${x.id}">초기화</button></td></tr>`; }).join('') || '<tr><td colspan="9" class="empty">아직 참가자가 없어요.</td></tr>';
  const ub = $('oUsers'); if (ub.dataset.h !== rows && !ub.contains(document.activeElement)) { ub.innerHTML = rows; ub.dataset.h = rows; wire(); }
}
function fillCfg() {
  $('cSeason').value = CFG.season; $('cStart').value = num(CFG.start_cash); $('cRefill').value = num(CFG.refill_amount); $('cThr').value = num(CFG.refill_thr_pct);
  $('cCool').value = num(CFG.refill_cool_h); $('cLev').value = CFG.max_lev; $('cFee').value = num(CFG.fee_pct); $('cCs').value = CFG.close_start_h; $('cCe').value = CFG.close_end_h;
  $('cMax').value = CFG.max_open_orders; $('cNotice').value = CFG.notice; $('cDaily').value = num(CFG.daily_bonus); $('cWhale').value = num(CFG.whale_threshold);
}
async function call(fn, args, ok) { const r = await sb.rpc(fn, args); if (r.error) { toast(errMsg(r.error)); return false; } await load(); render(); if (ok) toast(ok); return true; }
function wire() {
  const ub = $('oUsers');
  ub.querySelectorAll('[data-give]').forEach(b => b.onclick = () => { const id = b.dataset.give, amt = Math.floor(num(ub.querySelector(`[data-bonus="${id}"]`).value)); if (!amt) return toast('지급할 젬을 입력해 주세요.'); call('admin_bonus', { p_id: id, p_amount: amt, p_as_profit: false }, `${fmt(amt)}젬을 지급했어요`); });
  ub.querySelectorAll('[data-ban]').forEach(b => b.onclick = () => call('admin_ban', { p_id: b.dataset.ban, p_banned: b.dataset.b === '1' }, b.dataset.b === '1' ? '거래를 정지했어요' : '정지를 해제했어요'));
  ub.querySelectorAll('[data-wipe]').forEach(b => b.onclick = () => armed(b, '한 번 더', () => call('admin_reset_player', { p_id: b.dataset.wipe }, '계정을 초기화했어요')));
}
$('fxApply').onclick = () => { const fx = num($('fx').value); if (!fx) return toast('환율을 입력해 주세요.'); document.querySelectorAll('[data-usd]').forEach(i => { const u = num(i.value); if (u) document.querySelector(`[data-krw="${i.dataset.usd}"]`).value = Math.round(u * fx); }); };
$('oSavePrices').onclick = () => {
  const p = {}; for (const c of CARDS) { const k = num(document.querySelector(`[data-krw="${c.sym}"]`).value), u = num(document.querySelector(`[data-usd="${c.sym}"]`).value); if (k > 0) p[c.sym] = { krw: Math.round(k), usd: u || null }; }
  call('set_base_prices', { p_token: null, p_prices: p, p_note: '운영자 수정', p_asof: new Date().toISOString().slice(0, 10) }, '기준가를 저장했어요').then(ok => { if (ok) builtPrices = false; });
};
$('oSaveCfg').onclick = () => {
  const n = id => num(String($(id).value).replace(/,/g, ''));
  call('admin_set_config', { p: { season: $('cSeason').value.trim() || '시즌 1', start_cash: n('cStart'), refill_amount: n('cRefill'), refill_thr_pct: n('cThr'), refill_cool_h: n('cCool'), max_lev: n('cLev'), fee_pct: n('cFee'), close_start_h: n('cCs'), close_end_h: n('cCe'), max_open_orders: n('cMax'), daily_bonus: n('cDaily'), whale_threshold: n('cWhale'), notice: $('cNotice').value.trim() } }, '설정을 저장했어요').then(ok => { if (ok) fillCfg(); });
};
$('gAll').onclick = () => { const amt = Math.floor(num(String($('gAmt').value).replace(/,/g, ''))); if (!(amt > 0)) return toast('지급할 젬을 입력해 주세요.');
  armed($('gAll'), `1인당 ${fmt(amt)}젬, 한 번 더 누르면 지급해요`, () => call('admin_gift_all', { p_amount: amt, p_note: $('gNote').value.trim() || null, p_as_profit: $('gProfit').checked }, `전원에게 ${fmt(amt)}젬을 지급했어요`)); };
$('oSeasonReset').onclick = () => armed($('oSeasonReset'), '정말 전원 초기화? 한 번 더', () => call('admin_season_reset', { p_season: $('newSeason').value.trim() || null }, '모든 참가자를 새 시즌으로 초기화했어요'));
$('tokenNew').onclick = () => armed($('tokenNew'), '이전 토큰이 끊겨요. 한 번 더', async () => {
  const a = new Uint8Array(24); crypto.getRandomValues(a); const t = 'gem_' + Array.from(a, x => x.toString(16).padStart(2, '0')).join('');
  if (await call('admin_set_price_token', { p_token: t }, '새 토큰을 만들었어요. 지금 한 번만 보여요.')) { $('tokenVal').value = t; $('tokenBox').hidden = false; }
});
$('tokenCopy').onclick = async () => { try { await navigator.clipboard.writeText($('tokenVal').value); toast('복사했어요'); } catch (e) { $('tokenVal').select(); } };

(async function boot() {
  if (!sb) { $('loading').textContent = 'config.js에 Supabase 주소와 anon key를 넣어 주세요.'; return; }
  try { await GEM.ensureSession(sb); await load(); }
  catch (e) {
    const { data } = await sb.auth.getSession(); const id = data.session?.user?.id || '';
    $('loading').innerHTML = `${esc(errMsg(e))}<br><br>이 기기를 운영자로 등록하려면 아래 계정 ID를 안내서의 "운영자 등록" SQL에 넣어 실행해 주세요.<br><code style="user-select:all;color:var(--gem2);word-break:break-all">${esc(id)}</code>`;
    return; }
  $('loading').hidden = true; $('app').hidden = false; render();
  setInterval(async () => { if (document.hidden) return; try { await load(); render(); } catch (e) {} }, 10000);
})();
})();
