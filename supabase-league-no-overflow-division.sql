-- PuckSlide: quitar la division "de emergencia" para jugadores nuevos (bug critico
-- reportado por el usuario el 2026-09-13: un jugador se registro esta semana y quedo
-- SOLO, el unico jugador real, en una division 4 nueva que se creo solo para el)
-- ------------------------------------------------------------------------------------
-- CAUSA: assign_new_player_league_division() tenia una regla "anti-amontonamiento": si la
-- ultima division ya tenia 20 jugadores o mas, en vez de meter ahi al jugador nuevo, le
-- abria una division nueva (todavia mas abajo) y se llevaba 8 jugadores DEMO con el para
-- que no se sintiera solo. En la practica, cuando el movimiento de los 8 demo no salia
-- perfecto (o si se registraban varios jugadores muy seguidos), el jugador nuevo podia
-- acabar solo, o casi solo, en una division fantasma - exactamente lo que paso este caso:
-- Benedikt 82 se registro el 2026-09-11 cuando la division 3 tenia justo 20 jugadores, y
-- quedo solo en la division 4 (0 jugadores demo con el).
--
-- PEDIDO EXPLICITO DEL USUARIO: los jugadores nuevos deben entrar siempre en la ULTIMA
-- division que exista esa semana (por llena que este) - es el cron semanal
-- (run_league_promotions, ver supabase-leagues.sql) el que ya decide cada lunes cuantas
-- divisiones hacen falta segun cuanta gente ha jugado la semana anterior (target_divisions),
-- y el que debe abrir una division nueva si hace falta, no el registro de un jugador suelto
-- a mitad de semana.
--
-- Se quita toda la logica de "crear division nueva + traer 8 demo" - la funcion queda
-- mucho mas simple: el jugador nuevo entra siempre en la division mas baja (numero mas
-- alto) que exista en ese momento.

create or replace function public.assign_new_player_league_division()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.league_division is null then
    select coalesce(max(league_division), 1) into new.league_division from public.profiles;
  end if;
  return new;
end;
$$;

-- reparacion puntual: mueve a quien haya quedado solo en la division "fantasma" (la mas
-- alta de todas) a la division inmediatamente anterior - calculado a partir de los datos
-- actuales, no con un numero fijo, por si esto no se ejecuta el mismo dia. Si la division
-- fantasma se queda vacia del todo tras esto, no hace falta hacer nada mas con ella - no es
-- una fila ni una tabla, solo un numero en profiles.league_division, y al no quedar nadie
-- ahi simplemente deja de existir.
update public.profiles
set league_division = (
  select max(league_division) from public.profiles
  where league_division < (select max(league_division) from public.profiles)
)
where league_division = (select max(league_division) from public.profiles);
