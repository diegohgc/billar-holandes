-- PuckSlide: sistema de monedas y estadio (gradas)
-- ------------------------------------------------------------------------------------
-- Diseño acordado con el usuario el 2026-08-27 (ver memoria de Claude Code /
-- project_pluckslide_visual_ideas_backlog.md para el detalle completo del diseño).
--
-- MONEDAS: solo se ganan jugando ONLINE (1 moneda por cada 10 puntos de la partida),
-- mas un bono fijo diario por volver al juego. El modo local nunca genera monedas -
-- asi se incentiva jugar online, que es donde esta el resto de la retencion (ligas,
-- ranking, etc).
--
-- ESTADIO: 200 asientos en total, repartidos en 4 fases de material (madera, hormigon,
-- moderna, premium), 50 asientos por fase (5 packs de 10). Cada fase tiene ademas una
-- "mejora de calidad" que se compra una vez completada la construccion de esa fase.
-- Las fases son estrictamente secuenciales: no se puede construir la fase 2 sin haber
-- completado construccion + mejora de la fase 1.
--
-- Precios (marcados con progresion fuerte entre fases), coste total 1.400 monedas:
--   Fase 1 (madera):    5 packs x 18  = 90  + mejora 60  = 150
--   Fase 2 (hormigon):  5 packs x 30  = 150 + mejora 100 = 250
--   Fase 3 (moderna):   5 packs x 48  = 240 + mejora 160 = 400
--   Fase 4 (premium):   5 packs x 72  = 360 + mejora 240 = 600
--
-- Aplicado 2026-08-27.

-- ---- 1) columnas nuevas en profiles ----
alter table public.profiles
  add column if not exists coins integer not null default 0,
  add column if not exists seats_built integer not null default 0,      -- 0-200, de 10 en 10
  add column if not exists quality_upgrades integer not null default 0, -- 0-4, cuantas fases tienen ya la mejora de calidad comprada
  add column if not exists last_daily_bonus_date date;

-- protecciones basicas de rango (evita que un cliente manipulado deje valores absurdos)
alter table public.profiles drop constraint if exists profiles_coins_check;
alter table public.profiles add constraint profiles_coins_check check (coins >= 0);
alter table public.profiles drop constraint if exists profiles_seats_built_check;
alter table public.profiles add constraint profiles_seats_built_check check (seats_built >= 0 and seats_built <= 200);
alter table public.profiles drop constraint if exists profiles_quality_upgrades_check;
alter table public.profiles add constraint profiles_quality_upgrades_check check (quality_upgrades >= 0 and quality_upgrades <= 4);

-- ---- 2) funcion para reclamar el bono diario (se puede llamar cada vez que se abre el
-- juego - ella misma comprueba que no se haya reclamado ya hoy) ----
create or replace function public.claim_daily_bonus()
returns integer  -- monedas ganadas (0 si ya se habia reclamado hoy)
language plpgsql
security definer
set search_path = public
as $$
declare
  last_date date;
  bonus integer := 5;
begin
  select last_daily_bonus_date into last_date from public.profiles where id = auth.uid();
  if last_date is not null and last_date = current_date then
    return 0;
  end if;
  update public.profiles
  set coins = coins + bonus, last_daily_bonus_date = current_date
  where id = auth.uid();
  return bonus;
end;
$$;

-- ---- 3) funcion para sumar monedas al terminar una partida ONLINE (se llama con la
-- puntuacion de la partida ya guardada; solo suma, nunca resta, y esta limitada al
-- propio usuario via auth.uid()) ----
create or replace function public.award_match_coins(match_score integer)
returns integer  -- monedas ganadas
language plpgsql
security definer
set search_path = public
as $$
declare
  earned integer;
begin
  earned := greatest(0, floor(match_score / 10.0))::integer;
  if earned > 0 then
    update public.profiles set coins = coins + earned where id = auth.uid();
  end if;
  return earned;
end;
$$;

-- ---- 4) funcion para comprar un pack de 10 asientos (siguiente pack disponible segun
-- la fase actual) ----
create or replace function public.buy_seat_pack()
returns jsonb  -- {ok: bool, reason: text, seats_built, coins}
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  phase integer;
  seats_in_phase integer;
  pack_price integer;
  prices integer[] := array[18, 30, 48, 72]; -- precio por pack, indice 0..3 = fase 1..4
begin
  select coins, seats_built, quality_upgrades into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  phase := (prof.seats_built / 50) + 1; -- fase actual (1-4) segun asientos ya construidos
  seats_in_phase := prof.seats_built % 50;

  if prof.seats_built >= 200 then
    return jsonb_build_object('ok', false, 'reason', 'stadium_complete');
  end if;
  -- no se puede seguir construyendo la fase actual si ya esta completa (50/50) sin haber
  -- comprado antes la mejora de calidad de esa fase
  if seats_in_phase = 0 and phase > 1 and prof.quality_upgrades < phase - 1 then
    return jsonb_build_object('ok', false, 'reason', 'quality_upgrade_required');
  end if;

  pack_price := prices[phase];
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  update public.profiles
  set coins = coins - pack_price, seats_built = seats_built + 10
  where id = auth.uid();

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 5) funcion para comprar la mejora de calidad de la fase actual (solo disponible
-- cuando esa fase esta completamente construida: 50 asientos) ----
create or replace function public.buy_quality_upgrade()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  phase integer;
  upgrade_price integer;
  prices integer[] := array[60, 100, 160, 240]; -- indice 0..3 = fase 1..4
begin
  select coins, seats_built, quality_upgrades into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  phase := least(4, (prof.seats_built / 50) + (case when prof.seats_built % 50 = 0 and prof.seats_built > 0 then 0 else 1 end));
  -- fase a mejorar = la ultima fase completamente construida que aun no tiene mejora
  phase := prof.quality_upgrades + 1;

  if phase > 4 then
    return jsonb_build_object('ok', false, 'reason', 'all_upgraded');
  end if;
  if prof.seats_built < phase * 50 then
    return jsonb_build_object('ok', false, 'reason', 'phase_not_built');
  end if;

  upgrade_price := prices[phase];
  if prof.coins < upgrade_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', upgrade_price, 'coins', prof.coins);
  end if;

  update public.profiles
  set coins = coins - upgrade_price, quality_upgrades = quality_upgrades + 1
  where id = auth.uid();

  return jsonb_build_object('ok', true, 'price', upgrade_price);
end;
$$;
