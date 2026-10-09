begin;

create table if not exists public.irmao_salon_admin_credentials (
  phone text primary key references public.irmao_salon_allowed_phones(phone) on delete cascade,
  password_hash text not null check (password_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.irmao_salon_enrollment_challenges (
  phone text primary key check (phone ~ '^55[0-9]{10,11}$'),
  code_hash text not null check (code_hash ~ '^[0-9a-f]{64}$'),
  password_hash text not null check (password_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts between 0 and 5),
  created_at timestamptz not null default now()
);
alter table public.irmao_salon_admin_credentials enable row level security;
alter table public.irmao_salon_enrollment_challenges enable row level security;
revoke all on public.irmao_salon_admin_credentials,public.irmao_salon_enrollment_challenges from public,anon,authenticated;
grant select,insert,update,delete on public.irmao_salon_admin_credentials,public.irmao_salon_enrollment_challenges to service_role;

alter table public.irmao_salon_catalog add column if not exists cost_cents integer check (cost_cents is null or cost_cents between 0 and 100000000);

create or replace function public.irmao_salon_duration_minutes(p_service text)
returns integer language sql immutable set search_path=pg_catalog as $$
  select case
    when lower(p_service) like '%corte + barba + limpeza de pele%' then 60
    when lower(p_service) like '%corte + barba%' then 60
    when lower(p_service) like '%corte + pigmentação%' then 60
    when lower(p_service) like '%corte + limpeza de pele%' then 60
    when lower(p_service) like '%pezinho + barba%' then 30
    when lower(p_service) like '%corte + limpeza nasal%' then 60
    when lower(p_service) like '%corte%' then 30
    else 30
  end;
$$;

create or replace function public.irmao_salon_request_appointment(
  p_name text,p_phone text,p_service text,p_date date,p_time time,p_note text,p_phone_hash text,p_ip_hash text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare appointment public.irmao_salon_appointments; recent_ip integer; recent_phone integer;
  local_now timestamp; local_day date; local_minutes integer; requested_minutes integer;
  professional_name text; requested_duration integer;
begin
  local_now:=now() at time zone 'America/Sao_Paulo'; local_day:=local_now::date;
  local_minutes:=extract(hour from local_now)::integer*60+extract(minute from local_now)::integer;
  requested_minutes:=extract(hour from p_time)::integer*60+extract(minute from p_time)::integer;
  professional_name:=substring(coalesce(p_note,'') from '^Profissional: ([[:alnum:]À-ÿ .''-]{2,80})$');
  requested_duration:=public.irmao_salon_duration_minutes(p_service);
  if p_name !~ '^[[:alnum:]À-ÿ][[:alnum:]À-ÿ .''-]{1,78}$' or p_phone !~ '^55[0-9]{10,11}$'
    or p_service !~ '^[[:alnum:]À-ÿ][[:alnum:]À-ÿ .''+&()-]{1,58}$'
    or p_date < local_day or p_date > local_day+1 or extract(dow from p_date)=0
    or requested_minutes<480 or requested_minutes>1365 or requested_minutes%30<>0
    or (p_date=local_day and p_time<=local_now::time) or (local_now::time>='12:00' and requested_minutes<720)
    or professional_name is null or professional_name not in ('Moabe','Miguel Oliveira','Eliezer Miranda Dias')
    or length(coalesce(p_note,''))>240 or p_phone_hash !~ '^[0-9a-f]{64}$' or p_ip_hash !~ '^[0-9a-f]{64}$'
  then return jsonb_build_object('error','invalid_appointment_window'); end if;
  if not ((requested_minutes>=480 and requested_minutes<720) or (requested_minutes>=720 and requested_minutes<840)
       or (requested_minutes>=840 and requested_minutes<1080) or (requested_minutes>=1080 and requested_minutes<=1365))
  then return jsonb_build_object('error','invalid_appointment_window'); end if;
  perform pg_advisory_xact_lock(hashtext(p_ip_hash));
  perform pg_advisory_xact_lock(hashtext(p_date::text||':'||professional_name));
  if exists(select 1 from public.irmao_salon_appointments existing where existing.appointment_date=p_date
    and existing.status in ('solicitado','confirmado')
    and substring(coalesce(existing.note,'') from '^Profissional: ([[:alnum:]À-ÿ .''-]{2,80})$')=professional_name
    and existing.appointment_time < p_time + make_interval(mins=>requested_duration)
    and p_time < existing.appointment_time + make_interval(mins=>public.irmao_salon_duration_minutes(existing.service_name)))
  then return jsonb_build_object('error','professional_unavailable'); end if;
  delete from public.irmao_salon_appointment_rate_events where created_at<now()-interval '1 day';
  select count(*) into recent_ip from public.irmao_salon_appointment_rate_events where ip_hash=p_ip_hash and created_at>now()-interval '1 hour';
  select count(*) into recent_phone from public.irmao_salon_appointment_rate_events where phone_hash=p_phone_hash and created_at>now()-interval '1 hour';
  if recent_ip>=20 or recent_phone>=4 then return jsonb_build_object('error','appointment_rate_limited'); end if;
  insert into public.irmao_salon_appointment_rate_events(phone_hash,ip_hash) values(p_phone_hash,p_ip_hash);
  insert into public.irmao_salon_appointments(client_name,client_phone,service_name,appointment_date,appointment_time,note)
    values(trim(p_name),p_phone,trim(p_service),p_date,p_time,trim(coalesce(p_note,''))) returning * into appointment;
  return jsonb_build_object('reference',appointment.reference,'status',appointment.status);
end;
$$;

create or replace function public.irmao_salon_can_fit_emergency(p_date date,p_time time,p_professional text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare minutes integer; now_sp timestamp;
begin
  now_sp:=now() at time zone 'America/Sao_Paulo'; minutes:=extract(hour from p_time)::integer*60+extract(minute from p_time)::integer;
  if p_professional not in ('Moabe','Miguel Oliveira','Eliezer Miranda Dias') or p_date<now_sp::date
    or p_date>now_sp::date+1 or extract(dow from p_date)=0 or minutes<480 or minutes>1365 or minutes%30<>0
    or (p_date=now_sp::date and p_time<=now_sp::time) then return false; end if;
  return not exists(select 1 from public.irmao_salon_appointments a where a.appointment_date=p_date
    and a.status in ('solicitado','confirmado')
    and substring(coalesce(a.note,'') from '^Profissional: ([[:alnum:]À-ÿ .''-]{2,80})$')=p_professional
    and a.appointment_time<p_time+interval '30 minutes'
    and p_time<a.appointment_time+make_interval(mins=>public.irmao_salon_duration_minutes(a.service_name)));
end;
$$;

create or replace function public.irmao_salon_create_emergency_appointment(
  p_admin_phone text,p_name text,p_phone text,p_date date,p_time time,p_professional text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare appointment public.irmao_salon_appointments;
begin
  if not exists(select 1 from public.irmao_salon_allowed_phones where phone=p_admin_phone and enabled)
    or p_name !~ '^[[:alnum:]À-ÿ][[:alnum:]À-ÿ .''-]{1,78}$' or p_phone !~ '^55[0-9]{10,11}$'
    or not public.irmao_salon_can_fit_emergency(p_date,p_time,p_professional)
  then return jsonb_build_object('error','emergency_slot_unavailable'); end if;
  perform pg_advisory_xact_lock(hashtext(p_date::text||':'||p_professional));
  if not public.irmao_salon_can_fit_emergency(p_date,p_time,p_professional)
  then return jsonb_build_object('error','emergency_slot_unavailable'); end if;
  insert into public.irmao_salon_appointments(client_name,client_phone,service_name,appointment_date,appointment_time,note,status,updated_by)
    values(trim(p_name),p_phone,'Corte emergente',p_date,p_time,'Profissional: '||p_professional,'confirmado',p_admin_phone)
    returning * into appointment;
  return jsonb_build_object('reference',appointment.reference,'status',appointment.status);
end;
$$;

revoke all on function public.irmao_salon_can_fit_emergency(date,time,text),
  public.irmao_salon_create_emergency_appointment(text,text,text,date,time,text) from public,anon,authenticated;
grant execute on function public.irmao_salon_can_fit_emergency(date,time,text),
  public.irmao_salon_create_emergency_appointment(text,text,text,date,time,text) to service_role;
revoke all on function public.irmao_salon_request_appointment(text,text,text,date,time,text,text,text) from public,anon,authenticated;
grant execute on function public.irmao_salon_request_appointment(text,text,text,date,time,text,text,text) to service_role;

commit;
