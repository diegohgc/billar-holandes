-- PuckSlide: fase 2 del estadio - grada del fondo (350 asientos) + desacoplar
-- construccion y reforma
-- ------------------------------------------------------------------------------------
-- Cambio pedido por el usuario el 2026-09-05:
--   1) Aforo total sube de 200 a 350 (200 en las 2 laterales de siempre + 150 nuevos en
--      una grada nueva detras de la porteria, "grada del fondo").
--   2) Ya NO hace falta terminar de construir todo el aforo antes de poder reformar el
--      material. Ahora se puede reformar en cualquier momento lo que YA este construido,
--      en paralelo con seguir ampliando la grada - las dos cosas son independientes.
--      Lo unico que sigue siendo secuencial es el orden de los materiales (no se puede
--      reformar a premium sin pasar antes por moderna).
--
-- Requiere haber ejecutado antes supabase-stadium-v2.sql (usa las mismas columnas
-- coins/seats_built/material_tier/renovated_seats, sin cambios de esquema salvo los checks).

-- ---- 1) ampliar los limites de los checks existentes: 200 -> 350 ----
alter table public.profiles drop constraint if exists profiles_seats_built_check;
alter table public.profiles add constraint profiles_seats_built_check check (seats_built >= 0 and seats_built <= 350);

alter table public.profiles drop constraint if exists profiles_renovated_seats_check;
alter table public.profiles add constraint profiles_renovated_seats_check check (renovated_seats >= 0 and renovated_seats <= 350);

-- ---- 2) buy_seat_pack: mismo precio por pack (8 monedas / 10 asientos), tope ahora 350
-- en vez de 200. Los primeros 200 seguiran viendose en las 2 laterales y los 150 restantes
-- en la grada del fondo (la app decide esa mitad visualmente, aqui solo se cuenta el total) ----
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
  if prof.seats_built >= 350 then
    return jsonb_build_object('ok', false, 'reason', 'construction_complete');
  end if;
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  update public.profiles
  set coins = coins - pack_price, seats_built = least(350, seats_built + 10)
  where id = auth.uid();

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 3) buy_renovation_pack: reescrita para desacoplar de la construccion. Ya NO exige
-- seats_built >= 350 (construction_not_complete desaparece). En su lugar, renovated_seats
-- nunca puede superar a seats_built (no se puede reformar un asiento que aun no existe) -
-- si ya esta todo lo construido reformado, devuelve "nothing_to_renovate". El tope para
-- pasar al siguiente material sube de 200 a 350 ----
create or replace function public.buy_renovation_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  pack_price integer;
  new_renovated integer;
  -- precio por pack para reformar HACIA el tier 2/3/4 - indice = material_tier actual (1,2,3)
  prices integer[] := array[13, 20, 29];
begin
  select coins, seats_built, material_tier, renovated_seats into prof from public.profiles where id = auth.uid();
  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;
  if prof.material_tier >= 4 then
    return jsonb_build_object('ok', false, 'reason', 'all_upgraded');
  end if;
  if prof.renovated_seats >= prof.seats_built then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_renovate');
  end if;

  pack_price := prices[prof.material_tier];
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  new_renovated := least(prof.renovated_seats + 10, prof.seats_built);

  if new_renovated >= 350 then
    update public.profiles
    set coins = coins - pack_price, renovated_seats = 0, material_tier = material_tier + 1
    where id = auth.uid();
  else
    update public.profiles
    set coins = coins - pack_price, renovated_seats = new_renovated
    where id = auth.uid();
  end if;

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;
