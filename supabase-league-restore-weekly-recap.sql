-- PuckSlide: recuperar el aviso semanal de ascensos/descensos (roto sin querer el 2026-09-09)
-- ------------------------------------------------------------------------------------
-- DESCUBIERTO al responder la pregunta del usuario "¿habria que avisar a los jugadores del
-- reparto nuevo de divisiones?": el juego YA TENIA un sistema de avisos para esto desde el
-- 2026-08-31 (supabase-recaps.sql) - una pantalla de "resumen semanal" que se muestra al
-- abrir la app con: top 3 de tu division, si has ascendido/descendido, "campeon" si eres el
-- 1º de la division 1, y 30 monedas de premio para el 1º de cada division.
--
-- Ese sistema estaba tejido DENTRO de run_league_promotions() (guardaba el resumen antes de
-- mover a nadie de division). El 2026-09-09, al corregir el bug de fechas de esa misma
-- funcion (ver supabase-league-promotions-fix.sql), la reescribi basandome en la version
-- ORIGINAL de supabase-leagues.sql en vez de en la version de supabase-recaps.sql que ya
-- tenia el guardado del resumen integrado - sin darme cuenta, elimine esa parte. Desde
-- entonces (dos lunes ya) los jugadores no han recibido ni el aviso ni las 30 monedas.
--
-- Esta version junta todo:
--   1) el guardado del resumen semanal + reparto de monedas (recuperado de supabase-recaps.sql)
--   2) el calculo de la semana con fechas explicitas (supabase-league-promotions-fix.sql)
--   3) el reparto de golpe cuando hace falta una division nueva (supabase-league-bulk-split-new-division.sql)
--
-- El "promoted"/"relegated" de cada jugador ahora se calcula comparando su division ANTES
-- y DESPUES de aplicar TODOS los movimientos de esta funcion (guardado en una tabla
-- temporal al principio) - asi funciona igual de bien tanto con el ascenso/descenso normal
-- de 3 personas como con el reparto de golpe de una division nueva, sin tener que duplicar
-- la logica de cada caso.

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
  last_week_start timestamptz;
  last_week_end timestamptz;
  this_week_start date;
  extra_divisions int;
begin
  last_week_end := date_trunc('week', now());
  last_week_start := last_week_end - interval '7 days';
  this_week_start := last_week_end::date;

  select coalesce(max(league_division), 1) into max_division from public.profiles;
  update public.profiles set league_division = max_division where league_division is null;

  -- snapshot de la division de cada jugador ANTES de mover a nadie - se compara al final
  -- con la division ya definitiva para saber quien ha ascendido/descendido de verdad
  create temporary table league_promo_snapshot on commit drop as
  select id as player_id, league_division as old_division
  from public.profiles where league_division is not null;

  -- ---- guardar el resumen de la semana que se cierra (rank/total/premio de 30 monedas al
  -- 1º de cada division) - promoted/relegated se calculan mas abajo, al final ----
  with ranked as (
    select
      p.id as player_id,
      p.league_division,
      coalesce(round(avg(m.score)), 0) as week_score,
      row_number() over (partition by p.league_division order by coalesce(round(avg(m.score)), 0) desc) as rank_in_division,
      count(*) over (partition by p.league_division) as total_in_division
    from public.profiles p
    join public.solo_matches m
      on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
    group by p.id, p.league_division
    having count(m.score) >= 3
  )
  insert into public.weekly_recap (player_id, week_start, division, week_score, rank_in_division, total_in_division, promoted, relegated, coins_awarded)
  select
    r.player_id, this_week_start, r.league_division, r.week_score, r.rank_in_division, r.total_in_division,
    false, false, -- placeholder, se rellena al final comparando con el snapshot
    case when r.rank_in_division = 1 then 30 else 0 end
  from ranked r
  on conflict (player_id, week_start) do nothing;

  update public.profiles p
  set coins = coins + r.coins_awarded
  from public.weekly_recap r
  where r.player_id = p.id and r.week_start = this_week_start and r.coins_awarded > 0;
  -- ---- fin resumen ----

  select count(*) into eligible_count from (
    select p.id
    from public.profiles p
    join public.solo_matches m
      on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
    group by p.id
    having count(m.score) >= 3
  ) active_last_week;
  target_divisions := greatest(1, ceil(eligible_count / 20.0))::int;

  -- ascensos y descensos normales (3 sube / 3 baja) para todas las divisiones EXCEPTO la
  -- ultima
  for d in 1..max_division - 1 loop
    with ranked as (
      select p.id as player_id,
        coalesce(round(avg(m.score)), 0) as week_score
      from public.profiles p
      join public.solo_matches m
        on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
      where p.league_division = d
      group by p.id
      having count(m.score) >= 3
    )
    update public.profiles
    set league_division = greatest(1, d - 1)
    where id in (select player_id from ranked order by week_score desc limit 3);

    with ranked as (
      select p.id as player_id,
        coalesce(round(avg(m.score)), 0) as week_score
      from public.profiles p
      join public.solo_matches m
        on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
      where p.league_division = d
      group by p.id
      having count(m.score) >= 3
    )
    update public.profiles
    set league_division = d + 1
    where id in (select player_id from ranked order by week_score asc limit 3);
  end loop;

  -- la ULTIMA division: el top 3 asciende igual que siempre
  with ranked as (
    select p.id as player_id,
      coalesce(round(avg(m.score)), 0) as week_score
    from public.profiles p
    join public.solo_matches m
      on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
    where p.league_division = max_division
    group by p.id
    having count(m.score) >= 3
  )
  update public.profiles
  set league_division = greatest(1, max_division - 1)
  where id in (select player_id from ranked order by week_score desc limit 3);

  extra_divisions := greatest(0, target_divisions - max_division);

  if extra_divisions > 0 then
    -- hacen falta (extra_divisions) divisiones nuevas: reparte de golpe el resto de la
    -- ultima division en grupos por puntuacion real (ver supabase-league-bulk-split-new-division.sql)
    with candidatos as (
      select p.id, coalesce(avg(m.score), 0) as week_score
      from public.profiles p
      left join public.solo_matches m
        on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
      where p.league_division = max_division
      group by p.id
    ),
    grupos as (
      select id, ntile(extra_divisions + 1) over (order by week_score desc) as grupo
      from candidatos
    )
    update public.profiles p
    set league_division = max_division - 1 + g.grupo
    from grupos g
    where g.id = p.id;
  end if;

  update public.profiles set league_division = target_divisions where league_division > target_divisions;
  update public.profiles set league_division = 1 where league_division < 1;

  -- ---- ya se ha movido a todo el mundo: comparamos con el snapshot inicial para saber de
  -- verdad quien ha ascendido/descendido, sea cual sea el mecanismo que lo haya movido ----
  update public.weekly_recap wr
  set promoted = (p.league_division < s.old_division),
      relegated = (p.league_division > s.old_division)
  from public.profiles p, league_promo_snapshot s
  where wr.week_start = this_week_start
    and wr.player_id = p.id
    and s.player_id = p.id;
end;
$$;
