-- PuckSlide: el publico del resumen final = el publico que se vio durante la partida
-- ------------------------------------------------------------------------------------
-- Bug reportado por el usuario el 2026-10-09: durante la partida el HUD/estadio decia p.ej.
-- "130 espectadores", pero el resumen final decia "450", y en la partida siguiente el HUD
-- volvia a decir justo esos 450. Causa: el 2026-09-24 se cambio el cliente para que
-- award_match_coins se llamase DESPUES de guardar la partida en solo_matches; como
-- league_ranking es una vista en vivo, el resumen pasaba a usar la clasificacion CON la
-- partida ya contada (= el publico de la SIGUIENTE partida). El salto 130 -> 450 es el que
-- se produce cuando entra la 3a partida de la semana (a partir de ahi la puntuacion cuenta,
-- y la posicion en la liga salta de las ultimas a las primeras).
--
-- Arreglo (cliente, index.html): award_match_coins se llama ANTES de guardar la partida, asi
-- usa la clasificacion de antes de jugarla - la misma que vio el HUD al empezar.
--
-- Cambio en esta migracion: parametro opcional match_variance. El cliente sortea UNA vez la
-- variacion natural (+-6%) al cargar el estadio, la usa en el HUD y la manda aqui, asi el
-- numero del resumen final coincide EXACTO con el que se vio durante la partida (antes cada
-- lado sorteaba la suya y podian diferir un poco). Por seguridad el servidor la ACOTA a
-- 0.94 - 1.06 (el mismo rango del sorteo aleatorio): un cliente tramposo no gana nada que no
-- pudiera sacar por suerte. Si no se manda (clientes antiguos), se sortea aqui como antes.
-- Todo lo demas de la funcion es EXACTAMENTE el cuerpo que hay ahora en produccion.
--
-- Cambia la firma (3 parametros), asi que se borra la version de 2 parametros para no dejar
-- dos funciones conviviendo con el mismo nombre.

drop function if exists public.award_match_coins(integer, integer);

create or replace function public.award_match_coins(
  match_score integer,
  match_sets integer default 0,
  match_variance numeric default null
)
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

      -- variacion natural +-6%: la que mando el cliente (acotada a 0.94-1.06) para que el
      -- resumen final coincida con lo que se vio en el HUD; si no la mando, se sortea aqui
      -- (case explicito: greatest()/least() ignoran los NULL en Postgres, un coalesce no valdria)
      occupancy := least(1.0, greatest(0.0, occupancy * case
        when match_variance is null then 0.94 + random() * 0.12
        else least(1.06, greatest(0.94, match_variance))
      end));

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
