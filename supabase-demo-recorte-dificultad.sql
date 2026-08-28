-- PuckSlide: recalibrar jugadores demo para la regla mas dificil del SET
-- ------------------------------------------------------------------------------------
-- Complementa a supabase-recorte-historico-dificultad.sql (ese ya recorta TAMBIEN las
-- partidas historicas de los jugadores demo, porque su UPDATE no filtra por is_demo).
--
-- Lo que falta aqui es otra cosa: `demo_avg_score` es el centro de la distribucion que usa
-- el cron `refresh_demo_players_matches` (ver supabase-demo-more-active.sql) para generar
-- las puntuaciones de las FUTURAS partidas de cada jugador demo. Si no se toca, los demo
-- seguirian generando partidas nuevas tan altas como antes de endurecer la regla del SET,
-- mientras que los jugadores reales sacarian menos puntuacion desde ya - quedarian
-- artificialmente por encima de los jugadores reales nuevos.
--
-- Se recalibra `demo_avg_score` con el mismo criterio de tramos que las partidas
-- historicas (percent_rank dinamico SOLO entre jugadores demo, ya que su "nivel" es un
-- parametro que nosotros mismos les dimos, no algo que hayan demostrado jugando):
--   percentil 0-25%   (demo_avg_score mas bajo)  -> -15%
--   percentil 25-50%                              -> -12%
--   percentil 50-75%                              -> -9%
--   percentil 75-95%                              -> -6%
--   percentil 95-100% (demo_avg_score mas alto)   -> -5%
--
-- NO EJECUTAR TODAVIA. Revisar primero el SELECT de comprobacion (seccion 1) y luego
-- descomentar y ejecutar el UPDATE (seccion 2). Se recomienda ejecutar este script
-- DESPUES de supabase-recorte-historico-dificultad.sql, aunque el orden entre los dos no
-- afecta al resultado (tocan columnas distintas).

-- ==================================================================================
-- 1) SELECT de comprobacion (NO modifica nada)
-- ==================================================================================
with demo_tier as (
  select
    id,
    name,
    demo_avg_score,
    percent_rank() over (order by demo_avg_score) as pct
  from public.profiles
  where is_demo = true
)
select
  id,
  name,
  demo_avg_score as avg_score_actual,
  round(pct::numeric, 2) as percentil,
  case
    when pct < 0.25 then 0.15
    when pct < 0.50 then 0.12
    when pct < 0.75 then 0.09
    when pct < 0.95 then 0.06
    else 0.05
  end as recorte_pct,
  greatest(10, round(demo_avg_score * (1 - (
    case
      when pct < 0.25 then 0.15
      when pct < 0.50 then 0.12
      when pct < 0.75 then 0.09
      when pct < 0.95 then 0.06
      else 0.05
    end
  ))))::int as avg_score_nuevo
from demo_tier
order by demo_avg_score;

-- ==================================================================================
-- 2) UPDATE real: recalibra demo_avg_score
--    (comentado a proposito - descomentar solo tras revisar el SELECT de arriba)
-- ==================================================================================
/*
with demo_tier as (
  select
    id,
    demo_avg_score,
    percent_rank() over (order by demo_avg_score) as pct
  from public.profiles
  where is_demo = true
),
demo_recorte as (
  select
    id,
    case
      when pct < 0.25 then 0.15
      when pct < 0.50 then 0.12
      when pct < 0.75 then 0.09
      when pct < 0.95 then 0.06
      else 0.05
    end as recorte_pct
  from demo_tier
)
update public.profiles p
set demo_avg_score = greatest(10, round(p.demo_avg_score * (1 - dr.recorte_pct)))::int
from demo_recorte dr
where dr.id = p.id;
*/
