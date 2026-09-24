-- PuckSlide: 1 moneda por SET anotado (pedido por el usuario el 2026-09-24)
-- ------------------------------------------------------------------------------------
-- No hace falta ningun cambio de fechas/ranking aqui para el bug de "el resumen final
-- predice la siguiente partida" (ver aviso en chat) - ese bug era en el CLIENTE (index.html
-- llamaba a award_match_coins en paralelo con el insert de solo_matches, en vez de esperar a
-- que el insert terminara), ya corregido ahi. Esta migracion es solo la parte nueva pedida:
-- premiar los sets.
--
-- Cambios en award_match_coins:
--   - Nuevo parametro match_sets (con default 0, para no romper ninguna llamada vieja que
--     quedara en caché en algun cliente sin actualizar).
--   - Como cambia la firma de la funcion (antes 1 parametro, ahora 2), hace falta borrar la
--     version vieja de 1 parametro explicitamente - si no, Postgres se queda con las DOS
--     funciones a la vez (sobrecarga), y aunque no rompe nada, es confuso tener dos
--     definiciones distintas del mismo nombre conviviendo sin necesidad.
--   - sets_coins = match_sets (1 moneda por set, sin tope) se suma al neto y se devuelve en
--     el desglose para que el cliente lo pueda mostrar en la pantalla de resultados.
--   - Todo lo demas (asistencia, cafeteria, mantenimiento, bono de division/parking) se deja
--     EXACTAMENTE igual que la version actual en produccion, comprobada con
--     pg_get_functiondef antes de escribir esta migracion.

drop function if exists public.award_match_coins(integer);

create or replace function public.award_match_coins(match_score integer, match_sets integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  score_coins integer;
  sets_coins integer;
  total_players integer;
  my_rank integer;
  percentile numeric;
  occupancy numeric;
  attendance integer := 0;
  attendance_bonus integer := 0;
  maintenance_fee integer;
  cafeteria_revenue integer := 0;
  cafeteria_cost integer := 0;
  cafeteria_net integer;
  net integer;
  dow integer;
  parking_bonus constant numeric := 0.12;
  parking_max_spots constant integer := 140;
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;
  sets_coins := greatest(0, coalesce(match_sets, 0));

  select coins, seats_built, league_division, parking_spots_built, cafeteria_tier
    into prof from public.profiles where id = auth.uid();

  if prof.league_division is not null then
    select count(*) into total_players from public.league_ranking where league_division = prof.league_division;

    select rnk into my_rank from (
      select player_id, row_number() over (order by week_score desc) as rnk
      from public.league_ranking
      where league_division = prof.league_division
    ) ranked
    where ranked.player_id = auth.uid();

    if my_rank is not null and total_players > 0 then
      percentile := (my_rank - 1)::numeric / greatest(total_players - 1, 1);
      if percentile <= 0.15 then
        occupancy := 0.90;
      elsif percentile <= 0.5 then
        occupancy := 0.55;
      else
        occupancy := 0.20;
      end if;

      dow := extract(isodow from now());
      if dow in (6, 7) then
        occupancy := least(1.0, occupancy + 0.15);
      end if;

      if my_rank > 6 then
        occupancy := occupancy * greatest(0.4, 1 - (prof.league_division - 1) * 0.15);
      end if;

      if coalesce(prof.parking_spots_built, 0) > 0 then
        occupancy := least(1.0, occupancy + parking_bonus * least(1.0, prof.parking_spots_built::numeric / parking_max_spots));
      end if;

      attendance := round(occupancy * coalesce(prof.seats_built, 0));
      attendance_bonus := floor(attendance / 50.0)::integer;
    end if;
  end if;

  if coalesce(prof.cafeteria_tier, 0) = 1 then
    cafeteria_revenue := floor(attendance / 40.0)::integer;
    cafeteria_cost := 1;
  elsif coalesce(prof.cafeteria_tier, 0) = 2 then
    cafeteria_revenue := floor(attendance / 25.0)::integer;
    cafeteria_cost := 3;
  end if;
  cafeteria_net := case when coalesce(prof.cafeteria_tier, 0) > 0 then cafeteria_revenue - cafeteria_cost else null end;

  maintenance_fee := least(5, floor(coalesce(prof.seats_built, 0) / 70.0))::integer;
  net := score_coins + sets_coins + attendance_bonus - maintenance_fee + coalesce(cafeteria_net, 0);

  update public.profiles
  set coins = greatest(0, coins + net)
  where id = auth.uid();

  return jsonb_build_object(
    'score_coins', score_coins,
    'sets_coins', sets_coins,
    'attendance', attendance,
    'attendance_bonus', attendance_bonus,
    'maintenance_fee', maintenance_fee,
    'cafeteria_net', cafeteria_net,
    'net', net
  );
end;
$$;
