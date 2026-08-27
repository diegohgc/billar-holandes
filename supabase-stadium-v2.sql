-- PuckSlide: rediseño del estadio - reforma progresiva en vez de secciones separadas
-- ------------------------------------------------------------------------------------
-- Cambio de diseño pedido por el usuario el 2026-08-27, sustituye el modelo de
-- supabase-stadium.sql (4 secciones de 50 asientos cada una, cada una con su propio
-- material fijo para siempre) por este otro, mas intuitivo:
--
-- Primero se construyen los 200 asientos EN MADERA (fase de construccion). Una vez
-- completados los 200, se desbloquea la REFORMA a hormigon: los mismos 200 asientos se
-- van renovando poco a poco (en packs de 10) hasta que los 200 son de hormigon. Solo
-- entonces se desbloquea la reforma a moderna, y despues a premium. Es decir, en todo
-- momento hay 200 asientos (nunca cambia el aforo), lo unico que avanza es el material
-- de esos 200 asientos, un nivel detras de otro, para el estadio ENTERO a la vez - no
-- hay secciones mezcladas de distinto material conviviendo.
--
-- Precios (packs de 10, marcados con progresion fuerte), coste total 1.400 monedas
-- (se mantiene el mismo presupuesto y ritmo ya acordado, ~75 dias de juego regular):
--   Construccion (madera):        20 packs x 8  = 160
--   Reforma a hormigon:           20 packs x 13 = 260
--   Reforma a moderna:            20 packs x 20 = 400
--   Reforma a premium:            20 packs x 29 = 580
--                                                  ----
--                                                 1.400
--
-- Aplicado 2026-08-27. Requiere haber ejecutado antes supabase-stadium.sql (usa las
-- mismas columnas coins/seats_built/last_daily_bonus_date, y las funciones
-- claim_daily_bonus/award_match_coins sin cambios).

-- ---- 1) columnas: fuera quality_upgrades (ya no se usa), dentro material_tier +
-- renovated_seats ----
alter table public.profiles drop constraint if exists profiles_quality_upgrades_check;
alter table public.profiles drop column if exists quality_upgrades;

alter table public.profiles
  add column if not exists material_tier integer not null default 1,     -- 1=madera, 2=hormigon, 3=moderna, 4=premium (material ACTUAL de los 200 asientos)
  add column if not exists renovated_seats integer not null default 0;   -- 0-200, progreso de la reforma EN CURSO hacia material_tier+1

alter table public.profiles drop constraint if exists profiles_material_tier_check;
alter table public.profiles add constraint profiles_material_tier_check check (material_tier >= 1 and material_tier <= 4);
alter table public.profiles drop constraint if exists profiles_renovated_seats_check;
alter table public.profiles add constraint profiles_renovated_seats_check check (renovated_seats >= 0 and renovated_seats <= 200);

-- ---- 2) reescribir buy_seat_pack: ahora construye hasta 200 asientos (en madera),
-- sin fases de 50 - precio fijo por pack durante toda la construccion inicial ----
create or replace function public.buy_seat_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  pack_price integer := 8;
begin
  select coins, seats_built into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;
  if prof.seats_built >= 200 then
    return jsonb_build_object('ok', false, 'reason', 'construction_complete');
  end if;
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  update public.profiles
  set coins = coins - pack_price, seats_built = seats_built + 10
  where id = auth.uid();

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 3) nueva funcion: reformar 10 asientos mas hacia el siguiente material. Solo
-- disponible cuando la construccion inicial esta completa (200/200 en madera). Al
-- llegar renovated_seats a 200, sube material_tier y renovated_seats vuelve a 0 (listo
-- para la siguiente reforma, o terminado si ya se llego a premium) ----
create or replace function public.buy_renovation_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  pack_price integer;
  -- precio por pack para reformar HACIA el tier 2/3/4 - indice = material_tier actual (1,2,3)
  prices integer[] := array[13, 20, 29];
begin
  select coins, seats_built, material_tier, renovated_seats into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;
  if prof.seats_built < 200 then
    return jsonb_build_object('ok', false, 'reason', 'construction_not_complete');
  end if;
  if prof.material_tier >= 4 then
    return jsonb_build_object('ok', false, 'reason', 'all_upgraded');
  end if;

  pack_price := prices[prof.material_tier];
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  if prof.renovated_seats + 10 >= 200 then
    update public.profiles
    set coins = coins - pack_price, renovated_seats = 0, material_tier = material_tier + 1
    where id = auth.uid();
  else
    update public.profiles
    set coins = coins - pack_price, renovated_seats = renovated_seats + 10
    where id = auth.uid();
  end if;

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 4) la funcion vieja de mejora de calidad ya no se usa - se elimina para que no
-- quede confusion en el esquema ----
drop function if exists public.buy_quality_upgrade();
