-- =====================================================================
--  젬 거래소 · Supabase 서버 설정 (SQL Editor에 통째로 붙여넣고 Run)
--  - 모든 거래는 서버 함수(RPC)에서만 처리돼요. 브라우저에서 잔고를 고칠 수 없어요.
--  - 매일 00:00~08:00(한국 시간)은 장 마감: 가격이 멈추고 즉시 거래가 막혀요.
--  - 장 마감 중에는 예약 주문만 받고, 08:00 첫 틱에서 동시호가로 시가가 정해져요.
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- 설정 ----------
create table if not exists public.config (
  id int primary key default 1 check (id = 1),
  season text not null default '시즌 1',
  start_cash numeric not null default 1000000,
  refill_amount numeric not null default 1000000,
  refill_thr_pct numeric not null default 10,
  refill_cool_h numeric not null default 24,
  max_lev int not null default 20,
  fee_pct numeric not null default 0.05,
  notice text not null default '',
  close_start_h int not null default 0,   -- 한국 시간, 이 시각부터
  close_end_h int not null default 8,     -- 이 시각 전까지 장 마감
  max_open_orders int not null default 20
);
insert into public.config default values on conflict do nothing;

create table if not exists public.private_settings (
  id int primary key default 1 check (id = 1),
  price_token_hash text
);
insert into public.private_settings default values on conflict do nothing;

create table if not exists public.admins (user_id uuid primary key);

-- ---------- 시장 ----------
create table if not exists public.cards (
  sym text primary key,
  name text not null, rarity text not null, lang text not null, set_code text not null,
  ptype text not null, vol numeric not null default 1, sort int not null default 0,
  base_krw numeric not null, base_usd numeric, base_asof date, base_note text,
  prev_base numeric, base_updated_at timestamptz not null default now(),
  price numeric not null, day_ref numeric,
  flow numeric not null default 0, shock numeric not null default 0, shock_ticks int not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists public.candles (
  sym text references public.cards on delete cascade, t timestamptz,
  o numeric, h numeric, l numeric, c numeric, v numeric not null default 0,
  primary key (sym, t)
);
create table if not exists public.news (
  id bigserial primary key, sym text, up boolean, mag numeric, body text not null, at timestamptz not null default now()
);
create table if not exists public.market_state (
  id int primary key default 1 check (id = 1), last_open_date date, is_open boolean not null default false, last_tick timestamptz
);
insert into public.market_state default values on conflict do nothing;

-- ---------- 참가자 ----------
create table if not exists public.players (
  id uuid primary key references auth.users on delete cascade,
  name text unique not null, age_group text not null,
  cash numeric not null, injected numeric not null,
  refills int not null default 0, last_refill timestamptz, bonus numeric not null default 0,
  banned boolean not null default false, season text, joined_at timestamptz not null default now()
);
create table if not exists public.holdings (
  player_id uuid references public.players on delete cascade, sym text references public.cards,
  qty numeric not null, avg numeric not null, primary key (player_id, sym)
);
create table if not exists public.positions (
  id bigserial primary key, player_id uuid references public.players on delete cascade, sym text references public.cards,
  side text not null check (side in ('L','S')), entry numeric not null, qty numeric not null,
  margin numeric not null, lev int not null, liq numeric not null, opened_at timestamptz not null default now()
);
create table if not exists public.orders (
  id bigserial primary key, player_id uuid references public.players on delete cascade, sym text references public.cards,
  side text not null check (side in ('buy','sell')), qty numeric not null, limit_price numeric not null,
  reserved numeric not null default 0, status text not null default 'open',
  created_at timestamptz not null default now(), done_at timestamptz, fill_price numeric
);
create index if not exists orders_open_idx on public.orders (sym, status);
create table if not exists public.history (
  id bigserial primary key, player_id uuid references public.players on delete cascade,
  sym text, what text not null, qty numeric, price numeric, amount numeric, at timestamptz not null default now()
);
create index if not exists history_player_idx on public.history (player_id, at desc);

-- ---------- 읽기 권한 (쓰기는 전부 함수로만) ----------
alter table public.config enable row level security;
alter table public.private_settings enable row level security;
alter table public.admins enable row level security;
alter table public.cards enable row level security;
alter table public.candles enable row level security;
alter table public.news enable row level security;
alter table public.market_state enable row level security;
alter table public.players enable row level security;
alter table public.holdings enable row level security;
alter table public.positions enable row level security;
alter table public.orders enable row level security;
alter table public.history enable row level security;
drop policy if exists r on public.config;        create policy r on public.config for select using (true);
drop policy if exists r on public.cards;         create policy r on public.cards for select using (true);
drop policy if exists r on public.candles;       create policy r on public.candles for select using (true);
drop policy if exists r on public.news;          create policy r on public.news for select using (true);
drop policy if exists r on public.market_state;  create policy r on public.market_state for select using (true);
drop policy if exists r on public.players;       create policy r on public.players for select using (id = auth.uid());
drop policy if exists r on public.holdings;      create policy r on public.holdings for select using (player_id = auth.uid());
drop policy if exists r on public.positions;     create policy r on public.positions for select using (player_id = auth.uid());
drop policy if exists r on public.orders;        create policy r on public.orders for select using (player_id = auth.uid());
drop policy if exists r on public.history;       create policy r on public.history for select using (player_id = auth.uid());

-- ---------- 공통 도우미 ----------
create or replace function public.kst_hour(ts timestamptz default now()) returns int
language sql stable as $$ select extract(hour from ts at time zone 'Asia/Seoul')::int $$;

create or replace function public.market_open(ts timestamptz default now()) returns boolean
language sql stable set search_path = public as $$
  select case when c.close_start_h <= c.close_end_h
              then not (kst_hour(ts) >= c.close_start_h and kst_hour(ts) < c.close_end_h)
              else not (kst_hour(ts) >= c.close_start_h or kst_hour(ts) < c.close_end_h) end
  from config c where c.id = 1 $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid()) $$;

create or replace function public._fee() returns numeric
language sql stable set search_path = public as $$ select fee_pct / 100 from config where id = 1 $$;

create or replace function public._gauss() returns double precision
language sql volatile as $$ select sqrt(-2 * ln(greatest(random(), 1e-12))) * cos(2 * pi() * random()) $$;

create or replace function public._base_now(c public.cards) returns numeric
language sql stable as $$
  select case when c.prev_base is null then c.base_krw
              else c.prev_base + (c.base_krw - c.prev_base) * least(1, greatest(0, extract(epoch from now() - c.base_updated_at) / 3600)) end $$;

create or replace function public._trader() returns public.players
language plpgsql security definer set search_path = public as $$
declare pl players;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  select * into pl from players where id = auth.uid() for update;
  if not found then raise exception '가입이 필요해요'; end if;
  if pl.banned then raise exception '운영자에 의해 거래가 정지된 계정이에요'; end if;
  return pl;
end $$;

create or replace function public._need_open() returns void
language plpgsql stable set search_path = public as $$
declare a int; b int;
begin
  if not market_open() then
    select close_start_h, close_end_h into a, b from config where id = 1;
    raise exception '%', format('장 마감 시간(%s:00~%s:00)이에요. 예약 주문을 이용해 주세요', lpad(a::text, 2, '0'), lpad(b::text, 2, '0'));
  end if;
end $$;

