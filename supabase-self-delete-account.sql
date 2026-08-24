-- PuckSlide: borrado de cuenta 100% automatico (self-service)
-- ------------------------------------------------------------------------------------
-- Antes: el jugador pedia el borrado desde la app -> le llegaba un aviso al admin (Diego) ->
-- el admin tenia que borrar el perfil A MANO en Supabase. Problema: si el admin no puede
-- (viaje, no tiene este contexto a mano, etc.) la cuenta se queda sin borrar indefinidamente.
--
-- Ahora: al confirmar en la app, se borra la cuenta AL INSTANTE, sin intervencion humana.
-- El trigger de supabase-account-deletion-email.sql sigue disparandose igual (porque sigue
-- siendo un DELETE real sobre profiles), asi que el email de confirmacion tambien sigue
-- saliendo solo.
--
-- Seguridad: la funcion es "security definer" (se salta RLS, como el dueño de la tabla), pero
-- SOLO opera sobre auth.uid() (el propio usuario que llama), nunca sobre un id que le pases tu -
-- por diseño, un jugador no puede borrar la cuenta de otro aunque quisiera.
--
-- Aplicado 2026-08-24.

create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- primero el perfil (dispara el trigger de email de confirmacion, que necesita que
  -- auth.users todavia exista en ese momento para leer el email)
  delete from public.profiles where id = auth.uid();
  -- despues la cuenta de verdad (login de Google)
  delete from auth.users where id = auth.uid();
end;
$$;

grant execute on function public.delete_own_account() to authenticated;
