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
-- gente ha jugado esa semana (objetivo ~20 jugadores por division, subido de 15 el 2026-08-25),
-- sin tope maximo. Si la base de jugadores crece mucho, saldran mas divisiones solas.
--
-- Puntuacion semanal: MEDIA de las partidas de esta semana (no la suma) - cambiado el
-- 2026-08-25 porque con la suma ganaba siempre quien mas jugaba, no quien mejor jugaba. Con la
-- media, lo que engancha es que cada semana vuelves a competir "en igualdad" contra gente de tu
-- mismo nivel actual (a diferencia de la clasificacion general de siempre, que es historica).
--
-- MINIMO 2 partidas esa semana para que la puntuacion cuente (si no, marca 0) - añadido el
-- 2026-08-25 porque con la media pura, jugar 1 partida muy buena y no volver a arriesgarse
-- garantizaba una media perfecta sin mas esfuerzo. El juego avisa al jugador en pantalla tras su
-- primera partida de la semana para que sepa que necesita jugar otra.
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
  case when count(m.score) >= 2 then coalesce(round(avg(m.score)), 0) else 0 end as week_score,
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
  select greatest(1, ceil(count(*) / 20.0))::int into target_divisions from public.profiles;

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
  select count(*) into eligible_count from public.league_ranking where matches_played >= 2;
  target_divisions := greatest(1, ceil(eligible_count / 20.0))::int;

  -- ascensos y descensos, division por division, segun la clasificacion de ESTA semana
  for d in 1..max_division loop
    update public.profiles
    set league_division = greatest(1, d - 1)
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played >= 2
      order by week_score desc
      limit 3
    );

    update public.profiles
    set league_division = d + 1
    where id in (
      select player_id from public.league_ranking
      where league_division = d and matches_played >= 2
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

-- ---- 5) asignacion INMEDIATA de division a jugadores nuevos ----
-- antes, un jugador que se registraba a mitad de semana se quedaba sin division hasta el
-- siguiente lunes (cuando corria run_league_promotions y los colocaba al fondo). Con este
-- trigger, en cuanto se crea su perfil ya entra directamente en la division mas baja, sin
-- esperar al cron semanal - coherente con "entras en las ligas automaticamente en cuanto
-- juegas", que es lo que le decimos en la app. Añadido 2026-08-25.
--
-- IMPORTANTE (corregido el mismo dia, umbral subido a 20 el mismo dia tambien): si la ultima
-- division ya tiene ~20 jugadores, el nuevo NO se amontona ahi - abre una division nueva,
-- todavia mas abajo, solo para el/los jugadores nuevos. Asi nadie que ya estuviera establecido
-- en esa division puede verse arrastrado a bajar de division sin haberlo "perdido" de verdad
-- esa semana - solo entra gente nueva a lo nuevo.
--
-- Para que esa division nueva no se quede vacia/solitaria si solo se registran 1-3 jugadores
-- reales esa semana, se trae con ellos a un puñado de jugadores DEMO (is_demo=true) de la
-- division de arriba - a los ficticios les da igual de que division "vengan", y asi la nueva
-- division tiene algo de vida desde el primer momento en vez de sentirse un pueblo fantasma.
create or replace function public.assign_new_player_league_division()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  lowest_division int;
  lowest_division_count int;
begin
  if new.league_division is null then
    select coalesce(max(league_division), 1) into lowest_division from public.profiles;
    select count(*) into lowest_division_count from public.profiles where league_division = lowest_division;
    if lowest_division_count >= 20 then
      update public.profiles
      set league_division = lowest_division + 1
      where id in (
        select id from public.profiles
        where is_demo = true and league_division = lowest_division
        order by random()
        limit 8
      );
      lowest_division := lowest_division + 1;
    end if;
    new.league_division := lowest_division;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_assign_new_player_league_division on public.profiles;
create trigger trg_assign_new_player_league_division
  before insert on public.profiles
  for each row
  execute function public.assign_new_player_league_division();