create or replace function public.player_equity(pid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select p.cash
    + coalesce((select sum(h.qty * c.price) from holdings h join cards c using (sym) where h.player_id = pid), 0)
    + coalesce((select sum(greatest(0, po.margin + (case when po.side = 'L' then 1 else -1 end) * (c.price - po.entry) * po.qty))
                from positions po join cards c using (sym) where po.player_id = pid), 0)
    + coalesce((select sum(o.reserved) from orders o where o.player_id = pid and o.status = 'open' and o.side = 'buy'), 0)
    + coalesce((select sum(o.qty * c.price) from orders o join cards c using (sym) where o.player_id = pid and o.status = 'open' and o.side = 'sell'), 0)
  from players p where p.id = pid $$;

-- ---------- 가입 ----------
create or replace function public.join_game(p_name text, p_age int) returns void
language plpgsql security definer set search_path = public as $$
declare cfg config; g text; nm text := trim(p_name);
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from players where id = auth.uid()) then raise exception '이미 가입했어요'; end if;
  if p_age is null or p_age < 1 or p_age > 120 then raise exception '나이를 확인해 주세요'; end if;
  if p_age < 14 then raise exception '만 14세 미만은 보호자 동의가 필요해서 가입할 수 없어요'; end if;
  if nm !~ '^[0-9A-Za-z가-힣_ .-]{2,12}$' then raise exception '닉네임은 한글·영문·숫자 2~12자로 정해 주세요'; end if;
  if exists (select 1 from players where lower(name) = lower(nm)) then raise exception '이미 쓰고 있는 닉네임이에요'; end if;
  select * into cfg from config where id = 1;
  g := case when p_age < 20 then '10대' when p_age < 30 then '20대' when p_age < 40 then '30대' when p_age < 50 then '40대' else '50대 이상' end;
  insert into players (id, name, age_group, cash, injected, season) values (auth.uid(), nm, g, cfg.start_cash, cfg.start_cash, cfg.season);
  insert into history (player_id, what, amount) values (auth.uid(), '가입 지급', cfg.start_cash);
end $$;

