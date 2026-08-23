-- PuckSlide: jugadores de demostracion (perfiles sinteticos)
-- ------------------------------------------------------------
-- Objetivo: dar sensacion de comunidad activa mientras la base de jugadores reales es pequeña.
-- 47 perfiles ficticios repartidos por Europa, EE.UU., Sudamerica y Asia, con partidas que se
-- van refrescando solas via pg_cron (sin intervencion manual, para siempre).
--
-- Decidido con el usuario el 2026-08-22. Lista completa de nombres/paises documentada tambien
-- en la conversacion de Claude Code de esa fecha.
--
-- CÓMO DESHACER ESTO en el futuro (si se quiere quitar):
--   select cron.unschedule('refresh_demo_players_matches');
--   delete from public.profiles where is_demo = true;  -- borra en cascada sus solo_matches
--
-- Tras el sembrado inicial, se retocaron a mano 10 nombres para que no se noten "de laboratorio"
-- (algunos sin apellido, en mayusculas, en minusculas o sin tildes) - ver update-nombres-demo.sql
-- para el detalle exacto de esos 10 cambios.

-- ---- 1) columnas de control + quitar la exigencia de cuenta real de Google ----
alter table public.profiles
  add column if not exists is_demo boolean not null default false,
  add column if not exists demo_avg_score int;

-- los perfiles normales SIGUEN exigiendo login real (esto solo afecta a como se crea la fila,
-- no cambia las politicas de RLS ni el flujo normal de la app)
alter table public.profiles drop constraint if exists profiles_id_fkey;

-- ---- 2) sembrar los 47 perfiles + 4 partidas iniciales cada uno (fechadas en los ultimos
-- dias, para que aparezcan ya mismo tanto en la clasificacion de media como en la de record) ----
do $$
declare
  players jsonb := '[
    {"name":"Sofía Martínez","country":"ES","avg":78},
    {"name":"Pablo Ruiz","country":"ES","avg":61},
    {"name":"Lucía Navarro","country":"ES","avg":88},
    {"name":"Julien Moreau","country":"FR","avg":69},
    {"name":"Camille Dubois","country":"FR","avg":92},
    {"name":"Antoine Lefevre","country":"FR","avg":57},
    {"name":"Lukas Schneider","country":"DE","avg":74},
    {"name":"Hannah Weber","country":"DE","avg":63},
    {"name":"Felix Bauer","country":"DE","avg":50},
    {"name":"Giulia Ricci","country":"IT","avg":81},
    {"name":"Marco Bianchi","country":"IT","avg":58},
    {"name":"Chiara Romano","country":"IT","avg":71},
    {"name":"Tiago Costa","country":"PT","avg":66},
    {"name":"Beatriz Alves","country":"PT","avg":47},
    {"name":"Rui Pereira","country":"PT","avg":76},
    {"name":"Oliver Bennett","country":"GB","avg":89},
    {"name":"Emily Clarke","country":"GB","avg":60},
    {"name":"James Wilson","country":"GB","avg":53},
    {"name":"Sanne de Vries","country":"NL","avg":95},
    {"name":"Daan Bakker","country":"NL","avg":68},
    {"name":"Lotte Jansen","country":"NL","avg":72},
    {"name":"Erik Lindqvist","country":"SE","avg":55},
    {"name":"Elin Bergström","country":"SE","avg":79},
    {"name":"Oskar Nilsson","country":"SE","avg":62},
    {"name":"Ryan Mitchell","country":"US","avg":84},
    {"name":"Ashley Turner","country":"US","avg":67},
    {"name":"Brandon Lee","country":"US","avg":49},
    {"name":"Martín Gómez","country":"AR","avg":73},
    {"name":"Valeria Fernández","country":"AR","avg":59},
    {"name":"Camila Torres","country":"MX","avg":65},
    {"name":"Diego Ramírez","country":"MX","avg":52},
    {"name":"Lucas Oliveira","country":"BR","avg":87},
    {"name":"Beatriz Souza","country":"BR","avg":70},
    {"name":"Valentina Rojas","country":"CO","avg":56},
    {"name":"Andrés Molina","country":"CO","avg":77},
    {"name":"Sebastián Vidal","country":"CL","avg":64},
    {"name":"Javiera Contreras","country":"CL","avg":48},
    {"name":"Haruto Sato","country":"JP","avg":91},
    {"name":"Yuki Tanaka","country":"JP","avg":63},
    {"name":"Ji-woo Kim","country":"KR","avg":75},
    {"name":"Min-jun Park","country":"KR","avg":58},
    {"name":"Wei Zhang","country":"CN","avg":69},
    {"name":"Mei Chen","country":"CN","avg":82},
    {"name":"Minh Nguyen","country":"VN","avg":54},
    {"name":"Linh Tran","country":"VN","avg":71},
    {"name":"Ananya Sharma","country":"IN","avg":66},
    {"name":"Rohan Mehta","country":"IN","avg":46}
  ]'::jsonb;
  p jsonb;
  new_id uuid;
  i int;
  match_score int;
  match_sets int;
begin
  for p in select * from jsonb_array_elements(players)
  loop
    insert into public.profiles (id, name, country, is_demo, demo_avg_score)
    values (gen_random_uuid(), p->>'name', p->>'country', true, (p->>'avg')::int)
    returning id into new_id;

    -- 4 partidas iniciales, puntuacion con algo de variacion natural alrededor de su media,
    -- fechadas en los ultimos ~6 dias (dentro de la ventana de 7 dias que exige el ranking)
    for i in 1..4 loop
      match_score := greatest(10, (p->>'avg')::int + (floor(random() * 21) - 10)::int);
      match_sets := greatest(0, least(4, round(match_score / 28.0)));
      insert into public.solo_matches (player_id, score, sets, played_at)
      values (
        new_id, match_score, match_sets,
        now() - (floor(random() * 6)::int || ' days')::interval
            - (floor(random() * 20)::int || ' hours')::interval
      );
    end loop;
  end loop;
end $$;

-- ---- 3) refresco automatico para siempre: una partida nueva cada 2 dias por jugador demo,
-- para que nunca caduquen de la clasificacion de media (regla de los 7 dias de inactividad) ----
create extension if not exists pg_cron;

select cron.schedule(
  'refresh_demo_players_matches',
  '0 4 */2 * *',  -- las 4:00 UTC, cada 2 dias
  $$
  insert into public.solo_matches (player_id, score, sets, played_at)
  select
    id,
    greatest(10, demo_avg_score + (floor(random() * 21) - 10)::int) as score,
    greatest(0, least(4, round(
      (greatest(10, demo_avg_score + (floor(random() * 21) - 10)::int)) / 28.0
    )))::int as sets,
    now()
  from public.profiles
  where is_demo = true;
  $$
);
