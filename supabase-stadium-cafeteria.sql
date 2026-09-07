-- PuckSlide: cafeterias como INVERSION (fase 9, 2026-09-07)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario: "las cafeterias deberian ser una inversion que reporten dinero
-- tambien y tengan gastos de mantenimiento y productos, generan ganancias dependiendo de
-- la asistencia al estadio, cuanto mayor y mejor sea el estadio mas premium pueden ser".
--
-- Antes las cafeterias eran decoracion gratis que se desbloqueaba sola al llegar a 350
-- asientos. Ahora:
--   - Nivel 1 (basica): se COMPRA (80 monedas) una vez tienes 350 asientos construidos.
--   - Nivel 2 (premium): se COMPRA (150 monedas) una vez tienes nivel 1 Y material
--     "moderna" (tier 3) o mejor - un estadio mejor construido puede tener cafeterias
--     mejores, tal cual pedido.
--   - Cada partida online generan un ingreso segun la asistencia real de esa partida
--     (igual de espiritu que el bono de asistencia de las gradas) menos un gasto fijo de
--     mantenimiento/producto - la premium gana mas por espectador pero tambien cuesta mas.
--
-- IMPORTANTE: estos numeros tienen que coincidir EXACTAMENTE con
-- CAFETERIA_TIER_PRICE/CAFETERIA_REVENUE_PER/CAFETERIA_COST en index.html (ese lado solo
-- se usa para mostrar precios y el desglose en pantalla - el dinero de verdad siempre sale
-- de aqui, award_match_coins).

-- 1) columna nueva en profiles
alter table public.profiles
  add column if not exists cafeteria_tier integer not null default 0;

-- 2) comprar/mejorar las cafeterias - una sola funcion decide segun el nivel actual
create or replace function public.buy_cafeteria_upgrade()
returns jsonb  -- { ok: boolean, reason?: text }
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  price_tier1 constant integer := 80;
  price_tier2 constant integer := 150;
  required_material_tier2 constant integer := 3; -- "moderna"
begin
  select coins, seats_built, material_tier, cafeteria_tier into prof from public.profiles where id = auth.uid();

  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  if coalesce(prof.cafeteria_tier, 0) = 0 then
    if coalesce(prof.seats_built, 0) < 350 then
      return jsonb_build_object('ok', false, 'reason', 'phase_not_built');
    end if;
    if prof.coins < price_tier1 then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_coins');
    end if;
    update public.profiles set coins = coins - price_tier1, cafeteria_tier = 1 where id = auth.uid();
    return jsonb_build_object('ok', true);
  elsif prof.cafeteria_tier = 1 then
    if coalesce(prof.material_tier, 1) < required_material_tier2 then
      return jsonb_build_object('ok', false, 'reason', 'quality_upgrade_required');
    end if;
    if prof.coins < price_tier2 then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_coins');
    end if;
    update public.profiles set coins = coins - price_tier2, cafeteria_tier = 2 where id = auth.uid();
    return jsonb_build_object('ok', true);
  else
    return jsonb_build_object('ok', false, 'reason', 'already_built');
  end if;
end;
$$;

-- 3) award_match_coins: identico a supabase-stadium-division-multiplier-sync.sql (la ultima
-- version), con el ingreso/gasto de las cafeterias añadido - se calcula sobre la misma
-- asistencia (attendance) ya calculada para el bono de las gradas, DESPUES de calcularla
-- (no afecta a la ocupacion en si, solo genera/gasta monedas aparte).
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
  cafeteria_revenue integer := 0;
  cafeteria_cost integer := 0;
  cafeteria_net integer;
  net integer;
  dow integer;
  parking_bonus constant numeric := 0.12;
  parking_max_spots constant integer := 14;
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;

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

      dow := extract(isodow from now()); -- 6 = sabado, 7 = domingo
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

  -- cafeterias: ingreso segun asistencia (mas generoso en premium), gasto fijo de
  -- mantenimiento/producto (tambien mayor en premium) - solo si el jugador tiene alguna
  if coalesce(prof.cafeteria_tier, 0) = 1 then
    cafeteria_revenue := floor(attendance / 40.0)::integer;
    cafeteria_cost := 1;
  elsif coalesce(prof.cafeteria_tier, 0) = 2 then
    cafeteria_revenue := floor(attendance / 25.0)::integer;
    cafeteria_cost := 3;
  end if;
  cafeteria_net := case when coalesce(prof.cafeteria_tier, 0) > 0 then cafeteria_revenue - cafeteria_cost else null end;

  maintenance_fee := least(5, floor(coalesce(prof.seats_built, 0) / 70.0))::integer;
  net := score_coins + attendance_bonus - maintenance_fee + coalesce(cafeteria_net, 0);

  update public.profiles
  set coins = greatest(0, coins + net)
  where id = auth.uid();

  return jsonb_build_object(
    'score_coins', score_coins,
    'attendance', attendance,
    'attendance_bonus', attendance_bonus,
    'maintenance_fee', maintenance_fee,
    'cafeteria_net', cafeteria_net,
    'net', net
  );
end;
$$;
