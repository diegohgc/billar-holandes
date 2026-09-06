-- PuckSlide: parking del estadio (fase 8, 2026-09-06)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario: "hacemos el parking? tiene que provocar que mas gente vaya al
-- estadio". Es una mejora COMPRABLE de una sola vez (no un pack incremental como los
-- asientos): una vez comprada, sube la ocupacion real del estadio (mas espectadores, mas
-- recaudacion por asistencia) para siempre. Precio fijo, alto a proposito (250 monedas) -
-- es un hito, no algo que se compre muchas veces.
--
-- IMPORTANTE: el bono de ocupacion (+12 puntos porcentuales, tope 100%) tiene que coincidir
-- EXACTAMENTE con PARKING_OCCUPANCY_BONUS en index.html (computeLeagueOccupancy) - ese es el
-- espejo cliente-side que se usa solo para mostrar el HUD/vista previa del estadio; el dinero
-- de verdad siempre se calcula aqui, en award_match_coins.
--
-- El resto de la formula de award_match_coins se deja EXACTAMENTE igual que en
-- supabase-stadium-finance-breakdown.sql (la ultima version que se ejecuto) - solo se añade
-- la lectura de parking_built y el bono de ocupacion, ningun otro cambio de economia.

-- 1) columna nueva en profiles
alter table public.profiles
  add column if not exists parking_built boolean not null default false;

-- 2) comprar el parking (compra unica, precio fijo)
create or replace function public.buy_parking()
returns jsonb  -- { ok: boolean, reason?: text }
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  price constant integer := 250;
begin
  select coins, parking_built into prof from public.profiles where id = auth.uid();

  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  if prof.parking_built then
    return jsonb_build_object('ok', false, 'reason', 'already_built');
  end if;

  if prof.coins < price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins');
  end if;

  update public.profiles
  set coins = coins - price, parking_built = true
  where id = auth.uid();

  return jsonb_build_object('ok', true);
end;
$$;

-- 3) award_match_coins: identico a supabase-stadium-finance-breakdown.sql, solo con el bono
-- de ocupacion del parking añadido justo antes de calcular la asistencia real.
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
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;

  select coins, seats_built, league_division, parking_built into prof from public.profiles where id = auth.uid();

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

      if coalesce(prof.parking_built, false) then
        occupancy := least(1.0, occupancy + parking_bonus);
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
