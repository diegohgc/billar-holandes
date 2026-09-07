-- PuckSlide: parking POR FASES (2026-09-07)
-- ------------------------------------------------------------------------------------
-- Sustituye supabase-stadium-parking.sql: el parking pasa de ser una compra unica
-- (parking_built boolean, funcion buy_parking) a construirse por fases con packs de 1
-- plaza, igual que los asientos - pedido por el usuario: "el parking se debe construir
-- como el estadio, por fases".
--
-- Si NUNCA ejecutaste supabase-stadium-parking.sql (la version anterior), no pasa nada:
-- este script crea todo desde cero igualmente. Ejecutalo tal cual, de arriba a abajo.

-- 1) columna nueva: plazas construidas (reemplaza a parking_built si existiera)
alter table public.profiles
  add column if not exists parking_spots_built integer not null default 0;

-- si la version anterior (parking_built boolean) llego a crearse y alguien ya lo habia
-- comprado, migramos ese "todo" a las 14 plazas completas antes de borrar la columna vieja
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles' and column_name = 'parking_built') then
    update public.profiles set parking_spots_built = 14 where parking_built = true;
    alter table public.profiles drop column parking_built;
  end if;
end $$;

-- 2) la funcion vieja de compra unica ya no existe
drop function if exists public.buy_parking();

-- 3) comprar un pack de 1 plaza de parking
create or replace function public.buy_parking_pack()
returns jsonb  -- { ok: boolean, reason?: text }
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  price constant integer := 18;
  max_spots constant integer := 14;
begin
  select coins, parking_spots_built into prof from public.profiles where id = auth.uid();

  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  if coalesce(prof.parking_spots_built, 0) >= max_spots then
    return jsonb_build_object('ok', false, 'reason', 'already_built');
  end if;

  if prof.coins < price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins');
  end if;

  update public.profiles
  set coins = coins - price, parking_spots_built = coalesce(parking_spots_built, 0) + 1
  where id = auth.uid();

  return jsonb_build_object('ok', true);
end;
$$;

-- 4) award_match_coins: igual que en supabase-stadium-finance-breakdown.sql, con el bono
-- del parking ahora PROPORCIONAL a la fraccion de plazas construidas (antes era todo o
-- nada). Mismo valor y formula que PARKING_OCCUPANCY_BONUS/PARKING_MAX_SPOTS en index.html
-- - deben ir siempre a la par.
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
