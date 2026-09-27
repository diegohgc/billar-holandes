-- PuckSlide: variacion natural en el aforo (pedido por el usuario el 2026-09-27)
-- ------------------------------------------------------------------------------------
-- El usuario reporto "siempre me pone 372 espectadores" - no era un bug de calculo: el aforo
-- es 100% determinista (posicion en la liga esta semana + fin de semana + plazas de parking),
-- y ninguno de esos tres factores cambia entre una partida y la siguiente del mismo dia, asi
-- que el numero salia clavado partida tras partida - correcto pero con pinta de bug.
--
-- Unico cambio: +-6% de variacion aleatoria sobre el aforo ya calculado, justo antes de
-- redondear a espectadores reales - mismo criterio que en computeLeagueOccupancy en el
-- cliente (ver index.html), deben ir siempre a la par. Todo lo demas de la funcion se deja
-- EXACTAMENTE igual que la version actual en produccion, comprobada con pg_get_functiondef
-- antes de escribir esta migracion.

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

      -- variacion natural: +-6% aleatorio, igual que en el cliente (computeLeagueOccupancy)
      occupancy := least(1.0, greatest(0.0, occupancy * (0.94 + random() * 0.12)));

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
