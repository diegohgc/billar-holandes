-- PuckSlide: confirmacion automatica por email cuando se borra la cuenta de un jugador
-- ------------------------------------------------------------------------------------
-- Motivo: la app promete "Te confirmaremos por email" al solicitar el borrado de cuenta
-- (ver deleteAccountConfirm en index.html), pero el borrado en si lo hace el admin a mano
-- en Supabase (delete from profiles where id = '...'). Este trigger automatiza el email
-- de confirmacion para que se cumpla esa promesa sin tener que acordarse cada vez.
--
-- Servicio usado: Resend (resend.com), plan gratuito. Dominio verificado:
-- puckslide.dhaudiovisuales.com (subdominio de dhaudiovisuales.com, gestionado en Namecheap).
-- Clave de API con permiso "Sending access" restringido a ese dominio.
--
-- Los jugadores demo (is_demo = true, ver supabase-demo-players.sql) no tienen cuenta real
-- en auth.users, asi que el trigger los detecta automaticamente y NO les manda nada.
--
-- IMPORTANTE: la clave de API NO va escrita en este archivo (es publico en GitHub). Se guarda
-- aparte, directamente en la base de datos, con este comando (ejecutar UNA VEZ en el SQL
-- Editor de Supabase, no lo pegues ni lo commitees en ningun archivo):
--
--   alter database postgres set app.resend_api_key = 're_TU_CLAVE_AQUI';
--   select pg_reload_conf();
--
-- Aplicado 2026-08-24.

create extension if not exists pg_net;

create or replace function public.notify_account_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  user_email text;
begin
  select email into user_email from auth.users where id = old.id;

  if user_email is not null then
    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || current_setting('app.resend_api_key', true),
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'from', 'PuckSlide <noreply@puckslide.dhaudiovisuales.com>',
        'to', jsonb_build_array(user_email),
        'subject', 'Cuenta eliminada / Account deleted - PuckSlide',
        'html', '<p>Hola,</p><p>Confirmamos que tu cuenta de PuckSlide y todos tus datos (perfil, pa&iacute;s y partidas) han sido eliminados permanentemente.</p><p>Un saludo,<br>Equipo PuckSlide</p><hr><p>Hello,</p><p>We confirm that your PuckSlide account and all your data (profile, country and matches) have been permanently deleted.</p><p>Best,<br>PuckSlide Team</p>'
      )
    );
  end if;

  return old;
end;
$$;

drop trigger if exists trg_notify_account_deletion on public.profiles;
create trigger trg_notify_account_deletion
  before delete on public.profiles
  for each row
  execute function public.notify_account_deletion();
