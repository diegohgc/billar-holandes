-- PuckSlide: corregir el precio del parking - se disparo x10 sin querer al pasar a packs de 10
-- ------------------------------------------------------------------------------------
-- Feedback del usuario el 2026-09-14 al ver el precio en la app: "no es un poco caro hacer
-- parkings?". Tenia razon: PARKING_OCCUPANCY_BONUS (el beneficio real de tener el parking al
-- 100%) es el mismo tope tanto con 14/14 como con 140/140 plazas - el beneficio de "parking
-- completo" NO cambio al subir de 14 a 140 plazas (ver supabase-stadium-parking-140.sql). Al
-- mantener 18 monedas POR PLAZA en esa migracion, el coste total de completar el parking
-- entero paso de 252 monedas (14 plazas x 18) a 2520 monedas (14 packs x 180) - diez veces mas
-- caro que antes para exactamente el mismo beneficio, y mas de 6 veces el coste de construir
-- el estadio ENTERO (500 asientos = 400 monedas).
--
-- Unico cambio: el precio pasa a ser 18 monedas POR PACK (no por plaza) - asi el coste total
-- de completar el parking (14 packs x 18 = 252) vuelve a ser el mismo que con la version de
-- 14 plazas. Nada mas se toca (max_spots sigue en 140, pack_size en 10, y award_match_coins
-- no se ve afectado por esto - ya quedo bien en supabase-stadium-parking-140.sql).

create or replace function public.buy_parking_pack()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  prof record;
  price constant integer := 18;
  pack_size constant integer := 10;
  max_spots constant integer := 140;
begin
  select coins, parking_spots_built into prof from public.profiles where id = auth.uid();

  if prof is null then
    return jsonb_build_object('ok', false, 'reason', 'no_profile');
  end if;

  if coalesce(prof.parking_spots_built, 0) >= max_spots then
    return jsonb_build_object('ok', false, 'reason', 'already_built');
  end if;

  if prof.coins < price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins');
  end if;

  update public.profiles
  set coins = coins - price, parking_spots_built = coalesce(parking_spots_built, 0) + pack_size
  where id = auth.uid();

  return jsonb_build_object('ok', true);
end;
$$;
