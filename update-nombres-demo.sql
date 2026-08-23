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
