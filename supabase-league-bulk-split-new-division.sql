-- PuckSlide: repartir de golpe (no goteo de 3/semana) cuando hace falta una division nueva
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-09-13, justo despues de quitar la division "de emergencia"
-- para jugadores nuevos (ver supabase-league-no-overflow-division.sql): ahora que los
-- jugadores nuevos SIEMPRE entran en la ultima division que exista, esa ultima division
-- puede hincharse mucho durante la semana (ej. 20 -> 40 si se registra mucha gente). Con el
-- ritmo normal de ascensos/descensos (3 por semana, siempre igual, decidido el 2026-08-25
-- para no mover a mucha gente de golpe) tardaria muchisimas semanas en repartirse bien en
-- divisiones nuevas del tamaño objetivo (~20).
--
-- IMPORTANTE (aclarado con el usuario): esto NO significa que se demote a 10-15 jugadores
-- que "no se lo merecen" - la nueva division se rellena SIEMPRE por puntuacion real de la
-- semana que se cierra, igual que cualquier ascenso/descenso normal. El cambio es de RITMO:
-- en vez de ir goteando 3 peor-clasificados por semana durante muchas semanas, en el
-- momento en que target_divisions (calculado como siempre, aforo activo / 20) exige una
-- division mas de las que existen ahora mismo, se reparte a todo el resto de la ultima
-- division en (huecos_que_faltan + 1) grupos por puntuacion, de una sola vez.
--
-- El resto de la funcion (ascensos/descensos de 3 en todas las divisiones que NO son la
-- ultima, calculo de target_divisions con la semana ya cerrada) sigue exactamente igual que
-- en supabase-league-promotions-fix.sql - solo cambia como se trata la ultima division.

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
  extra_divisions int;
begin
  last_week_end := date_trunc('week', now());
  last_week_start := last_week_end - interval '7 days';

  select coalesce(max(league_division), 1) into max_division from public.profiles;
  update public.profiles set league_division = max_division where league_division is null;

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
  -- ultima - la siguiente division ya existe de sobra, no hay nada especial que hacer aqui
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
    -- hacen falta (extra_divisions) divisiones nuevas: reparte a TODO el resto de la ultima
    -- division (los que no se acaban de ascender arriba) en (extra_divisions + 1) grupos
    -- segun su puntuacion real de la semana que se cierra - el mejor grupo se queda en
    -- max_division, cada grupo peor forma una division nueva (max_division+1, +2, ...).
    -- Quien no llego al minimo de 3 partidas cuenta como 0 (mismo criterio que el resto de
    -- la funcion), asi que cae en los grupos mas bajos, igual que en un descenso normal.
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

  -- reencaja a todo el mundo dentro del numero de divisiones vigente esta semana (por si ha
  -- encogido la base de jugadores activos)
  update public.profiles set league_division = target_divisions where league_division > target_divisions;
  update public.profiles set league_division = 1 where league_division < 1;
end;
$$;
