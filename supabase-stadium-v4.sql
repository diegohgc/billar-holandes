-- PuckSlide: fase 3 del estadio - nivel 2 de gradas (aforo 350 -> 500)
-- ------------------------------------------------------------------------------------
-- Pedido por el usuario el 2026-09-06: elevar las laterales y la grada del fondo a un
-- segundo nivel (como un anfiteatro real), sumando 150 asientos mas: 350 -> 500.
--
-- Es el mismo mecanismo de siempre (buy_seat_pack / buy_renovation_pack), solo cambia el
-- tope de 350 a 500. No hace falta tocar la logica de desacoplar construccion/reforma
-- (ya la trae supabase-stadium-v3.sql) ni el mantenimiento progresivo (ya la trae
-- supabase-stadium-maintenance.sql, que usa seats_built directamente asi que sigue
-- funcionando sin cambios con el nuevo tope de 500).
--
-- Requiere haber ejecutado antes supabase-stadium-v3.sql y supabase-stadium-maintenance.sql.

-- ---- 1) ampliar los limites de los checks existentes: 350 -> 500 ----
alter table public.profiles drop constraint if exists profiles_seats_built_check;
alter table public.profiles add constraint profiles_seats_built_check check (seats_built >= 0 and seats_built <= 500);

alter table public.profiles drop constraint if exists profiles_renovated_seats_check;
alter table public.profiles add constraint profiles_renovated_seats_check check (renovated_seats >= 0 and renovated_seats <= 500);

-- ---- 2) buy_seat_pack: mismo precio por pack, tope ahora 500 ----
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
  if prof.seats_built >= 500 then
    return jsonb_build_object('ok', false, 'reason', 'construction_complete');
  end if;
  if prof.coins < pack_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'price', pack_price, 'coins', prof.coins);
  end if;

  update public.profiles
  set coins = coins - pack_price, seats_built = least(500, seats_built + 10)
  where id = auth.uid();

  return jsonb_build_object('ok', true, 'price', pack_price);
end;
$$;

-- ---- 3) buy_renovation_pack: mismo desacople de siempre, tope ahora 500 ----
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

  if new_renovated >= 500 then
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
