-- PuckSlide: subir el minimo de partidas semanales de liga de 2 a 3
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-08-28: 2 partidas se quedaba corto para que la puntuacion
-- semanal de liga cuente de verdad. Solo cambia el umbral del "if" en la vista
-- league_ranking (de count(m.score) >= 2 a >= 3) - el resto de la logica de ascensos y
-- descensos sigue igual, ya que run_league_promotions() ya filtra por matches_played >= 2,
-- pero como week_score sera 0 para quien tenga menos de 3, en la practica ya no puede
-- ascender/descender con solo 2 partidas (su week_score de 0 lo manda al fondo del orden).
--
-- El texto de instrucciones en index.html (las 19 traducciones) ya se ha actualizado por
-- separado para reflejar el "al menos 3" y aclarar que entras en la division en cuanto
-- creas tu perfil online, no en cuanto juegas tu primera partida.

create or replace view public.league_ranking as
select
  p.id as player_id,
  p.name,
  p.country,
  p.league_division,
  case when count(m.score) >= 3 then coalesce(round(avg(m.score)), 0) else 0 end as week_score,
  count(m.score) as matches_played
from public.profiles p
left join public.solo_matches m
  on m.player_id = p.id and m.played_at >= date_trunc('week', now())
group by p.id, p.name, p.country, p.league_division;
