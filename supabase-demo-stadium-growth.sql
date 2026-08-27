-- PuckSlide: los jugadores demo tambien construyen su estadio poco a poco
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-08-27: los perfiles ficticios (is_demo = true, ver
-- supabase-demo-players.sql) deben ir avanzando su estadio igual que un jugador real,
-- para que las gradas que se ven al visitar su perfil desde la clasificacion no esten
-- siempre vacias/a cero.
--
-- Se engancha en el MISMO cron diario que ya reinserta sus partidas
-- (refresh_demo_players_matches, ver supabase-demo-players.sql) - se re-programa con el
-- mismo nombre añadiendo esta logica extra, sin tocar la parte de las partidas:
--   - coins += floor(score/10), igual formula que un jugador real (ver
--     supabase-stadium.sql: award_match_coins)
--   - seats_built avanza un poco cada dia (0-5 asientos aleatorios), tope 200
--   - una vez a 200, hay una probabilidad pequeña cada dia de que avance de fase de
--     material (renovated_seats se resetea a 0 y material_tier + 1, tope 4) - no hace
--     falta reproducir el detalle exacto de "packs de 10", es solo decorativo
--
-- Aplicado 2026-08-27. Requiere haber ejecutado antes supabase-demo-players.sql y
-- supabase-stadium-v2.sql (necesita las columnas seats_built/material_tier/renovated_seats).

select cron.unschedule('refresh_demo_players_matches');

select cron.schedule(
  'refresh_demo_players_matches',
  '0 4 * * *',  -- las 4:00 UTC, todos los dias
  $$
  with new_matches as (
    insert into public.solo_matches (player_id, score, sets, played_at)
    select
      id,
      greatest(10, demo_avg_score + (floor(random() * 21) - 10)::int) as score,
      greatest(0, least(4, round(
        (greatest(10, demo_avg_score + (floor(random() * 21) - 10)::int)) / 28.0
      )))::int as sets,
      now()
    from public.profiles
    where is_demo = true
    returning player_id, score
  )
  update public.profiles p
  set
    coins = p.coins + greatest(0, floor(nm.score / 10.0))::int,
    seats_built = least(200, p.seats_built + floor(random() * 6)::int),
    material_tier = case
      when p.seats_built >= 200 and p.material_tier < 4 and random() < 0.12 then p.material_tier + 1
      else p.material_tier
    end,
    renovated_seats = case
      when p.seats_built >= 200 and p.material_tier < 4 and random() < 0.12 then 0
      else p.renovated_seats
    end
  from new_matches nm
  where p.id = nm.player_id;
  $$
);