-- ---------- 현물 ----------
create or replace function public.buy(p_sym text, p_qty numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; c cards; fill numeric; total numeric; q numeric := trunc(p_qty, 3);
begin
  pl := _trader(); perform _need_open();
  if q is null or q <= 0 then raise exception '수량을 확인해 주세요'; end if;
  select * into c from cards where sym = p_sym for update;
  if not found then raise exception '없는 종목이에요'; end if;
  fill := c.price * 1.001; total := q * fill * (1 + _fee());
  if total > pl.cash then raise exception '젬이 부족해요'; end if;
  update players set cash = cash - total where id = pl.id;
  insert into holdings values (pl.id, p_sym, q, fill)
    on conflict (player_id, sym) do update set avg = (holdings.avg * holdings.qty + excluded.avg * excluded.qty) / (holdings.qty + excluded.qty), qty = holdings.qty + excluded.qty;
  update cards set flow = flow + q * fill where sym = p_sym;
  insert into history (player_id, sym, what, qty, price, amount) values (pl.id, p_sym, '매수', q, fill, -total);
  return jsonb_build_object('price', fill, 'total', total);
end $$;

create or replace function public.sell(p_sym text, p_qty numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; c cards; h holdings; fill numeric; got numeric; q numeric := trunc(p_qty, 3);
begin
  pl := _trader(); perform _need_open();
  if q is null or q <= 0 then raise exception '수량을 확인해 주세요'; end if;
  select * into h from holdings where player_id = pl.id and sym = p_sym for update;
  if not found or h.qty < q then raise exception '보유 수량이 부족해요'; end if;
  select * into c from cards where sym = p_sym for update;
  fill := c.price * 0.999; got := q * fill * (1 - _fee());
  update players set cash = cash + got where id = pl.id;
  if h.qty - q < 0.0005 then delete from holdings where player_id = pl.id and sym = p_sym;
  else update holdings set qty = qty - q where player_id = pl.id and sym = p_sym; end if;
  update cards set flow = flow - q * fill where sym = p_sym;
  insert into history (player_id, sym, what, qty, price, amount) values (pl.id, p_sym, '매도', q, fill, got);
  return jsonb_build_object('price', fill, 'total', got);
end $$;

-- ---------- 선물 ----------
create or replace function public.open_position(p_sym text, p_side text, p_margin numeric, p_lev int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; c cards; cfg config; entry numeric; f numeric; m numeric := floor(p_margin); liq numeric; q numeric;
begin
  pl := _trader(); perform _need_open();
  select * into cfg from config where id = 1;
  if p_side not in ('L','S') then raise exception '롱 또는 숏을 골라 주세요'; end if;
  if p_lev is null or p_lev < 1 or p_lev > cfg.max_lev then raise exception '레버리지는 1~%배까지예요', cfg.max_lev; end if;
  if m is null or m < 1000 then raise exception '증거금은 1,000젬 이상이에요'; end if;
  select * into c from cards where sym = p_sym for update;
  if not found then raise exception '없는 종목이에요'; end if;
  f := m * p_lev * _fee();
  if m + f > pl.cash then raise exception '젬이 부족해요'; end if;
  entry := c.price * (case when p_side = 'L' then 1.001 else 0.999 end);
  q := m * p_lev / entry;
  liq := case when p_side = 'L' then entry * (1 - 0.9 / p_lev) else entry * (1 + 0.9 / p_lev) end;
  update players set cash = cash - m - f where id = pl.id;
  insert into positions (player_id, sym, side, entry, qty, margin, lev, liq) values (pl.id, p_sym, p_side, entry, q, m, p_lev, liq);
  update cards set flow = flow + (case when p_side = 'L' then 1 else -1 end) * m * p_lev * 0.5 where sym = p_sym;
  insert into history (player_id, sym, what, qty, price, amount) values (pl.id, p_sym, (case when p_side = 'L' then '롱 ' else '숏 ' end) || p_lev || 'x 진입', q, entry, -(m + f));
  return jsonb_build_object('entry', entry, 'liq', liq);
end $$;

create or replace function public.close_position(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; po positions; c cards; fill numeric; pnl numeric; back numeric;
begin
  pl := _trader(); perform _need_open();
  select * into po from positions where id = p_id and player_id = pl.id for update;
  if not found then raise exception '포지션을 찾을 수 없어요'; end if;
  select * into c from cards where sym = po.sym for update;
  fill := c.price * (case when po.side = 'L' then 0.999 else 1.001 end);
  pnl := (case when po.side = 'L' then 1 else -1 end) * (fill - po.entry) * po.qty;
  back := greatest(0, po.margin + pnl - po.qty * fill * _fee());
  update players set cash = cash + back where id = pl.id;
  delete from positions where id = po.id;
  update cards set flow = flow - (case when po.side = 'L' then 1 else -1 end) * po.margin * po.lev * 0.5 where sym = po.sym;
  insert into history (player_id, sym, what, qty, price, amount) values (pl.id, po.sym, (case when po.side = 'L' then '롱' else '숏' end) || ' 정리', po.qty, fill, back);
  return jsonb_build_object('pnl', pnl, 'back', back);
end $$;

-- ---------- 예약 주문 (장 마감 중에도 가능) ----------
create or replace function public.place_order(p_sym text, p_side text, p_qty numeric, p_price numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; c cards; cfg config; q numeric := trunc(p_qty, 3); lp numeric := round(p_price); res numeric := 0; h holdings; oid bigint;
begin
  pl := _trader();
  select * into cfg from config where id = 1;
  if p_side not in ('buy','sell') then raise exception '매수 또는 매도를 골라 주세요'; end if;
  if q is null or q <= 0 then raise exception '수량을 확인해 주세요'; end if;
  select * into c from cards where sym = p_sym;
  if not found then raise exception '없는 종목이에요'; end if;
  if lp is null or lp < c.price * 0.7 or lp > c.price * 1.3 then raise exception '예약 가격은 현재가의 ±30%% 안에서 정해 주세요'; end if;
  if (select count(*) from orders where player_id = pl.id and status = 'open') >= cfg.max_open_orders then
    raise exception '예약 주문은 최대 %개까지 걸 수 있어요', cfg.max_open_orders; end if;
  if p_side = 'buy' then
    res := q * lp * (1 + _fee());
    if res > pl.cash then raise exception '젬이 부족해요'; end if;
    update players set cash = cash - res where id = pl.id;
  else
    select * into h from holdings where player_id = pl.id and sym = p_sym for update;
    if not found or h.qty < q then raise exception '보유 수량이 부족해요'; end if;
    if h.qty - q < 0.0005 then delete from holdings where player_id = pl.id and sym = p_sym;
    else update holdings set qty = qty - q where player_id = pl.id and sym = p_sym; end if;
  end if;
  insert into orders (player_id, sym, side, qty, limit_price, reserved) values (pl.id, p_sym, p_side, q, lp, res) returning id into oid;
  insert into history (player_id, sym, what, qty, price, amount) values (pl.id, p_sym, case when p_side = 'buy' then '예약 매수 등록' else '예약 매도 등록' end, q, lp, -res);
  -- 장중이고 이미 조건을 만족하면 바로 체결
  if market_open() then perform _match_orders(p_sym); end if;
  return jsonb_build_object('id', oid);
end $$;

create or replace function public._cancel(o public.orders, why text) returns void
language plpgsql security definer set search_path = public as $$
declare h holdings;
begin
  update orders set status = 'cancelled', done_at = now() where id = o.id;
  if o.side = 'buy' then
    update players set cash = cash + o.reserved where id = o.player_id;
  else
    select * into h from holdings where player_id = o.player_id and sym = o.sym for update;
    if found then
      update holdings set avg = (avg * qty + o.limit_price * o.qty) / (qty + o.qty), qty = qty + o.qty where player_id = o.player_id and sym = o.sym;
    else
      insert into holdings values (o.player_id, o.sym, o.qty, o.limit_price);
    end if;
  end if;
  insert into history (player_id, sym, what, qty, price, amount) values (o.player_id, o.sym, why, o.qty, o.limit_price, case when o.side = 'buy' then o.reserved else 0 end);
end $$;

create or replace function public.cancel_order(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pl players; o orders;
begin
  pl := _trader();
  select * into o from orders where id = p_id and player_id = pl.id and status = 'open' for update;
  if not found then raise exception '취소할 예약 주문이 없어요'; end if;
  perform _cancel(o, '예약 취소');
end $$;

create or replace function public._match_orders(p_sym text default null) returns int
language plpgsql security definer set search_path = public as $$
declare o orders; c cards; cost numeric; got numeric; n int := 0; f numeric := _fee();
begin
  for o in select ord.* from orders ord join cards cd using (sym)
           where ord.status = 'open' and (p_sym is null or ord.sym = p_sym)
             and ((ord.side = 'buy' and ord.limit_price >= cd.price) or (ord.side = 'sell' and ord.limit_price <= cd.price))
           order by ord.created_at for update of ord loop
    select * into c from cards where sym = o.sym;
    if o.side = 'buy' then
      cost := o.qty * c.price * (1 + f);
      update players set cash = cash + (o.reserved - cost) where id = o.player_id;
      insert into holdings values (o.player_id, o.sym, o.qty, c.price)
        on conflict (player_id, sym) do update set avg = (holdings.avg * holdings.qty + excluded.avg * excluded.qty) / (holdings.qty + excluded.qty), qty = holdings.qty + excluded.qty;
      update cards set flow = flow + o.qty * c.price where sym = o.sym;
      insert into history (player_id, sym, what, qty, price, amount) values (o.player_id, o.sym, '예약 매수 체결', o.qty, c.price, o.reserved - cost);
    else
      got := o.qty * c.price * (1 - f);
      update players set cash = cash + got where id = o.player_id;
      update cards set flow = flow - o.qty * c.price where sym = o.sym;
      insert into history (player_id, sym, what, qty, price, amount) values (o.player_id, o.sym, '예약 매도 체결', o.qty, c.price, got);
    end if;
    update orders set status = 'filled', done_at = now(), fill_price = c.price where id = o.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public._liquidate() returns int
language plpgsql security definer set search_path = public as $$
declare po record; n int := 0;
begin
  for po in select p.*, c.price from positions p join cards c using (sym)
            where (p.side = 'L' and c.price <= p.liq) or (p.side = 'S' and c.price >= p.liq) for update of p loop
    delete from positions where id = po.id;
    insert into history (player_id, sym, what, qty, price, amount) values (po.player_id, po.sym, '강제 청산', po.qty, po.liq, 0);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 재충전 ----------
create or replace function public.refill() returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; cfg config; eq numeric;
begin
  pl := _trader();
  select * into cfg from config where id = 1;
  eq := player_equity(pl.id);
  if eq >= cfg.start_cash * cfg.refill_thr_pct / 100 then raise exception '%', format('총 자산이 시작 젬의 %s%% 미만일 때만 재충전할 수 있어요', cfg.refill_thr_pct); end if;
  if pl.last_refill is not null and now() < pl.last_refill + make_interval(secs => cfg.refill_cool_h * 3600) then
    raise exception '아직 재충전 대기 시간이에요'; end if;
  update players set cash = cash + cfg.refill_amount, injected = injected + cfg.refill_amount, refills = refills + 1, last_refill = now() where id = pl.id;
  insert into history (player_id, what, amount) values (pl.id, '파산 지원 재충전', cfg.refill_amount);
  return jsonb_build_object('amount', cfg.refill_amount);
end $$;

-- ---------- 조회 ----------
create or replace function public.my_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p.id is null then null else jsonb_build_object(
    'player', to_jsonb(p) - 'banned' || jsonb_build_object('banned', p.banned),
    'equity', player_equity(p.id),
    'holdings', coalesce((select jsonb_agg(to_jsonb(h)) from holdings h where h.player_id = p.id), '[]'),
    'positions', coalesce((select jsonb_agg(to_jsonb(x) order by x.opened_at) from positions x where x.player_id = p.id), '[]'),
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from orders o where o.player_id = p.id and (o.status = 'open' or o.done_at > now() - interval '2 days')), '[]'),
    'history', coalesce((select jsonb_agg(to_jsonb(y)) from (select * from history where player_id = p.id order by at desc limit 60) y), '[]')
  ) end
  from (select auth.uid() uid) u left join players p on p.id = u.uid $$;

create or replace function public.leaderboard() returns table (rank bigint, name text, age_group text, refills int, equity numeric, injected numeric, profit numeric, is_me boolean)
language sql stable security definer set search_path = public as $$
  with e as (select p.*, player_equity(p.id) eq from players p where not p.banned)
  select row_number() over (order by e.eq - e.injected desc), e.name, e.age_group, e.refills, e.eq, e.injected, e.eq - e.injected, e.id = auth.uid()
  from e order by 7 desc limit 200 $$;

-- 개장 전 대기 주문 요약 (누가 걸었는지는 공개하지 않아요)
create or replace function public.pending_summary() returns table (sym text, buy_qty numeric, sell_qty numeric, buy_value numeric, sell_value numeric, buy_n bigint, sell_n bigint, traders bigint)
language sql stable security definer set search_path = public as $$
  select c.sym,
    coalesce(sum(o.qty) filter (where o.side = 'buy'), 0), coalesce(sum(o.qty) filter (where o.side = 'sell'), 0),
    coalesce(sum(o.qty * o.limit_price) filter (where o.side = 'buy'), 0), coalesce(sum(o.qty * o.limit_price) filter (where o.side = 'sell'), 0),
    count(o.id) filter (where o.side = 'buy'), count(o.id) filter (where o.side = 'sell'), count(distinct o.player_id)
  from cards c left join orders o on o.sym = c.sym and o.status = 'open'
  group by c.sym $$;

create or replace function public.order_ladder(p_sym text) returns table (price numeric, buy_qty numeric, sell_qty numeric)
language sql stable security definer set search_path = public as $$
  with c as (select price, case when price < 10000 then 10 when price < 100000 then 50 when price < 1000000 then 100 else 1000 end * 10 as step from cards where sym = p_sym)
  select round(o.limit_price / c.step) * c.step,
         coalesce(sum(o.qty) filter (where o.side = 'buy'), 0), coalesce(sum(o.qty) filter (where o.side = 'sell'), 0)
  from orders o, c where o.sym = p_sym and o.status = 'open'
  group by 1 order by 1 desc $$;

-- ---------- 시세 엔진 (10초마다) ----------
create or replace function public.market_tick() returns void
language plpgsql security definer set search_path = public as $$
declare st market_state; c cards; b numeric; r double precision; np numeric; mn timestamptz := date_trunc('minute', now());
        today date := (now() at time zone 'Asia/Seoul')::date; bv numeric; sv numeric; gap double precision; k cards;
begin
  select * into st from market_state where id = 1 for update;
  if not market_open() then
    if st.is_open then update market_state set is_open = false, last_tick = now() where id = 1;
      insert into news (body) select format('[장 마감] %s:00까지 가격이 멈춰요. 예약 주문은 계속 받아요.', lpad(close_end_h::text, 2, '0')) from config where id = 1; end if;
    return;
  end if;

  -- 하루 첫 틱: 동시호가로 시가 결정
  if st.last_open_date is distinct from today then
    for c in select * from cards for update loop
      select coalesce(sum(qty * limit_price) filter (where side = 'buy'), 0), coalesce(sum(qty * limit_price) filter (where side = 'sell'), 0)
        into bv, sv from orders where sym = c.sym and status = 'open';
      gap := 0;
      if bv + sv > 0 then gap := ((bv - sv) / (bv + sv)) * least(0.06, 0.01 + (bv + sv) / (c.base_krw * 200)); end if;
      b := _base_now(c);
      np := c.price * exp(gap + 0.5 * ln(b / c.price));
      update cards set price = np, day_ref = np, flow = 0, updated_at = now() where sym = c.sym;
      insert into candles values (c.sym, mn, c.price, greatest(c.price, np), least(c.price, np), np, 0)
        on conflict (sym, t) do update set h = greatest(candles.h, excluded.h), l = least(candles.l, excluded.l), c = excluded.c;
      if bv + sv > 0 then
        insert into news (sym, up, mag, body) values (c.sym, gap >= 0, abs(gap),
          format('[동시호가] %s %s · %s 대기 우위로 %s%% 출발', c.name, c.rarity, case when gap >= 0 then '매수' else '매도' end, to_char(gap * 100, 'FMS990.00')));
      end if;
    end loop;
    insert into news (body) values ('[개장] 오늘 장이 열렸어요. 대기 중이던 예약 주문을 체결해요.');
    update market_state set last_open_date = today, is_open = true, last_tick = now() where id = 1;
    perform _match_orders(null); perform _liquidate();
    return;
  end if;

  for c in select * from cards for update loop
    b := _base_now(c);
    r := 0.0005 * ln(b / c.price) + c.vol * 0.0008 * _gauss() + greatest(-0.03, least(0.03, c.flow / (c.base_krw * 300)));
    if c.shock_ticks > 0 then r := r + c.shock; end if;
    np := greatest(1, c.price * exp(r));
    update cards set price = np, flow = 0, shock_ticks = greatest(0, shock_ticks - 1), updated_at = now() where sym = c.sym;
    insert into candles values (c.sym, mn, c.price, greatest(c.price, np), least(c.price, np), np, abs(r) * 1000 + abs(c.flow) / c.base_krw)
      on conflict (sym, t) do update set h = greatest(candles.h, excluded.h), l = least(candles.l, excluded.l), c = excluded.c, v = candles.v + excluded.v;
  end loop;

  -- 가상 뉴스 (평균 약 4분에 한 번)
  if random() < 0.04 then
    select * into k from cards order by random() limit 1;
    gap := (0.03 + random() * 0.07) * (case when random() < 0.55 then 1 else -1 end);
    update cards set shock = gap / 6, shock_ticks = 6 where sym = k.sym;
    insert into news (sym, up, mag, body) values (k.sym, gap > 0, abs(gap), format(
      (case when gap > 0 then (array['해외 유명 개봉 영상에서 %s 등장, 관심 급증','대형 컬렉터 %s 매집 포착','%s 등급 10 물량 부족 소식','%s 바인더 인증 유행','%s 매물 급감'])[1 + floor(random() * 5)::int]
            else (array['%s 재판 루머 확산','%s 등급 10 물량 급증','%s 대량 매물 출회','%s 가품 유통 경보','%s 관심 식었다는 여론'])[1 + floor(random() * 5)::int] end),
      k.name || ' ' || k.rarity || ' (' || k.lang || ')'));
  end if;

  perform _match_orders(null);
  perform _liquidate();
  update market_state set is_open = true, last_tick = now() where id = 1;
  delete from candles where t < now() - interval '3 days';
  delete from news where at < now() - interval '3 days';
end $$;

-- ---------- 기준가 갱신 (운영자 또는 예약 작업 토큰) ----------
create or replace function public.set_base_prices(p_token text, p_prices jsonb, p_note text default null, p_asof date default null) returns int
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; n int := 0; c cards; h text;
begin
  select price_token_hash into h from private_settings where id = 1;
  if not (is_admin() or (h is not null and p_token is not null and encode(digest(p_token, 'sha256'), 'hex') = h)) then
    raise exception '권한이 없어요'; end if;
  for k, v in select * from jsonb_each(p_prices) loop
    select * into c from cards where sym = k for update;
    if not found then continue; end if;
    if (v->>'krw')::numeric is null or (v->>'krw')::numeric <= 0 then continue; end if;
    update cards set prev_base = _base_now(c), base_krw = (v->>'krw')::numeric, base_usd = coalesce((v->>'usd')::numeric, base_usd),
           base_asof = coalesce(p_asof, current_date), base_note = coalesce(p_note, base_note), base_updated_at = now()
     where sym = k;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 운영자 ----------
create or replace function public._need_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin if not is_admin() then raise exception '운영자만 할 수 있어요'; end if; end $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'age_group', p.age_group, 'joined_at', p.joined_at, 'cash', p.cash,
                 'injected', p.injected, 'refills', p.refills, 'bonus', p.bonus, 'banned', p.banned, 'equity', player_equity(p.id)) order by p.joined_at) from players p), '[]'),
    'open_orders', (select count(*) from orders where status = 'open'),
    'positions', (select count(*) from positions),
    'token_set', (select price_token_hash is not null from private_settings where id = 1));
