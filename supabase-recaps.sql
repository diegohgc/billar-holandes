-- PuckSlide: resumenes de mes y de semana con premios en monedas
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-08-30: al empezar un mes nuevo, avisar a todos los
-- jugadores de como quedaron el mes anterior (top 3 destacado, premio en monedas al 1º,
-- 2º y 3º). Al empezar una semana nueva, avisar de como quedo su division (top 3
-- destacado, "campeon" solo para el 1º de la DIVISION 1, ascensos/descensos de todas las
-- divisiones, premio en monedas solo al 1º de cada division).
--
-- Premios acordados:
--   Mensual: 1º = 50 monedas, 2º = 25 monedas, 3º = 15 monedas (resto del top 3 no cobra)
--   Semanal (por division): 1º de cada division = 30 monedas (2º y 3º solo se destacan,
--   sin premio)
--
-- El aviso se muestra en cuanto el jugador ABRE LA APP (no hace falta que juegue), para
-- que no se pierda la sensacion de "recien ha pasado" si tarda unos dias en volver a
-- jugar. Por eso se guardan "fotos" de cada periodo en tablas propias (monthly_recap,
-- weekly_recap) en vez de calcularlo al vuelo - lo semanal en concreto SE PIERDE en
-- cuanto corre el cron de ascensos/descensos (cambia league_division), asi que hay que
-- guardar el resumen ANTES de mover a nadie.

-- ==================================================================================
-- 1) TABLAS
-- ==================================================================================
create table public.monthly_recap (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.profiles(id) on delete cascade,
  recap_month date not null, -- primer dia del mes que se resume, ej. '2026-08-01'
  avg_score numeric,
  rank_overall int not null,
  total_players int not null,
  coins_awarded int not null default 0,
  seen boolean not null default false,
  created_at timestamptz not null default now(),
  unique (player_id, recap_month)
);
alter table public.monthly_recap enable row level security;
create policy "Cada usuario ve solo sus propios resumenes mensuales"
  on public.monthly_recap for select
  using (auth.uid() = player_id);

create table public.weekly_recap (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.profiles(id) on delete cascade,
  week_start date not null, -- lunes de la semana que se resume
  division int not null, -- division en la que estaba ANTES de aplicar ascensos/descensos
  week_score numeric,
  rank_in_division int not null,
  total_in_division int not null,
  promoted boolean not null default false,
  relegated boolean not null default false,
  coins_awarded int not null default 0,
  seen boolean not null default false,
  created_at timestamptz not null default now(),
  unique (player_id, week_start)
);
alter table public.weekly_recap enable row level security;
create policy "Cada usuario ve solo sus propios resumenes semanales"
  on public.weekly_recap for select
  using (auth.uid() = player_id);

-- ==================================================================================
-- 2) FUNCION MENSUAL (cron nuevo, dia 1 de cada mes)
-- ==================================================================================
create or replace function public.run_monthly_recap()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  month_start date := date_trunc('month', now() - interval '1 day')::date; -- mes que acaba de terminar
  month_end date := date_trunc('month', now())::date; -- exclusivo, es el mes nuevo que empieza ahora
begin
  with month_avg as (
    select
      m.player_id,
      avg(m.score) as avg_score,
      count(*) as num_matches
    from public.solo_matches m
    where m.played_at >= month_start and m.played_at < month_end
    group by m.player_id
    having count(*) >= 2 -- misma regla minima que la clasificacion mensual en vivo
  ),
  ranked as (
    select
      player_id,
      avg_score,
      row_number() over (order by avg_score desc) as rank_overall,
      count(*) over () as total_players
    from month_avg
  )
  insert into public.monthly_recap (player_id, recap_month, avg_score, rank_overall, total_players, coins_awarded)
  select
    player_id,
    month_start,
    avg_score,
    rank_overall,
    total_players,
    case rank_overall when 1 then 50 when 2 then 25 when 3 then 15 else 0 end
  from ranked
  on conflict (player_id, recap_month) do nothing;

  -- reparte las monedas del premio (solo top 3, el resto queda en 0 y no se toca)
  update public.profiles p
  set coins = coins + r.coins_awarded
  from public.monthly_recap r
  where r.player_id = p.id and r.recap_month = month_start and r.coins_awarded > 0;
end;
$$;

create extension if not exists pg_cron;
select cron.schedule(
  'run_monthly_recap',
  '10 0 1 * *', -- dia 1 de cada mes, 00:10 UTC (despues de medianoche, antes de que la gente empiece a jugar)
  $$ select public.run_monthly_recap(); $$
);

