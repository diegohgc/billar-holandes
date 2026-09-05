-- PuckSlide: fase 4 del estadio - reforma de materiales ligada a la división, y asistencia
-- según la división actual
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-09-06 (idea original del 2026-08-30, aparcada hasta ahora):
--
--   1) Moderna y premium ya no dependen solo de tener el material anterior terminado -
--      ademas piden haber llegado ALGUNA VEZ a cierta división en las ligas (la MEJOR
--      división alcanzada históricamente, no la división actual - para no penalizar un
--      descenso temporal, una vez desbloqueado un material se queda desbloqueado siempre):
--        - Moderna (tier 3):  haber llegado alguna vez a la 2ª división o mejor
--        - Premium (tier 4):  haber llegado alguna vez a la 1ª división
--      Madera y hormigón siguen sin ninguna restricción de división.
--      IMPORTANTE: esto NO afecta al aforo/construcción (seats_built) - eso sigue
--      dependiendo solo de las fichas ganadas jugando, igual que siempre.
--
--   2) La asistencia de público (que ya variaba según tu posición semanal dentro de tu
--      propia división) ahora TAMBIEN baja segun el numero de división en si: las
--      divisiones mas bajas (numero mas alto) atraen menos publico, salvo que estes
--      peleando el ascenso (entre los 6 primeros de tu división) - ahi la emocion llena
--      las gradas igual que en 1ª división. Formula: multiplicador = max(0.4, 1 - (division-1)*0.15).
--
-- Requiere haber ejecutado antes supabase-leagues.sql, supabase-stadium-v4.sql y
-- supabase-stadium-maintenance.sql.

-- ---- 1) nueva columna: mejor división alcanzada alguna vez (NULL si nunca ha tenido división) ----
alter table public.profiles add column if not exists best_division_reached integer;

-- backfill para jugadores que ya tienen division asignada de antes de esta columna existir
update public.profiles set best_division_reached = league_division
where best_division_reached is null and league_division is not null;

-- ---- 2) trigger que la mantiene sola: cualquier UPDATE o INSERT que toque league_division
-- (la asignacion inicial, las promociones/descensos semanales, o un cambio manual) actualiza
-- best_division_reached automaticamente - asi no hace falta tocar run_league_promotions ni
-- assign_new_player_league_division, y no hay riesgo de que se desincronice ----
create or replace function public.track_best_division_reached()
returns trigger
language plpgsql
as $$
begin
  if new.league_division is not null then
    if TG_OP = 'INSERT' then
      new.best_division_reached := new.league_division;
    else
      new.best_division_reached := least(coalesce(old.best_division_reached, new.league_division), new.league_division);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_track_best_division_reached on public.profiles;
create trigger trg_track_best_division_reached
before insert or update of league_division on public.profiles
for each row
execute function public.track_best_division_reached();

-- ---- 3) buy_renovation_pack: añade el requisito de división para tier 3/4 ----
create or replace function public.buy_renovation_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  pack_price integer;
  new_renovated integer;
  required_division integer;
  prices integer[] := array[13, 20, 29];
begin
  select coins, seats_built, material_tier, renovated_seats, best_division_reached
    into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;
  if prof.material_tier >= 4 then
    return jsonb_build_object('ok', false, 'reason', 'all_upgraded');
  end if;

  -- tier objetivo = prof.material_tier + 1 (2, 3 o 4) - moderna (3) pide 2ª division o
  -- mejor, premium (4) pide 1ª - la 'mejor division alcanzada', no la actual
  required_division := case prof.material_tier + 1
    when 3 then 2
    when 4 then 1
    else null
  end;
  if required_division is not null and (prof.best_division_reached is null or prof.best_division_reached > required_division) then
    return jsonb_build_object('ok', false, 'reason', 'division_locked', 'required_division', required_division);
  end if;

  if prof.renovated_seats >= prof.seats_built then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_renovate');
  end if;

  pack_price := prices[prof.material_tier];
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  new_renovated := least(prof.renovated_seats + 10, prof.seats_built);

  if new_renovated >= 500 then
    update public.profiles
    set coins = coins - pack_price, renovated_seats = 0, material_tier = material_tier + 1
    where id = auth.uid();
  else
    update public.profiles
    set coins = coins - pack_price, renovated_seats = new_renovated
    where id = auth.uid();
  end if;

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 4) award_match_coins: añade el multiplicador de asistencia segun la division actual,
-- salvo que se este en zona de ascenso (top 6 de la division) ----
create or replace function public.award_match_coins(match_score integer)
returns integer
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
  attendance integer;
  attendance_bonus integer := 0;
  maintenance_fee integer;
  net integer;
  dow integer;
  in_promotion_race boolean;
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;

  select coins, seats_built, league_division into prof from public.profiles where id = auth.uid();

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

      -- fase 4: menos publico en divisiones mas bajas, salvo pelea de ascenso (top 6) -
      -- misma formula que computeLeagueOccupancy en el cliente (index.html)
      in_promotion_race := my_rank <= 6;
      if not in_promotion_race then
        occupancy := occupancy * greatest(0.4, 1 - (prof.league_division - 1) * 0.15);
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

  return net;
end;
$$;
