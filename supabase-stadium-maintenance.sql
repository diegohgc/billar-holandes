-- PuckSlide: mantenimiento del estadio (progresivo, con tope)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-09-05: cobrar una pequeña cuota de mantenimiento del
-- estadio en cada partida online, para que un estadio grande tambien tenga un coste, no
-- solo ventajas. Progresivo segun lo construido (seats_built), NO un fijo igual para
-- todos - quien no ha construido nada no paga nada, y el tope se alcanza justo con el
-- aforo maximo:
--
--   mantenimiento = min(5, floor(seats_built / 70))
--
--   0-69 asientos construidos:    0 monedas
--   70-139:                       1 moneda
--   140-209:                      2 monedas
--   210-279:                      3 monedas
--   280-349:                      4 monedas
--   350 (aforo completo):         5 monedas (tope)
--
-- Se descuenta del MISMO ingreso de esa partida (puntuacion + asistencia), nunca aparte,
-- para que nunca pueda dejar el saldo por debajo de 0 (el check coins >= 0 lo impediria y
-- la funcion fallaria) - de ahi el greatest(0, ...) final. Si el mantenimiento supera lo
-- ganado esa partida, el balance neto sale negativo (el cliente ya lo muestra en rojo,
-- ver showCoinToast en index.html) pero el saldo total nunca baja de 0.
--
-- Sustituye award_match_coins() de supabase-stadium-crowd-bonus.sql (mismo nombre y firma,
-- el cliente no necesita ningun cambio en la llamada).

create or replace function public.award_match_coins(match_score integer)
returns integer  -- balance neto de la partida (puntuacion + asistencia - mantenimiento), puede ser negativo
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

  return net;
end;
$$;
