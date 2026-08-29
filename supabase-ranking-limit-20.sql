-- PuckSlide: bajar la ventana de la clasificacion general de 50 a 20 partidas
-- ------------------------------------------------------------------------------------
-- Motivo: la clasificacion general (vista ranking) calcula la media sobre las ULTIMAS
-- 50 partidas de cada jugador. Comprobado el 2026-08-29: con la base de jugadores
-- actual, 0 de 52 jugadores tienen siquiera 50 partidas jugadas, asi que el limite de
-- 50 no esta afectando a nadie todavia - en la practica la media ya es "todas las
-- partidas" para el 100% de la gente. Bajarlo a 20 SI tiene efecto real: 26 de 52
-- jugadores (la mitad) ya tienen 20+ partidas, asi que empezarian a tener una media
-- mas "viva", basada en su nivel reciente, en vez de arrastrar partidas antiguas.
--
-- Solo cambia el "limit 50" -> "limit 20" dentro de la sub-consulta lateral. El resto
-- de reglas (minimo 2 partidas para aparecer, desaparecer tras 7 dias sin jugar) se
-- deja igual.
--
-- El texto de instrucciones (rankRule1, 19 idiomas) ya se ha actualizado por separado
-- en index.html para decir "20" en vez de "50".

create or replace view public.ranking as
select
  p.id as player_id,
  p.name,
  p.country,
  round(avg(m.score)) as avg_score,
  count(m.score) as matches_played
from public.profiles p
join lateral (
  select score, played_at
  from public.solo_matches sm
  where sm.player_id = p.id
  order by sm.played_at desc
  limit 20
) m on true
group by p.id, p.name, p.country
having count(m.score) >= 2 and max(m.played_at) >= now() - interval '7 days'
order by avg_score desc;
