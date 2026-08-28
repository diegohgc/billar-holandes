-- PuckSlide: recorte historico de puntuaciones por endurecer la regla del SET
-- ------------------------------------------------------------------------------------
-- Motivo: se va a endurecer la regla de "completar las 4 porterias" (SET) - las porterias
-- amarillas pasaran a reiniciarse en CADA tanda, no solo cuando se completa un SET (hasta
-- ahora se podian ir acumulando puertas de tandas anteriores). Esto hace mas dificil
-- conseguir SETs, asi que las puntuaciones nuevas seran mas bajas que las historicas. Para
-- que el ranking historico no quede artificialmente inflado frente a las partidas nuevas,
-- se recorta el score de las partidas YA JUGADAS con un % basado en la calidad de cada
-- jugador (su puntuacion media historica).
--
-- El % de recorte por jugador viene de una simulacion offline (no toca datos reales,
-- 200.000 partidas simuladas por escenario) comparando la regla actual vs la nueva segun
-- el nivel de acierto del jugador - los jugadores flojos dependian mas de ir acumulando
-- porterias entre tandas, asi que bajan mas; los buenos/expertos casi no se ven afectados
-- porque ya solian completar el SET dentro de la misma tanda. Resultado de la simulacion
-- (2026-08-28): flojo -15.2%, medio -12.0%, bueno -8.9%, experto -5.3%.
--
-- Los tramos se calculan de forma DINAMICA con percent_rank() sobre la poblacion real de
-- jugadores en el momento de ejecutar este script (nada de umbrales fijos tipo ">80
-- puntos" hardcodeados, para que el reparto siga siendo justo aunque cambie quien juega):
--   percentil 0-25%   (mas flojos) -> -15%
--   percentil 25-50%               -> -12%
--   percentil 50-75%               -> -9%
--   percentil 75-95%               -> -6%
--   percentil 95-100% (mejores)    -> -5%
-- Jugadores con menos de 3 partidas (media poco fiable, dato con mucho ruido) reciben el
-- tramo medio (-9%) por defecto, en vez de intentar clasificarlos con un solo dato suelto.
--
-- Como todos los rankings (ranking, ranking_monthly, ranking_yearly, ranking_record*,
-- ranking_countries*, league_ranking) son VIEWS calculadas en vivo sobre solo_matches, un
-- unico UPDATE sobre solo_matches.score ya se refleja automaticamente en todos ellos - no
-- hace falta tocar ninguna otra tabla ni vista.
--
-- IMPORTANTE: el UPDATE de la seccion 2 es irreversible sobre datos ya jugados. Si se
-- quiere poder deshacer despues, guardar antes una copia:
--   create table public.solo_matches_backup_pre_recorte as select * from public.solo_matches;
--
-- NO EJECUTAR TODAVIA. Revisar primero el SELECT de comprobacion (seccion 1), confirmar
-- que los recortes por jugador son los esperados, y solo entonces descomentar y ejecutar
-- el UPDATE de la seccion 2. Este cambio va ademas ligado a dos cosas que faltan por hacer
-- (no incluidas en este script): (a) el cambio de regla en index.html (reset de
-- attemptFilled al empezar cada tanda) y (b) recalibrar a los jugadores demo para que
-- jueguen ya con la regla nueva y reciban tambien su recorte segun su tramo.

-- ==================================================================================
-- 1) SELECT de comprobacion (NO modifica nada) - revisa el recorte que se aplicaria
--    a cada jugador antes de tocar un solo dato
-- ==================================================================================
with player_avg as (
  select
    p.id as player_id,
    p.name,
    avg(sm.score)::numeric(10,1) as avg_score,
    count(sm.score) as num_matches
  from public.profiles p
  join public.solo_matches sm on sm.player_id = p.id
  group by p.id, p.name
),
player_tier as (
  select
    player_id,
    name,
    avg_score,
    num_matches,
    case
      when num_matches < 3 then 0.5 -- fallback: tramo medio si la media es poco fiable
      else percent_rank() over (order by avg_score)
    end as pct
  from player_avg
)
select
  player_id,
  name,
  avg_score,
  num_matches,
  round(pct::numeric, 2) as percentil,
  case
    when pct < 0.25 then 0.15
    when pct < 0.50 then 0.12
    when pct < 0.75 then 0.09
    when pct < 0.95 then 0.06
    else 0.05
  end as recorte_pct
from player_tier
order by avg_score;

-- ==================================================================================
-- 2) UPDATE real: aplica el recorte a solo_matches.score
--    (comentado a proposito - descomentar solo cuando el SELECT de arriba se haya
--    revisado y los recortes por jugador sean los esperados)
-- ==================================================================================
/*
with player_avg as (
  select
    p.id as player_id,
    avg(sm.score)::numeric(10,1) as avg_score,
    count(sm.score) as num_matches
  from public.profiles p
  join public.solo_matches sm on sm.player_id = p.id
  group by p.id
),
player_tier as (
  select
    player_id,
    case
      when num_matches < 3 then 0.5
      else percent_rank() over (order by avg_score)
    end as pct
  from player_avg
),
player_recorte as (
  select
    player_id,
    case
      when pct < 0.25 then 0.15
      when pct < 0.50 then 0.12
      when pct < 0.75 then 0.09
      when pct < 0.95 then 0.06
      else 0.05
    end as recorte_pct
  from player_tier
)
update public.solo_matches sm
set score = greatest(0, round(sm.score * (1 - pr.recorte_pct)))::int
from player_recorte pr
where pr.player_id = sm.player_id;
*/
