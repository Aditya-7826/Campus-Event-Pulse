create extension if not exists pgcrypto;
create type public.user_role as enum ('student','organizer','admin');
create type public.event_status as enum ('draft','published','closed','cancelled');
create type public.registration_status as enum ('registered','cancelled');
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '', role public.user_role not null default 'student',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.events (
 id uuid primary key default gen_random_uuid(), organizer_id uuid not null references public.profiles(id) on delete restrict,
 title text not null check(length(title) between 3 and 120), description text not null check(length(description) between 10 and 10000),
 category text not null check(category in ('Technical','Cultural','Sports','Workshops','Entrepreneurship','Arts & Music','Other')),
 venue text not null, starts_at timestamptz not null, ends_at timestamptz not null, registration_deadline timestamptz,
 capacity integer not null check(capacity > 0), poster_url text, status public.event_status not null default 'draft',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(ends_at > starts_at), check(registration_deadline is null or registration_deadline <= starts_at)
);
create table public.registrations (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references public.events(id) on delete restrict,
 student_id uuid not null references public.profiles(id) on delete restrict,
 status public.registration_status not null default 'registered', created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(event_id,student_id)
);
create index events_publication_date_idx on public.events(status,starts_at);
create index events_organizer_idx on public.events(organizer_id,starts_at desc);
create index registrations_student_idx on public.registrations(student_id,created_at desc);
create index registrations_event_status_idx on public.registrations(event_id,status);
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,full_name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','')); return new; end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();
create or replace function public.is_event_organizer(p_event_id uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.events where id=p_event_id and organizer_id=auth.uid()) or exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;
create or replace function public.register_for_event(p_event_id uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_event public.events%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in to register.'; end if;
 select * into v_event from public.events where id=p_event_id for update;
 if not found or v_event.status <> 'published' then raise exception 'This event is not open for registration.'; end if;
 if v_event.registration_deadline is not null and now()>v_event.registration_deadline then raise exception 'Registration deadline has passed.'; end if;
 if exists(select 1 from public.registrations where event_id=p_event_id and student_id=auth.uid() and status='registered') then raise exception 'You are already registered.'; end if;
 if (select count(*) from public.registrations where event_id=p_event_id and status='registered') >= v_event.capacity then raise exception 'This event is full.'; end if;
 insert into public.registrations(event_id,student_id,status) values(p_event_id,auth.uid(),'registered')
 on conflict(event_id,student_id) do update set status='registered',updated_at=now() returning id into v_id;
 return v_id;
end; $$;
revoke all on function public.register_for_event(uuid) from public;
grant execute on function public.register_for_event(uuid) to authenticated;
alter table public.profiles enable row level security; alter table public.events enable row level security; alter table public.registrations enable row level security;
create policy "Profiles are readable to signed in users" on public.profiles for select to authenticated using(true);
revoke update on public.profiles from authenticated;
grant update(full_name) on public.profiles to authenticated;
create policy "Users update own profile fields" on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy "Published events are public" on public.events for select using(status='published' or organizer_id=auth.uid() or exists(select 1 from public.profiles where id=auth.uid() and role='admin'));
create policy "Organizers create own events" on public.events for insert to authenticated with check(organizer_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role in ('organizer','admin')));
create policy "Organizers update own events" on public.events for update to authenticated using(organizer_id=auth.uid() or exists(select 1 from public.profiles where id=auth.uid() and role='admin')) with check(organizer_id=auth.uid() or exists(select 1 from public.profiles where id=auth.uid() and role='admin'));
create policy "Organizers delete own events" on public.events for delete to authenticated using(organizer_id=auth.uid() or exists(select 1 from public.profiles where id=auth.uid() and role='admin'));
create policy "Students read own and owners read event registrations" on public.registrations for select to authenticated using(student_id=auth.uid() or public.is_event_organizer(event_id));
create policy "Students cancel own registrations" on public.registrations for update to authenticated using(student_id=auth.uid()) with check(student_id=auth.uid() and status='cancelled');
-- Inserts are intentionally RPC-only; capacity checks and the unique lock run transactionally.
