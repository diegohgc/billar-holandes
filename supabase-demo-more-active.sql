-- PuckSlide: jugadores demo mas activos (varias partidas al dia, no solo 1)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-08-27: con 1 sola partida diaria por jugador demo se
-- quedaban cortos. Se cambia el cron para que cada jugador demo juegue entre 3 y 7
-- partidas al dia (numero aleatorio por jugador cada vez), con las horas repartidas a lo
-- largo del dia (no todas a las 4:00 UTC), para que no se note un patron artificial.
--
-- Las monedas del dia se suman de TODAS esas partidas juntas (antes solo contaba 1
-- partida = 1 racion de monedas; ahora con varias partidas ganan bastantes mas monedas
-- cada dia, coherente con jugar mas). El crecimiento de asientos/reformas del estadio se
-- deja igual que antes (un empujon pequeño al dia, no por partida - si no, el estadio se
-- llenaria demasiado rapido).
--
-- Aplicado 2026-08-27. Sustituye el cron de supabase-demo-stadium-growth.sql (mismo
-- nombre de tarea, se re-programa).

select cron.unschedule('refresh_demo_players_matches');

select cron.schedule(
  'refresh_demo_players_matches',
  '0 4 * * *',  -- se dispara a las 4:00 UTC, pero las partidas que genera se reparten por todo el dia anterior
  $$
  with matches_per_player as (
    select id, demo_avg_score, (3 + floor(random() * 5))::int as num_matches -- 3 a 7 partidas/dia
    from public.profiles
    where is_demo = true
  ),
  new_matches as (
    insert into public.solo_matches (player_id, score, sets, played_at)
    select
      mp.id,
      greatest(10, mp.demo_avg_score + (floor(random() * 21) - 10)::int) as score,
      greatest(0, least(4, round(
        (greatest(10, mp.demo_avg_score + (floor(random() * 21) - 10)::int)) / 28.0
      )))::int as sets,
      now() - (floor(random() * 22)::int || ' hours')::interval - (floor(random() * 60)::int || ' minutes')::interval
    from matches_per_player mp, generate_series(1, mp.num_matches)
    returning player_id, score
  ),
  coins_per_player as (
    select player_id, sum(greatest(0, floor(score / 10.0)))::int as earned
    from new_matches
    group by player_id
  )
  update public.profiles p
  set
    coins = p.coins + coalesce(cp.earned, 0),
    seats_built = least(200, p.seats_built + floor(random() * 6)::int),
    material_tier = case
      when p.seats_built >= 200 and p.material_tier < 4 and random() < 0.12 then p.material_tier + 1
      else p.material_tier
    end,
    renovated_seats = case
      when p.seats_built >= 200 and p.material_tier < 4 and random() < 0.12 then 0
      else p.renovated_seats
    end
  from coins_per_player cp
  where p.id = cp.player_id;
  $$
);
