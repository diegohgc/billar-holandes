-- PuckSlide: arreglar ascensos/descensos semanales (bug critico reportado por el usuario
-- el 2026-09-09: "en vez de hacer ascensos y descensos, ha creado una primera division con
-- todos los jugadores y los que se registraron directamente a segunda")
-- ------------------------------------------------------------------------------------
-- CAUSA RAIZ: run_league_promotions() se dispara el lunes a las 00:05 UTC, es decir, justo
-- DESPUES de que la semana ya haya cambiado. La vista league_ranking calcula week_score y
-- matches_played con date_trunc('week', now()) - en el instante en que la funcion corre,
-- "now()" ya pertenece a la semana NUEVA (que acaba de empezar hace 5 minutos y no tiene
-- ninguna partida todavia), no a la semana que se acaba de cerrar. Eso provocaba dos cosas
-- a la vez:
--   1) eligible_count (cuanta gente ha jugado "esta semana") salia ~0 -> target_divisions
--      se quedaba en 1 -> el reencaje final ("league_division = target_divisions where
--      league_division > target_divisions") metia a TODO EL MUNDO en la division 1 de golpe.
--   2) Los ascensos/descensos ordenaban por week_score, que tambien salia 0 para todos en
--      ese instante - la clasificacion real de la semana que terminaba nunca se llegaba a
--      mirar, asi que "top 3 sube / ultimos 3 baja" nunca funciono de verdad.
--   3) Con la division 1 desbordada, los jugadores que se registraban esa semana disparaban
--      el sistema anti-amontonamiento (assign_new_player_league_division) y abrian solos una
--      division 2 nueva - de ahi "los que se registraron directamente a segunda".
--
-- SOLUCION: calcular la clasificacion con un rango de fechas EXPLICITO (la semana que se
-- acaba de cerrar: [ahora - 7 dias redondeado a lunes, ahora redondeado a lunes) ), en vez
-- de depender de la vista league_ranking (que siempre mira "la semana de ahora mismo"). Asi
-- da igual a que hora exacta del lunes se dispare el cron. De paso, se usa el mismo minimo
-- de 3 partidas que ya tiene league_ranking (antes esta funcion seguia usando >= 2, un
-- desajuste menor que tambien se corrige aqui).
--
-- No hace falta relanzar el cron.schedule (el nombre y la hora no cambian) - solo se
-- reemplaza el cuerpo de la funcion que ya llama.

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
begin
  last_week_end := date_trunc('week', now());
  last_week_start := last_week_end - interval '7 days';

  -- jugadores nuevos sin division asignada: se colocan al fondo de todo para empezar
  select coalesce(max(league_division), 1) into max_division from public.profiles;
  update public.profiles set league_division = max_division where league_division is null;

  -- cuanta gente jugo DE VERDAD la semana que se acaba de cerrar (no la semana nueva, vacia)
  select count(*) into eligible_count from (
    select p.id
    from public.profiles p
    join public.solo_matches m
      on m.player_id = p.id and m.played_at >= last_week_start and m.played_at < last_week_end
    group by p.id
    having count(m.score) >= 3
  ) active_last_week;
  target_divisions := greatest(1, ceil(eligible_count / 20.0))::int;

  -- ascensos y descensos, division por division, segun la clasificacion de la semana que
  -- se acaba de cerrar (rango de fechas explicito, no "ahora mismo")
  for d in 1..max_division loop
    with ranked as (
      select p.id as player_id,
        coalesce(round(avg(m.score)), 0) as week_score,
        count(m.score) as matches_played
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
        coalesce(round(avg(m.score)), 0) as week_score,
        count(m.score) as matches_played
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

  -- reencaja a todo el mundo dentro del numero de divisiones vigente esta semana (por si ha
  -- crecido o encogido la base de jugadores activos LA SEMANA PASADA, no la nueva vacia)
  update public.profiles set league_division = target_divisions where league_division > target_divisions;
  update public.profiles set league_division = 1 where league_division < 1;
end;
$$;
