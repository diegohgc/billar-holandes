-- PuckSlide: desglose economico al terminar una partida (espectadores, recaudacion por
-- asistencia y gastos de mantenimiento) - pedido por el usuario el 2026-09-06 para poder
-- mostrar esa informacion en una pantalla que el jugador pueda leer con calma (no un aviso
-- que desaparece solo), en vez del simple numero neto que devolvia hasta ahora.
-- ------------------------------------------------------------------------------------
-- award_match_coins() hasta ahora devolvia SOLO un integer (el balance neto de la partida).
-- Esta version calcula exactamente lo mismo (mismas formulas, ningun cambio de economia),
-- pero devuelve un jsonb con el desglose completo para que el cliente pueda mostrar cada
-- concepto por separado. Como cambia el tipo de retorno hay que borrar la funcion anterior
-- antes de crear la nueva (Postgres no permite CREATE OR REPLACE si cambia el tipo).

drop function if exists public.award_match_coins(integer);

create or replace function public.award_match_coins(match_score integer)
returns jsonb
-- {
--   score_coins:       monedas ganadas por la puntuacion de esta partida,
--   attendance:        espectadores reales en las gradas esta partida,
--   attendance_bonus:  monedas ganadas por esa asistencia,
--   maintenance_fee:   monedas descontadas por el mantenimiento del estadio,
--   net:               balance neto = score_coins + attendance_bonus - maintenance_fee
--                       (puede ser negativo; el saldo total del jugador nunca baja de 0)
-- }
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

      dow := extract(isodow from now()); -- 6 = sabado, 7 = domingo
      if dow in (6, 7) then
        occupancy := least(1.0, occupancy + 0.15);
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