end $$;

create or replace function public.admin_set_config(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  update config set
    season = coalesce(p->>'season', season),
    start_cash = greatest(1000, coalesce((p->>'start_cash')::numeric, start_cash)),
    refill_amount = greatest(0, coalesce((p->>'refill_amount')::numeric, refill_amount)),
    refill_thr_pct = least(100, greatest(0, coalesce((p->>'refill_thr_pct')::numeric, refill_thr_pct))),
    refill_cool_h = greatest(0, coalesce((p->>'refill_cool_h')::numeric, refill_cool_h)),
    max_lev = least(100, greatest(1, coalesce((p->>'max_lev')::int, max_lev))),
    fee_pct = least(5, greatest(0, coalesce((p->>'fee_pct')::numeric, fee_pct))),
    notice = coalesce(p->>'notice', notice),
    close_start_h = least(23, greatest(0, coalesce((p->>'close_start_h')::int, close_start_h))),
    close_end_h = least(24, greatest(0, coalesce((p->>'close_end_h')::int, close_end_h))),
    max_open_orders = least(100, greatest(1, coalesce((p->>'max_open_orders')::int, max_open_orders)))
  where id = 1;
end $$;

create or replace function public.admin_bonus(p_id uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if p_amount is null or p_amount = 0 then raise exception '금액을 확인해 주세요'; end if;
  update players set cash = cash + p_amount, bonus = bonus + p_amount where id = p_id;
  insert into history (player_id, what, amount) values (p_id, '운영자 보너스', p_amount);
end $$;

create or replace function public.admin_ban(p_id uuid, p_banned boolean) returns void
language plpgsql security definer set search_path = public as $$
begin perform _need_admin(); update players set banned = p_banned where id = p_id; end $$;

create or replace function public._reset_player(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare cfg config;
begin
  select * into cfg from config where id = 1;
  delete from holdings where player_id = p_id; delete from positions where player_id = p_id;
  delete from orders where player_id = p_id; delete from history where player_id = p_id;
  update players set cash = cfg.start_cash, injected = cfg.start_cash, refills = 0, last_refill = null, bonus = 0, season = cfg.season where id = p_id;
  insert into history (player_id, what, amount) values (p_id, '계정 초기화', cfg.start_cash);
end $$;

create or replace function public.admin_reset_player(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _need_admin(); perform _reset_player(p_id); end $$;

create or replace function public.reset_me() returns void
language plpgsql security definer set search_path = public as $$
declare pl players; begin pl := _trader(); perform _reset_player(pl.id); end $$;

create or replace function public.admin_season_reset(p_season text) returns int
language plpgsql security definer set search_path = public as $$
declare p record; n int := 0;
begin
  perform _need_admin();
  if p_season is not null and length(trim(p_season)) > 0 then update config set season = trim(p_season) where id = 1; end if;
  for p in select id from players loop perform _reset_player(p.id); n := n + 1; end loop;
  return n;
end $$;

create or replace function public.admin_set_price_token(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if p_token is null or length(p_token) < 24 then raise exception '토큰은 24자 이상이어야 해요'; end if;
  update private_settings set price_token_hash = encode(digest(p_token, 'sha256'), 'hex') where id = 1;
end $$;

-- ---------- 실행 권한: 내부 함수는 외부에서 못 부르게 ----------
revoke execute on function public._trader(), public._need_open(), public._match_orders(text), public._liquidate(),
  public._cancel(public.orders, text), public._reset_player(uuid), public.market_tick(), public._need_admin(),
  public.player_equity(uuid), public._base_now(public.cards), public._gauss(), public._fee()
  from public;
do $$ begin
  execute 'revoke execute on function public._trader(), public._need_open(), public._match_orders(text), public._liquidate(), public._cancel(public.orders, text), public._reset_player(uuid), public.market_tick(), public._need_admin(), public.player_equity(uuid), public._base_now(public.cards), public._gauss(), public._fee() from anon, authenticated';
exception when undefined_object then null; end $$;

-- ---------- 종목 (영문판·일판, SAR 이상) · 기준가 2026-11-10 ----------
-- 출처: PriceCharting 미등급 시세(USD) × 원/달러 1,347.1 (2026-11-09 종가)
insert into public.cards (sym, name, rarity, lang, set_code, ptype, vol, sort, base_krw, base_usd, base_asof, base_note, price, day_ref) values
 ('UMB-PRE',   '블래키 ex',       'SIR', 'EN', 'PRE 161/131',   'dark', 1.3, 1,  1462237, 1085.47, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$', 1462237, 1462237),
 ('MCX-PFL',   '메가리자몽X ex',  'SIR', 'EN', 'PFL 125/094',   'drag', 1.4, 2,   795692,  590.67, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  795692,  795692),
 ('MCX-PFL-M', '메가리자몽X ex',  'MUR', 'EN', 'PFL 130/094',   'drag', 1.5, 3,   253524,  188.20, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  253524,  253524),
 ('ZEK-BLK',   '제크로무 ex',     'BWR', 'EN', 'BLK 172/086',   'elec', 1.2, 4,   653290,  484.96, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  653290,  653290),
 ('RES-WHT',   '레시라무 ex',     'BWR', 'EN', 'WHT 173/086',   'fire', 1.2, 5,   585665,  434.76, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  585665,  585665),
 ('PIK-SSP',   '피카츄 ex',       'SIR', 'EN', 'SSP 238/191',   'elec', 1.1, 6,   300215,  222.86, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  300215,  300215),
 ('CHZ-OBF',   '리자몽 ex',       'SIR', 'EN', 'OBF 223/197',   'fire', 1.0, 7,   117198,   87.00, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  117198,  117198),
 ('UMB-SV8A',  '블래키 ex',       'SAR', 'JP', 'SV8a 217/187',  'dark', 1.2, 8,   409155,  303.73, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  409155,  409155),
 ('CHZ-SV2A',  '리자몽 ex',       'SAR', 'JP', 'SV2a 201/165',  'fire', 1.0, 9,   421130,  312.62, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  421130,  421130),
 ('ZEK-SV11B', '제크로무 ex',     'BWR', 'JP', 'SV11B 174/086', 'elec', 1.2, 10,  358032,  265.78, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  358032,  358032),
 ('PIK-SV8',   '피카츄 ex',       'SAR', 'JP', 'SV8 132/106',   'elec', 1.1, 11,  322630,  239.50, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  322630,  322630),
 ('MEW-SV2A',  '뮤 ex',           'UR',  'JP', 'SV2a 205/165',  'psy',  0.9, 12,  281813,  209.20, '2026-11-10', 'PriceCharting 미등급 · 1,347.1원/$',  281813,  281813)
on conflict (sym) do nothing;

-- ---------- 10초마다 시세 엔진 실행 (pg_cron) ----------
-- Supabase 대시보드 > Database > Extensions 에서 pg_cron을 켠 뒤 아래 두 줄이 실행돼요.
create extension if not exists pg_cron;
select cron.schedule('gem-market-tick', '10 seconds', $$select public.market_tick()$$);
-- ===== 기준가 자동 갱신 (환율은 서버가 매일 직접, 달러 시세는 예약 작업이 apply_usd_prices로) =====
create extension if not exists pg_net;
create table if not exists public.price_jobs (id bigserial primary key, kind text not null, req_id bigint, created_at timestamptz not null default now(), done boolean not null default false, result text);
alter table public.price_jobs enable row level security;

create or replace function public._rebase(p_fx numeric, p_note text) returns int
language plpgsql security definer set search_path = public as $$
declare c cards; n int := 0;
begin
  if p_fx is null or p_fx < 500 or p_fx > 3000 then raise exception 'fx out of range: %', p_fx; end if;
  for c in select * from cards where base_usd is not null and base_usd > 0 for update loop
    update cards set prev_base = _base_now(c), base_krw = round(c.base_usd * p_fx), base_asof = (now() at time zone 'Asia/Seoul')::date,
           base_note = p_note, base_updated_at = now() where sym = c.sym;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.fx_request() returns bigint
language plpgsql security definer set search_path = public as $$
declare rid bigint;
begin
  select net.http_get('https://open.er-api.com/v6/latest/USD') into rid;
  insert into price_jobs (kind, req_id) values ('fx', rid);
  return rid;
end $$;

create or replace function public.fx_apply() returns text
language plpgsql security definer set search_path = public as $$
declare j price_jobs; r record; fx numeric; t text; msg text;
begin
  select * into j from price_jobs where kind = 'fx' and not done order by id desc limit 1;
  if not found then return 'no pending job'; end if;
  select * into r from net._http_response where id = j.req_id;
  if not found then return 'waiting'; end if;
  if r.status_code <> 200 then msg := 'http ' || r.status_code;
  else
    fx := ((r.content::jsonb)->'rates'->>'KRW')::numeric;
    t := (r.content::jsonb)->>'time_last_update_utc';
    perform _rebase(round(fx, 2), format('PriceCharting 미등급 시세 · 환율 %s원 (%s)', to_char(round(fx, 2), 'FM9,990.00'), coalesce(t, '')));
    msg := 'ok ' || fx;
  end if;
  update price_jobs set done = true, result = msg where id = j.id;
  return msg;
end $$;

-- 예약 작업이 조사한 달러 시세 반영: {"UMB-PRE": 1085.47, ...} (마지막 환율로 즉시 환산)
create or replace function public.apply_usd_prices(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; n int := 0; c cards; fx numeric; usd numeric;
begin
  select coalesce(nullif(substring(base_note from '환율 ([0-9,.]+)원'), ''), '0') into k from cards where base_note like '%환율%' order by base_updated_at desc limit 1;
  fx := nullif(replace(coalesce(k, '0'), ',', ''), '')::numeric;
  if fx is null or fx < 500 then fx := 1347.1; end if;
  for k, v in select * from jsonb_each(p) loop
    usd := (v #>> '{}')::numeric;
    select * into c from cards where sym = k for update;
    if not found or usd is null or usd <= 0 then continue; end if;
    if c.base_usd is not null and (usd > c.base_usd * 1.5 or usd < c.base_usd / 1.5) then continue; end if; -- 급변은 무시
    update cards set base_usd = usd, prev_base = _base_now(c), base_krw = round(usd * fx), base_asof = (now() at time zone 'Asia/Seoul')::date,
           base_note = format('PriceCharting 미등급 시세 · 환율 %s원', to_char(fx, 'FM9,990.00')), base_updated_at = now() where sym = k;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public._rebase(numeric, text), public.fx_request(), public.fx_apply(), public.apply_usd_prices(jsonb) from public;
do $$ begin
  execute 'revoke execute on function public._rebase(numeric, text), public.fx_request(), public.fx_apply(), public.apply_usd_prices(jsonb) from anon, authenticated';
exception when undefined_object then null; end $$;

-- 매일 07:30 KST(22:30 UTC) 환율 요청, 07:33 반영 → 08:00 개장 전 1시간에 걸쳐 새 기준가로 이동
select cron.schedule('gem-fx-request', '30 22 * * *', $$select public.fx_request()$$);
select cron.schedule('gem-fx-apply', '33 22 * * *', $$select public.fx_apply()$$);


-- =====================================================================
--  젬 거래소 업데이트 002 (기존 데이터 보존: 표는 추가만, 함수는 교체만)
--  - 5초 틱 + 15초봉
--  - PSA 10 기준 시세
--  - 출석 보상 / 운영자 전원 지급
--  - 실거래 고래·물량 이동 뉴스, PSA 팝 증가 뉴스
--  - 계정 복구 코드
-- =====================================================================
alter table public.config add column if not exists daily_bonus numeric not null default 100000;
alter table public.config add column if not exists whale_threshold numeric not null default 30000000;
alter table public.players add column if not exists last_daily date;
alter table public.players add column if not exists recovery_hash text;
alter table public.news add column if not exists kind text not null default 'sim';

create table if not exists public.candles_15 (
  sym text references public.cards on delete cascade, t timestamptz,
  o numeric, h numeric, l numeric, c numeric, v numeric not null default 0,
  primary key (sym, t)
);
alter table public.candles_15 enable row level security;
drop policy if exists r on public.candles_15; create policy r on public.candles_15 for select using (true);

create table if not exists public.psa_pop (
  sym text references public.cards on delete cascade, checked_on date not null,
  pop10 int not null, pop_total int, primary key (sym, checked_on)
);
alter table public.psa_pop enable row level security;
drop policy if exists r on public.psa_pop; create policy r on public.psa_pop for select using (true);

-- ---------- 시세 엔진: 5초 틱, 15초봉 ----------
create or replace function public.market_tick() returns void
language plpgsql security definer set search_path = public as $$
declare st market_state; c cards; b numeric; r double precision; np numeric; mn timestamptz := date_trunc('minute', now());
        q15 timestamptz := to_timestamp(floor(extract(epoch from now()) / 15) * 15);
        today date := (now() at time zone 'Asia/Seoul')::date; bv numeric; sv numeric; gap double precision; k cards;
begin
  select * into st from market_state where id = 1 for update;
  if not market_open() then
    if st.is_open then update market_state set is_open = false, last_tick = now() where id = 1;
      insert into news (body, kind) select format('[장 마감] %s:00까지 가격이 멈춰요. 예약 주문은 계속 받아요.', lpad(close_end_h::text, 2, '0')), 'event' from config where id = 1; end if;
    return;
  end if;

  if st.last_open_date is distinct from today then
    for c in select * from cards for update loop
      select coalesce(sum(qty * limit_price) filter (where side = 'buy'), 0), coalesce(sum(qty * limit_price) filter (where side = 'sell'), 0)
        into bv, sv from orders where sym = c.sym and status = 'open';
      gap := 0;
      if bv + sv > 0 then gap := ((bv - sv) / (bv + sv)) * least(0.06, 0.01 + (bv + sv) / (c.base_krw * 200)); end if;
      b := _base_now(c);
      np := c.price * exp(gap + 0.5 * ln(b / c.price));
      update cards set price = np, day_ref = np, flow = 0, updated_at = now() where sym = c.sym;
      insert into candles values (c.sym, mn, c.price, greatest(c.price, np), least(c.price, np), np, 0)
        on conflict (sym, t) do update set h = greatest(candles.h, excluded.h), l = least(candles.l, excluded.l), c = excluded.c;
      insert into candles_15 values (c.sym, q15, c.price, greatest(c.price, np), least(c.price, np), np, 0)
        on conflict (sym, t) do update set h = greatest(candles_15.h, excluded.h), l = least(candles_15.l, excluded.l), c = excluded.c;
      if bv + sv > 0 then
        insert into news (sym, up, mag, body, kind) values (c.sym, gap >= 0, abs(gap),
          format('[동시호가] %s %s(%s) · %s 대기 우위로 %s%% 출발', c.name, c.rarity, c.lang, case when gap >= 0 then '매수' else '매도' end, to_char(gap * 100, 'FMS990.00')), 'real');
      end if;
    end loop;
    insert into news (body, kind) values ('[개장] 오늘 장이 열렸어요. 대기 중이던 예약 주문을 체결해요.', 'event');
    update market_state set last_open_date = today, is_open = true, last_tick = now() where id = 1;
    perform _match_orders(null); perform _liquidate();
    return;
  end if;

  for c in select * from cards for update loop
    b := _base_now(c);
    r := 0.00025 * ln(b / c.price) + c.vol * 0.00057 * _gauss() + greatest(-0.03, least(0.03, c.flow / (c.base_krw * 300)));
    if c.shock_ticks > 0 then r := r + c.shock; end if;
    np := greatest(1, c.price * exp(r));
    update cards set price = np, flow = 0, shock_ticks = greatest(0, shock_ticks - 1), updated_at = now() where sym = c.sym;
    insert into candles values (c.sym, mn, c.price, greatest(c.price, np), least(c.price, np), np, abs(r) * 1000 + abs(c.flow) / c.base_krw)
      on conflict (sym, t) do update set h = greatest(candles.h, excluded.h), l = least(candles.l, excluded.l), c = excluded.c, v = candles.v + excluded.v;
    insert into candles_15 values (c.sym, q15, c.price, greatest(c.price, np), least(c.price, np), np, abs(r) * 1000 + abs(c.flow) / c.base_krw)
      on conflict (sym, t) do update set h = greatest(candles_15.h, excluded.h), l = least(candles_15.l, excluded.l), c = excluded.c, v = candles_15.v + excluded.v;
  end loop;

  if random() < 0.02 then
    select * into k from cards order by random() limit 1;
    gap := (0.03 + random() * 0.07) * (case when random() < 0.55 then 1 else -1 end);
    update cards set shock = gap / 12, shock_ticks = 12 where sym = k.sym;
    insert into news (sym, up, mag, body, kind) values (k.sym, gap > 0, abs(gap), format(
      (case when gap > 0 then (array['해외 유명 개봉 영상에서 %s 등장, 관심 급증','대형 컬렉터 %s 매집 포착','%s PSA 10 매물 품귀','%s 바인더 인증 유행','%s 매물 급감'])[1 + floor(random() * 5)::int]
            else (array['%s 재판 루머 확산','%s PSA 10 매물 급증','%s 대량 매물 출회','%s 가품 유통 경보','%s 관심 식었다는 여론'])[1 + floor(random() * 5)::int] end),
      k.name || ' ' || k.rarity || ' (' || k.lang || ')'), 'sim');
  end if;

  perform _match_orders(null);
  perform _liquidate();
  update market_state set is_open = true, last_tick = now() where id = 1;
  delete from candles_15 where t < now() - interval '6 hours';
  delete from candles where t < now() - interval '3 days';
  delete from news where at < now() - interval '3 days';
end $$;

-- ---------- 실거래 고래 · 물량 이동 뉴스 (거래 기록에서 자동 생성) ----------
create or replace function public._trade_news() returns trigger
language plpgsql security definer set search_path = public as $$
declare th numeric; c cards; amt numeric := abs(coalesce(new.amount, 0)); prev history; pc cards; label text;
begin
  if new.sym is null then return new; end if;
  select whale_threshold into th from config where id = 1;
  select * into c from cards where sym = new.sym;
  if not found then return new; end if;
  label := c.name || ' ' || c.rarity || '(' || c.lang || ')';
  -- 물량 이동: 같은 참가자가 10분 안에 큰 규모로 다른 종목을 팔고 이 종목을 삼
  if new.what in ('매수', '예약 매수 체결') and amt >= th / 2 then
    select * into prev from history where player_id = new.player_id and what in ('매도', '예약 매도 체결') and sym <> new.sym
      and at > now() - interval '10 minutes' and abs(amount) >= th / 2 order by at desc limit 1;
    if found then
      select * into pc from cards where sym = prev.sym;
      insert into news (sym, up, mag, body, kind) values (new.sym, true, 0, format('[물량 이동] 약 %s젬 규모 자금이 %s → %s로 이동',
        to_char(round(least(amt, abs(prev.amount)) / 10000), 'FM999,999,999') || '만', pc.name || ' ' || pc.rarity || '(' || pc.lang || ')', label), 'real');
      return new;
    end if;
  end if;
  if amt >= th and (new.what in ('매수', '매도', '예약 매수 체결', '예약 매도 체결') or new.what like '%x 진입') then
    insert into news (sym, up, mag, body, kind) values (new.sym, new.what like '%매수%' or new.what like '롱%', 0,
      format('[고래 경보] %s %s %s젬 체결', label,
        case when new.what like '%매수%' then '대량 매수' when new.what like '%매도%' then '대량 매도' when new.what like '롱%' then '대형 롱 포지션' else '대형 숏 포지션' end,
        to_char(round(amt / 10000), 'FM999,999,999') || '만'), 'real');
  end if;
  return new;
end $$;
drop trigger if exists trade_news on public.history;
create trigger trade_news after insert on public.history for each row execute function public._trade_news();

-- ---------- PSA 팝 증가 뉴스 (예약 작업이 하루 한 번 호출) ----------
-- p = {"UMB-PRE": {"pop10": 5487, "total": 17990}, ...}
create or replace function public.apply_psa_pop(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; c cards; last psa_pop; n int := 0; p10 int; tot int; inc int; today date := (now() at time zone 'Asia/Seoul')::date; s double precision;
begin
  for k, v in select * from jsonb_each(p) loop
    select * into c from cards where sym = k;
    if not found then continue; end if;
    p10 := (v->>'pop10')::int; tot := nullif(v->>'total', '')::int;
    if p10 is null or p10 < 0 then continue; end if;
    select * into last from psa_pop where sym = k and checked_on < today order by checked_on desc limit 1;
    insert into psa_pop values (k, today, p10, tot) on conflict (sym, checked_on) do update set pop10 = excluded.pop10, pop_total = excluded.pop_total;
    if last.sym is not null then
      inc := p10 - last.pop10;
      if inc > 0 then
        s := -least(0.03, inc::double precision / greatest(last.pop10, 1) * 2);
        update cards set shock = s / 12, shock_ticks = 12 where sym = k;
        insert into news (sym, up, mag, body, kind) values (k, false, abs(s),
          format('[PSA 팝] %s %s(%s) PSA 10 +%s장 → 누적 %s장', c.name, c.rarity, c.lang, to_char(inc, 'FM999,999'), to_char(p10, 'FM999,999,999')), 'psa');
      end if;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 출석 보상 / 운영자 지급 ----------
create or replace function public.claim_daily() returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players; amt numeric; today date := (now() at time zone 'Asia/Seoul')::date;
begin
  pl := _trader();
  select daily_bonus into amt from config where id = 1;
  if amt is null or amt <= 0 then raise exception '지금은 출석 보상이 없어요'; end if;
  if pl.last_daily = today then raise exception '오늘 출석 보상은 이미 받았어요. 내일 다시 와 주세요'; end if;
  update players set cash = cash + amt, injected = injected + amt, last_daily = today where id = pl.id;
  insert into history (player_id, what, amount) values (pl.id, '출석 보상', amt);
  return jsonb_build_object('amount', amt);
end $$;

drop function if exists public.admin_bonus(uuid, numeric);
create or replace function public.admin_bonus(p_id uuid, p_amount numeric, p_as_profit boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if p_amount is null or p_amount = 0 then raise exception '금액을 확인해 주세요'; end if;
  update players set cash = cash + p_amount, bonus = bonus + p_amount,
         injected = injected + (case when p_as_profit then 0 else p_amount end) where id = p_id;
  insert into history (player_id, what, amount) values (p_id, '운영자 지급', p_amount);
end $$;

create or replace function public.admin_gift_all(p_amount numeric, p_note text default null, p_as_profit boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _need_admin();
  if p_amount is null or p_amount <= 0 then raise exception '금액을 확인해 주세요'; end if;
  update players set cash = cash + p_amount, bonus = bonus + p_amount,
         injected = injected + (case when p_as_profit then 0 else p_amount end) where not banned;
  get diagnostics n = row_count;
  insert into history (player_id, what, amount) select id, '운영자 선물' || coalesce(' · ' || nullif(trim(p_note), ''), ''), p_amount from players where not banned;
  insert into news (body, kind) values (format('[이벤트] 참가자 전원에게 %s젬을 지급했어요%s', to_char(p_amount, 'FM999,999,999,999'), coalesce(' · ' || nullif(trim(p_note), ''), '')), 'event');
  return n;
end $$;

create or replace function public.admin_set_config(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  update config set
    season = coalesce(p->>'season', season),
    start_cash = greatest(1000, coalesce((p->>'start_cash')::numeric, start_cash)),
    refill_amount = greatest(0, coalesce((p->>'refill_amount')::numeric, refill_amount)),
    refill_thr_pct = least(100, greatest(0, coalesce((p->>'refill_thr_pct')::numeric, refill_thr_pct))),
    refill_cool_h = greatest(0, coalesce((p->>'refill_cool_h')::numeric, refill_cool_h)),
    max_lev = least(100, greatest(1, coalesce((p->>'max_lev')::int, max_lev))),
    fee_pct = least(5, greatest(0, coalesce((p->>'fee_pct')::numeric, fee_pct))),
    notice = coalesce(p->>'notice', notice),
    close_start_h = least(23, greatest(0, coalesce((p->>'close_start_h')::int, close_start_h))),
    close_end_h = least(24, greatest(0, coalesce((p->>'close_end_h')::int, close_end_h))),
    max_open_orders = least(100, greatest(1, coalesce((p->>'max_open_orders')::int, max_open_orders))),
    daily_bonus = greatest(0, coalesce((p->>'daily_bonus')::numeric, daily_bonus)),
    whale_threshold = greatest(100000, coalesce((p->>'whale_threshold')::numeric, whale_threshold))
  where id = 1;
end $$;

-- ---------- 계정 복구 코드 ----------
create or replace function public.make_recovery_code() returns text
language plpgsql security definer set search_path = public as $$
declare pl players; code text; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := gen_random_bytes(12); i int;
begin
  pl := _trader();
  code := '';
  for i in 0..11 loop code := code || substr(alphabet, (get_byte(b, i) % 32) + 1, 1); if i in (3, 7) then code := code || '-'; end if; end loop;
  update players set recovery_hash = encode(digest(code, 'sha256'), 'hex') where id = pl.id;
  return code;
end $$;

create or replace function public.recover_account(p_name text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); old players;
begin
  if me is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from players where id = me) then raise exception '이 기기에는 이미 다른 계정이 있어요. "내 계정 처음부터 다시 시작" 대신 운영자에게 문의해 주세요'; end if;
  select * into old from players where lower(name) = lower(trim(p_name)) for update;
  if not found or old.recovery_hash is null or old.recovery_hash <> encode(digest(upper(trim(p_code)), 'sha256'), 'hex') then
    perform pg_sleep(1); raise exception '닉네임 또는 복구 코드가 맞지 않아요'; end if;
  update players set name = left(old.name, 12) || '~' || substr(md5(random()::text), 1, 6) where id = old.id;
  insert into players (id, name, age_group, cash, injected, refills, last_refill, bonus, banned, season, joined_at, last_daily, recovery_hash)
    values (me, old.name, old.age_group, old.cash, old.injected, old.refills, old.last_refill, old.bonus, old.banned, old.season, old.joined_at, old.last_daily, old.recovery_hash);
  update holdings set player_id = me where player_id = old.id;
  update positions set player_id = me where player_id = old.id;
  update orders set player_id = me where player_id = old.id;
  update history set player_id = me where player_id = old.id;
  update admins set user_id = me where user_id = old.id;
  delete from players where id = old.id;
  insert into history (player_id, what, amount) values (me, '다른 기기에서 계정 복구', 0);
end $$;

create or replace function public.my_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p.id is null then null else jsonb_build_object(
    'player', to_jsonb(p) - 'recovery_hash' || jsonb_build_object('has_recovery', p.recovery_hash is not null),
    'equity', player_equity(p.id),
    'holdings', coalesce((select jsonb_agg(to_jsonb(h)) from holdings h where h.player_id = p.id), '[]'),
    'positions', coalesce((select jsonb_agg(to_jsonb(x) order by x.opened_at) from positions x where x.player_id = p.id), '[]'),
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from orders o where o.player_id = p.id and (o.status = 'open' or o.done_at > now() - interval '2 days')), '[]'),
    'history', coalesce((select jsonb_agg(to_jsonb(y)) from (select * from history where player_id = p.id order by at desc limit 60) y), '[]')
  ) end
  from (select auth.uid() uid) u left join players p on p.id = u.uid $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'age_group', p.age_group, 'joined_at', p.joined_at, 'cash', p.cash,
                 'injected', p.injected, 'refills', p.refills, 'bonus', p.bonus, 'banned', p.banned, 'equity', player_equity(p.id)) order by p.joined_at) from players p), '[]'),
    'open_orders', (select count(*) from orders where status = 'open'),
    'positions', (select count(*) from positions),
    'token_set', (select price_token_hash is not null from private_settings where id = 1),
    'pop', coalesce((select jsonb_object_agg(sym, pop10) from (select distinct on (sym) sym, pop10 from psa_pop order by sym, checked_on desc) z), '{}'));
end $$;

-- ---------- 실행 권한 ----------
revoke execute on function public.apply_psa_pop(jsonb), public._trade_news() from public;
do $$ begin
  execute 'revoke execute on function public.apply_psa_pop(jsonb), public._trade_news() from anon, authenticated';
exception when undefined_object then null; end $$;

-- ---------- 기준가 문구를 PSA 10 기준으로 ----------
create or replace function public.fx_apply() returns text
language plpgsql security definer set search_path = public as $$
declare j price_jobs; r record; fx numeric; t text; msg text;
begin
  select * into j from price_jobs where kind = 'fx' and not done order by id desc limit 1;
  if not found then return 'no pending job'; end if;
  select * into r from net._http_response where id = j.req_id;
  if not found then return 'waiting'; end if;
  if r.status_code <> 200 then msg := 'http ' || r.status_code;
  else
    fx := ((r.content::jsonb)->'rates'->>'KRW')::numeric;
    t := (r.content::jsonb)->>'time_last_update_utc';
    perform _rebase(round(fx, 2), format('PriceCharting PSA 10 시세 · 환율 %s원 (%s)', to_char(round(fx, 2), 'FM9,990.00'), coalesce(t, '')));
    msg := 'ok ' || fx;
  end if;
  update price_jobs set done = true, result = msg where id = j.id;
  return msg;
end $$;

-- 예약 작업이 조사한 달러 시세 반영: {"UMB-PRE": 1085.47, ...} (마지막 환율로 즉시 환산)
create or replace function public.apply_usd_prices(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; n int := 0; c cards; fx numeric; usd numeric;
begin
  select coalesce(nullif(substring(base_note from '환율 ([0-9,.]+)원'), ''), '0') into k from cards where base_note like '%환율%' order by base_updated_at desc limit 1;
  fx := nullif(replace(coalesce(k, '0'), ',', ''), '')::numeric;
  if fx is null or fx < 500 then fx := 1347.1; end if;
  for k, v in select * from jsonb_each(p) loop
    usd := (v #>> '{}')::numeric;
    select * into c from cards where sym = k for update;
    if not found or usd is null or usd <= 0 then continue; end if;
    if c.base_usd is not null and (usd > c.base_usd * 1.5 or usd < c.base_usd / 1.5) then continue; end if; -- 급변은 무시
    update cards set base_usd = usd, prev_base = _base_now(c), base_krw = round(usd * fx), base_asof = (now() at time zone 'Asia/Seoul')::date,
           base_note = format('PriceCharting PSA 10 시세 · 환율 %s원', to_char(fx, 'FM9,990.00')), base_updated_at = now() where sym = k;
    n := n + 1;
  end loop;
  return n;
end $$;