-- ==================================================================================
-- 3) FUNCION SEMANAL: se sustituye run_league_promotions() para que guarde el resumen
--    ANTES de mover a nadie de division. El resto de la logica (ascensos/descensos) se
--    deja exactamente igual que en supabase-leagues.sql - solo se añade el guardado del
--    resumen y el reparto de monedas al principio.
-- ==================================================================================
create or replace function public.run_league_promotions()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  eligible_count int;
  target_divisions int;
  max_division int;
  d int;
  this_week_start date := date_trunc('week', now())::date;
begin
  -- jugadores nuevos sin division asignada (se han registrado desde el ultimo corte):
  -- se colocan al fondo de todo para empezar
  select coalesce(max(league_division), 1) into max_division from public.profiles;
  update public.profiles set league_division = max_division where league_division is null;

  -- ---- NUEVO: guardar el resumen de la semana ANTES de tocar ninguna division ----
  with ranked as (
    select
      player_id,
      league_division,
      week_score,
      row_number() over (partition by league_division order by week_score desc) as rank_in_division,
      count(*) over (partition by league_division) as total_in_division
    from public.league_ranking
    where matches_played >= 3 -- solo cuenta si su puntuacion semanal es real (no un 0 por pocas partidas)
  ),
  flagged as (
    select
      r.*,
      (rank_in_division <= 3) as promoted,
      (rank_in_division > total_in_division - 3) as relegated
    from ranked r
  )
  insert into public.weekly_recap (player_id, week_start, division, week_score, rank_in_division, total_in_division, promoted, relegated, coins_awarded)
  select
    f.player_id,
    this_week_start,
    f.league_division,
    (select week_score from public.league_ranking lr where lr.player_id = f.player_id),
    f.rank_in_division,
    f.total_in_division,
    f.promoted,
    -- si la division es tan pequeña que el mismo puesto contaria como ascenso y descenso
    -- a la vez, gana el ascenso (igual que la regla original de run_league_promotions)
    (f.relegated and not f.promoted),
    case when f.rank_in_division = 1 then 30 else 0 end
  from flagged f
  on conflict (player_id, week_start) do nothing;

  update public.profiles p
  set coins = coins + r.coins_awarded
  from public.weekly_recap r
  where r.player_id = p.id and r.week_start = this_week_start and r.coins_awarded > 0;
  -- ---- FIN NUEVO ----

  -- cuanta gente ha jugado esta semana - eso decide cuantas divisiones hacen falta
  select count(*) into eligible_count from public.league_ranking where matches_played >= 3;
  target_divisions := greatest(1, ceil(eligible_count / 20.0))::int;

  -- ascensos y descensos, division por division, segun la clasificacion de ESTA semana
  for d in 1..max_division loop
    update public.profiles
    set league_division = greatest(1, d - 1)
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played >= 3
      order by week_score desc
      limit 3
    );

    update public.profiles
    set league_division = d + 1
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played >= 3
      order by week_score asc
      limit 3
    );
  end loop;

  -- reencaja a todo el mundo dentro del numero de divisiones vigente esta semana (por si ha
  -- crecido o encogido la base de jugadores activos)
  update public.profiles set league_division = target_divisions where league_division > target_divisions;
  update public.profiles set league_division = 1 where league_division < 1;
end;
$$;

-- ==================================================================================
-- 4) RPCs para el cliente: leer resumenes pendientes y marcarlos como vistos
-- ==================================================================================
create or replace function public.get_pending_recaps()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  monthly jsonb;
  weekly jsonb;
begin
  select jsonb_agg(to_jsonb(m)) into monthly
  from public.monthly_recap m
  where m.player_id = auth.uid() and m.seen = false;

  select jsonb_agg(to_jsonb(w)) into weekly
  from public.weekly_recap w
  where w.player_id = auth.uid() and w.seen = false;

  return jsonb_build_object(
    'monthly', coalesce(monthly, '[]'::jsonb),
    'weekly', coalesce(weekly, '[]'::jsonb)
  );
end;
$$;

create or replace function public.mark_recap_seen(p_kind text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind = 'monthly' then
    update public.monthly_recap set seen = true where id = p_id and player_id = auth.uid();
  elsif p_kind = 'weekly' then
    update public.weekly_recap set seen = true where id = p_id and player_id = auth.uid();
  end if;
end;
$$;
