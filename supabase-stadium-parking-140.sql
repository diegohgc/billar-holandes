-- PuckSlide: subir el parking de 14 a 140 plazas, en packs de 10 (antes de 1)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-09-13: "veo que es capacidad para 14 coches pero deberian
-- ser 140 y aumentar el rango de construccion de 10 en 10 para 500 personas 14 es ridiculo".
--
-- Cambios (SOLO estos dos - las dos funciones de abajo son el cuerpo EXACTO que hay ahora
-- mismo en produccion, comprobado con pg_get_functiondef antes de escribir esta migracion,
-- para no repetir el error de la regresion del resumen semanal - ver
-- supabase-league-restore-weekly-recap.sql):
--   1) buy_parking_pack(): max_spots 14 -> 140, cada compra suma 10 plazas en vez de 1, y el
--      precio pasa de 18 (por 1 plaza) a 180 (por 10 plazas) - EXACTAMENTE el mismo precio
--      por plaza que antes (18/plaza), solo cambia el tamaño del pack. 140/10 = 14 packs
--      exactos, sin resto, asi que no hace falta logica de "ultimo pack parcial".
--   2) award_match_coins(): la constante parking_max_spots (usada para el bono de ocupacion
--      por parking) pasa de 14 a 140 - debe ir siempre a la par con PARKING_MAX_SPOTS del
--      cliente (ver index.html). Ni un solo caracter mas de esta funcion se toca.
--
-- El lado 3D (numero de coches, filas del parking) ya esta actualizado en index.html
-- (PARKING_MAX_SPOTS = 140, repartido en 10 filas x 7 huecos x 2 laterales, con los coches
-- ahora en InstancedMesh por rendimiento).

create or replace function public.buy_parking_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  price constant integer := 180;
  pack_size constant integer := 10;
  max_spots constant integer := 140;
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
  set coins = coins - price, parking_spots_built = coalesce(parking_spots_built, 0) + pack_size
  where id = auth.uid();

  return jsonb_build_object('ok', true);
end;
$$;

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
  parking_max_spots constant integer := 140;
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
