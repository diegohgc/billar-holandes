-- PuckSlide: sincronizar la reduccion por division con el servidor (2026-09-07)
-- ------------------------------------------------------------------------------------
-- Encontrado durante el trabajo del parking: el cliente (computeLeagueOccupancy en
-- index.html) ya reducia la asistencia mostrada en pantalla (HUD, banner, "Mi Estadio",
-- perfil de otros jugadores) para quien no esta en la pelea de ascenso (fuera del top 6
-- de su division) y juega en una division baja - pero el servidor (award_match_coins)
-- nunca aplicaba esa reduccion, asi que lo que se veia en pantalla no coincidia con las
-- monedas que de verdad se pagaban. El usuario confirmo que el comportamiento correcto es
-- el del cliente: se aplica tambien aqui.
--
-- Formula (identica a index.html): si tu puesto (my_rank, empezando en 1) esta fuera del
-- top 6 de tu division, la ocupacion se multiplica por
--   greatest(0.4, 1 - (division - 1) * 0.15)
-- Sustituye a supabase-stadium-parking-phases.sql (la ultima version de award_match_coins) -
-- mismo calculo, solo con esta multiplicacion añadida en su sitio exacto (despues del bono
-- de fin de semana, antes del bono del parking - mismo orden que en el cliente).

drop function if exists public.award_match_coins(integer);

create or replace function public.award_match_coins(match_score integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  score_coins integer;
  total_players integer;
  my_rank integer;
  percentile numeric;
  occupancy numeric;
  attendance integer := 0;
  attendance_bonus integer := 0;
  maintenance_fee integer;
  net integer;
  dow integer;
  parking_bonus constant numeric := 0.12; -- igual que PARKING_OCCUPANCY_BONUS en index.html
  parking_max_spots constant integer := 14; -- igual que PARKING_MAX_SPOTS en index.html
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;

  select coins, seats_built, league_division, parking_spots_built into prof from public.profiles where id = auth.uid();

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

      dow := extract(isodow from now()); -- 6 = sabado, 7 = domingo
      if dow in (6, 7) then
        occupancy := least(1.0, occupancy + 0.15);
      end if;

      -- reduccion por division (2026-09-07, sincronizada con el cliente): fuera de la
      -- pelea de ascenso (top 6), las divisiones mas bajas tienen menos prestigio y por
      -- tanto menos asistencia
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

  maintenance_fee := least(5, floor(coalesce(prof.seats_built, 0) / 70.0))::integer;
  net := score_coins + attendance_bonus - maintenance_fee;

  update public.profiles
  set coins = greatest(0, coins + net)
  where id = auth.uid();

  return jsonb_build_object(
    'score_coins', score_coins,
    'attendance', attendance,
    'attendance_bonus', attendance_bonus,
    'maintenance_fee', maintenance_fee,
    'net', net
  );
end;
$$;
