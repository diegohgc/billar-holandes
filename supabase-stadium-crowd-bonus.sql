-- PuckSlide: bono de monedas por asistencia de público
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-08-27: ademas de la moneda por cada 10 puntos, dar un
-- bono extra por la cantidad de publico que asiste a la partida - 1 moneda por cada 50
-- personas de aforo. El aforo real se calcula con dos factores:
--
--   1) Cuantos asientos tiene YA CONSTRUIDOS el jugador (seats_built) - un estadio mas
--      grande puede recibir mas publico, aunque el % de ocupacion sea el mismo. Esto
--      crea un bucle bonito: cuanto mas inviertes en el estadio, mas monedas puedes
--      llegar a ganar por partida.
--   2) El % de OCUPACION de esos asientos, segun la posicion del jugador en su division
--      de liga esa semana (ver supabase-leagues.sql / league_ranking):
--        - top 15% de la division:  90% de ocupacion
--        - siguiente hasta 50%:     55% de ocupacion
--        - resto:                   20% de ocupacion
--        - fin de semana (sabado o domingo, cuando cierra la liga): +15 puntos
--          porcentuales extra (tope 100%) - coincide con el dia de mas ambiente
--
-- Ejemplo: 100 asientos construidos, 2º de su division (top 15%) en sabado ->
-- ocupacion 90%+15%=100% -> 100 personas -> +2 monedas de bono esa partida.
--
-- Si el jugador aun no tiene division asignada (no ha jugado online lo suficiente esa
-- semana), no hay bono de asistencia esa partida - solo el de puntuacion, como siempre.
--
-- Aplicado 2026-08-27. Sustituye la funcion award_match_coins() de supabase-stadium.sql
-- (mismo nombre y firma, el cliente no necesita ningun cambio).

create or replace function public.award_match_coins(match_score integer)
returns integer  -- monedas ganadas en total (puntuacion + asistencia)
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
  dow integer;
begin
  score_coins := greatest(0, floor(match_score / 10.0))::integer;

  select seats_built, league_division into prof from public.profiles where id = auth.uid();

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

  update public.profiles
  set coins = coins + score_coins + attendance_bonus
  where id = auth.uid();

  return score_coins + attendance_bonus;
end;
$$;
