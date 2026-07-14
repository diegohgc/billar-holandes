-- PuckSlide online: tabla de perfiles de jugador
-- Cada usuario autenticado con Google tiene un perfil con nombre visible + pais elegido a mano.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 18),
  country text not null, -- codigo ISO 3166-1 alpha-2, ej. 'ES', 'FR', 'MX'
  created_at timestamptz not null default now()
);

-- Row Level Security: cada usuario solo puede crear/editar SU PROPIO perfil,
-- pero todos los perfiles son visibles (necesario para mostrar nombres en rankings/duelos).
alter table public.profiles enable row level security;

create policy "Los perfiles son visibles para todos"
  on public.profiles for select
  using (true);

create policy "Cada usuario crea su propio perfil"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "Cada usuario edita su propio perfil"
  on public.profiles for update
  using (auth.uid() = id);

-- ---- Partidas en solitario (historial, para calcular el ranking) ----
create table public.solo_matches (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.profiles(id) on delete cascade,
  score int not null,
  sets int not null,
  played_at timestamptz not null default now()
);

alter table public.solo_matches enable row level security;

create policy "Las partidas son visibles para todos"
  on public.solo_matches for select
  using (true);

create policy "Cada usuario registra sus propias partidas"
  on public.solo_matches for insert
  with check (auth.uid() = player_id);

-- Sin políticas de update/delete a propósito: el historial de partidas es inmutable,
-- nadie (ni el propio jugador) puede editar o borrar una partida ya jugada.

-- ---- Ranking global: media de las ultimas 20 partidas, minimo 2 jugadas para aparecer ----
-- (minimo bajado a 2 temporalmente para poder probar con pocos datos; subir para produccion)
create or replace view public.ranking as
select
  p.id as player_id,
  p.name,
  p.country,
  round(avg(m.score)) as avg_score,
  count(m.score) as matches_played
from public.profiles p
join lateral (
  select score
  from public.solo_matches sm
  where sm.player_id = p.id
  order by sm.played_at desc
  limit 20
) m on true
group by p.id, p.name, p.country
having count(m.score) >= 2
order by avg_score desc;

-- ---- Ranking mensual y anual de jugadores (media de TODAS las partidas del periodo) ----
create or replace view public.ranking_monthly as
select
  p.id as player_id, p.name, p.country,
  round(avg(m.score)) as avg_score,
  count(m.score) as matches_played
from public.profiles p
join lateral (
  select score from public.solo_matches sm
  where sm.player_id = p.id and sm.played_at >= date_trunc('month', now())
) m on true
group by p.id, p.name, p.country
having count(m.score) >= 2
order by avg_score desc;

create or replace view public.ranking_yearly as
select
  p.id as player_id, p.name, p.country,
  round(avg(m.score)) as avg_score,
  count(m.score) as matches_played
from public.profiles p
join lateral (
  select score from public.solo_matches sm
  where sm.player_id = p.id and sm.played_at >= date_trunc('year', now())
) m on true
group by p.id, p.name, p.country
having count(m.score) >= 2
order by avg_score desc;

-- ---- Ranking de paises: cada jugador "juega para si mismo y para su pais" a la vez -----
-- la puntuacion de un pais es la media de los rankings individuales de sus jugadores.
-- Minimo bajado a 2 jugadores representando (temporal, para probar con pocos datos).
create or replace view public.ranking_countries as
select country, round(avg(avg_score)) as avg_score, count(*) as players_count
from public.ranking
group by country
having count(*) >= 2
order by avg_score desc;

create or replace view public.ranking_countries_monthly as
select country, round(avg(avg_score)) as avg_score, count(*) as players_count
from public.ranking_monthly
group by country
having count(*) >= 2
order by avg_score desc;

create or replace view public.ranking_countries_yearly as
select country, round(avg(avg_score)) as avg_score, count(*) as players_count
from public.ranking_yearly
group by country
having count(*) >= 2
order by avg_score desc;
