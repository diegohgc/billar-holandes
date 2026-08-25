-- PuckSlide: sistema de ligas con ascensos y descensos
-- ------------------------------------------------------------------------------------
-- Idea: ademas de la clasificacion de media/record (historica, sin memoria), un sistema
-- de "ligas" semanales tipo Duolingo - cada jugador esta en una division (1a = la mejor),
-- compite esa semana contra los demas de su misma division, y al cierre de la semana
-- ascienden los 3 primeros (division - 1) y descienden los 3 ultimos (division + 1) - bajado
-- de 5 a 3 el 2026-08-25 porque con pocos jugadores por division (~13-15) mover a 10 de golpe
-- (5 arriba + 5 abajo) era demasiado movimiento cada semana.
--
-- Sin subgrupos por ahora (una sola division = un solo grupo, no divide en salas de 30 como
-- Duolingo) - se puede añadir mas adelante si una division llega a tener cientos de jugadores.
--
-- El NUMERO de divisiones no esta fijado a 10: se calcula solo cada semana segun cuanta
-- gente ha jugado esa semana (objetivo ~15 jugadores por division), sin tope maximo. Si la
-- base de jugadores crece mucho, saldran mas divisiones solas, sin tocar nada aqui.
--
-- Puntuacion semanal: SUMA de las puntuaciones de esta semana (no la media) - premia jugar
-- mas, que es justo el objetivo de esto (enganchar), a diferencia de la clasificacion de
-- media de siempre que no premia el volumen de partidas.
--
-- Aplicado 2026-08-25.

-- ---- 1) columna de division (1 = la mejor, numeros mas altos = divisiones mas bajas) ----
alter table public.profiles add column if not exists league_division int;

-- ---- 2) vista en vivo: puntuacion de ESTA semana (lunes a domingo) por jugador ----
create or replace view public.league_ranking as
select
  p.id as player_id,
  p.name,
  p.country,
  p.league_division,
  coalesce(sum(m.score), 0) as week_score,
  count(m.score) as matches_played
from public.profiles p
left join public.solo_matches m
  on m.player_id = p.id and m.played_at >= date_trunc('week', now())
group by p.id, p.name, p.country, p.league_division;

-- ---- 3) sembrado inicial: reparte a todo el mundo por division segun su mejor puntuacion
-- historica (para no empezar con todos amontonados en la division 1) ----
do $$
declare
  target_divisions int;
begin
  select greatest(1, ceil(count(*) / 15.0))::int into target_divisions from public.profiles;

  with best_scores as (
    select p.id, coalesce(max(m.score), 0) as best
    from public.profiles p
    left join public.solo_matches m on m.player_id = p.id
    group by p.id
  ),
  buckets as (
    select id, ntile(target_divisions) over (order by best desc) as bucket
    from best_scores
  )
  update public.profiles p
  set league_division = b.bucket
  from buckets b
  where b.id = p.id and p.league_division is null;
end $$;

-- ---- 4) ascensos/descensos semanales + reajuste automatico del numero de divisiones ----
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
begin
  -- jugadores nuevos sin division asignada (se han registrado desde el ultimo corte):
  -- se colocan al fondo de todo para empezar
  select coalesce(max(league_division), 1) into max_division from public.profiles;
  update public.profiles set league_division = max_division where league_division is null;

  -- cuanta gente ha jugado esta semana - eso decide cuantas divisiones hacen falta
  select count(*) into eligible_count from public.league_ranking where matches_played > 0;
  target_divisions := greatest(1, ceil(eligible_count / 15.0))::int;

  -- ascensos y descensos, division por division, segun la clasificacion de ESTA semana
  for d in 1..max_division loop
    update public.profiles
    set league_division = greatest(1, d - 1)
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played > 0
      order by week_score desc
      limit 3
    );

    update public.profiles
    set league_division = d + 1
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played > 0
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

create extension if not exists pg_cron;

select cron.schedule(
  'run_league_promotions_weekly',
  '5 0 * * 1', -- lunes 00:05 UTC - justo al empezar la semana (date_trunc('week', ...) usa lunes)
  $$ select public.run_league_promotions(); $$
);
