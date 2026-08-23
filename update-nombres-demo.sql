-- PuckSlide: retoques de nombres de los jugadores demo para que parezcan mas naturales
-- (algunos sin apellido, en mayusculas, en minusculas o sin tildes - como escribiria gente real
-- desde el movil). Aplicado el 2026-08-22, despues del sembrado inicial de supabase-demo-players.sql.
update public.profiles set name = 'Ryan' where name = 'Ryan Mitchell' and is_demo = true;
update public.profiles set name = 'Wei' where name = 'Wei Zhang' and is_demo = true;
update public.profiles set name = 'Haruto' where name = 'Haruto Sato' and is_demo = true;
update public.profiles set name = 'julien moreau' where name = 'Julien Moreau' and is_demo = true;
update public.profiles set name = 'camila torres' where name = 'Camila Torres' and is_demo = true;
update public.profiles set name = 'elin bergström' where name = 'Elin Bergström' and is_demo = true;
update public.profiles set name = 'OLIVER BENNETT' where name = 'Oliver Bennett' and is_demo = true;
update public.profiles set name = 'MARCO BIANCHI' where name = 'Marco Bianchi' and is_demo = true;
update public.profiles set name = 'BEATRIZ SOUZA' where name = 'Beatriz Souza' and is_demo = true;
update public.profiles set name = 'Sofia Martinez' where name = 'Sofía Martínez' and is_demo = true;

-- Segunda tanda (misma idea, 5 mas solo con nombre de pila): aplicado 2026-08-22
update public.profiles set name = 'Lucas' where name = 'Lucas Oliveira' and is_demo = true;
update public.profiles set name = 'Emily' where name = 'Emily Clarke' and is_demo = true;
update public.profiles set name = 'Mei' where name = 'Mei Chen' and is_demo = true;
update public.profiles set name = 'Valentina' where name = 'Valentina Rojas' and is_demo = true;
update public.profiles set name = 'Lukas' where name = 'Lukas Schneider' and is_demo = true;

-- Tercera tanda: 5 de Sudamerica reasignados a Paises Bajos (nombre + pais), a peticion del
-- usuario, uno de cada pais (AR/MX/CO/CL/BR) - aplicado 2026-08-22
update public.profiles set name = 'Bram de Jong', country = 'NL' where name = 'Martín Gómez' and is_demo = true;
update public.profiles set name = 'Sven van Dijk', country = 'NL' where name = 'Diego Ramírez' and is_demo = true;
update public.profiles set name = 'Thomas Visser', country = 'NL' where name = 'Andrés Molina' and is_demo = true;
update public.profiles set name = 'Niels Smit', country = 'NL' where name = 'Sebastián Vidal' and is_demo = true;
update public.profiles set name = 'Kees Mulder', country = 'NL' where name = 'BEATRIZ SOUZA' and is_demo = true;
