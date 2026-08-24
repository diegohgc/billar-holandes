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
-- aparte, en una tabla privada (ver mas abajo), con un INSERT que NO se pega ni se commitea
-- en ningun archivo - solo se ejecuta una vez, directo en el SQL Editor de Supabase.
--
-- Aplicado 2026-08-24. (Version 2: la primera version usaba `alter database ... set`, pero
-- el rol postgres de Supabase no tiene permiso para eso - se cambio a esta tabla privada.)

create extension if not exists pg_net;

-- tabla privada para guardar la clave (no expuesta via API: solo los esquemas publicados en
-- Configuracion > API son accesibles desde fuera, y este no lo esta)
create schema if not exists app_secrets;
create table if not exists app_secrets.resend (
  key text primary key,
  value text not null
);
revoke all on app_secrets.resend from public, anon, authenticated;

create or replace function public.notify_account_deletion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  user_email text;
  api_key text;
begin
  select email into user_email from auth.users where id = old.id;

  if user_email is not null then
    select value into api_key from app_secrets.resend where key = 'resend_api_key';

    if api_key is not null then
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || api_key,
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
  end if;

  return old;
end;
$$;

drop trigger if exists trg_notify_account_deletion on public.profiles;
create trigger trg_notify_account_deletion
  before delete on public.profiles
  for each row
  execute function public.notify_account_deletion();
