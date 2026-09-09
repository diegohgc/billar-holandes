-- PuckSlide: reparto INMEDIATO de divisiones tras el fallo del 2026-09-09
-- ------------------------------------------------------------------------------------
-- El bug de run_league_promotions() (ver supabase-league-promotions-fix.sql) metio a todo
-- el mundo en la division 1 y mando a los jugadores nuevos de esta semana a una division 2
-- "de emergencia". Solo con la funcion arreglada, esto tardaria semanas en corregirse solo
-- (cada lunes solo bajan 3 personas de la division 1). Este script reparte a todo el mundo
-- de golpe segun su mejor puntuacion HISTORICA, igual que el sembrado inicial de
-- supabase-leagues.sql cuando se lanzo el sistema de ligas por primera vez - deja las
-- divisiones justas ya esta misma semana, en vez de esperar.
--
-- Este script es un AJUSTE PUNTUAL, de un solo uso - no hace falta volver a ejecutarlo mas
-- adelante (solo si se repitiera este mismo fallo, que no deberia pasar una vez aplicado
-- supabase-league-promotions-fix.sql).

do $$
declare
  target_divisions int;
begin
  select greatest(1, ceil(count(*) / 20.0))::int into target_divisions from public.profiles;

  with best_scores as (
    select p.id, coalesce(max(m.score), 0) as best
    from public.profiles p
    left join public.solo_matches m on m.player_id = p.id
    group by p.id
  ),
  buckets as (
    select id, ntile(target_divisions) over (order by best desc) as bucket
    from best_scores
  )
  update public.profiles p
  set league_division = b.bucket
  from buckets b
  where b.id = p.id;
end $$;
