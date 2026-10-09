begin;

create table public.irmao_salon_appointments (
  id bigint generated always as identity primary key,
  reference uuid not null unique default gen_random_uuid(),
  client_name text not null check (length(client_name) between 2 and 80),
  client_phone text not null check (client_phone ~ '^55[0-9]{10,11}$'),
  service_name text not null check (length(service_name) between 2 and 60),
  appointment_date date not null,
  appointment_time time not null,
  note text not null default '' check (length(note)<=240),
  status text not null default 'solicitado' check (status in ('solicitado','confirmado','cancelado','concluido')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text references public.irmao_salon_allowed_phones(phone)
);
create index irmao_salon_appointments_date on public.irmao_salon_appointments(appointment_date,appointment_time);
alter table public.irmao_salon_appointments enable row level security;
revoke all on public.irmao_salon_appointments from public,anon,authenticated;
grant select,insert,update,delete on public.irmao_salon_appointments to service_role;
grant usage,select on sequence public.irmao_salon_appointments_id_seq to service_role;

create table public.irmao_salon_appointment_rate_events (
  id bigint generated always as identity primary key,
  phone_hash text not null,
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index irmao_salon_appointment_rate_ip on public.irmao_salon_appointment_rate_events(ip_hash,created_at desc);
alter table public.irmao_salon_appointment_rate_events enable row level security;
revoke all on public.irmao_salon_appointment_rate_events from public,anon,authenticated;
grant select,insert,delete on public.irmao_salon_appointment_rate_events to service_role;
grant usage,select on sequence public.irmao_salon_appointment_rate_events_id_seq to service_role;

create function public.irmao_salon_request_appointment(
  p_name text,p_phone text,p_service text,p_date date,p_time time,p_note text,p_phone_hash text,p_ip_hash text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare appointment public.irmao_salon_appointments; recent_ip integer; recent_phone integer;
begin
  if p_name !~ '^[[:alnum:]À-ÿ][[:alnum:]À-ÿ .''-]{1,78}$'
    or p_phone !~ '^55[0-9]{10,11}$' or p_service !~ '^[[:alnum:]À-ÿ][[:alnum:]À-ÿ .''+&()-]{1,58}$'
    or p_date < (now() at time zone 'America/Sao_Paulo')::date
    or p_date > (now() at time zone 'America/Sao_Paulo')::date + 120
    or (p_date=(now() at time zone 'America/Sao_Paulo')::date
      and p_time <= (now() at time zone 'America/Sao_Paulo')::time)
    or length(coalesce(p_note,'')) > 240
    or p_phone_hash !~ '^[0-9a-f]{64}$' or p_ip_hash !~ '^[0-9a-f]{64}$'
  then return jsonb_build_object('error','invalid_appointment'); end if;

  perform pg_advisory_xact_lock(hashtext(p_ip_hash));
  delete from public.irmao_salon_appointment_rate_events where created_at < now()-interval '1 day';
  select count(*) into recent_ip from public.irmao_salon_appointment_rate_events
    where ip_hash=p_ip_hash and created_at>now()-interval '1 hour';
  select count(*) into recent_phone from public.irmao_salon_appointment_rate_events
    where phone_hash=p_phone_hash and created_at>now()-interval '1 hour';
  if recent_ip>=20 or recent_phone>=4 then return jsonb_build_object('error','appointment_rate_limited'); end if;
  insert into public.irmao_salon_appointment_rate_events(phone_hash,ip_hash) values(p_phone_hash,p_ip_hash);
  insert into public.irmao_salon_appointments(client_name,client_phone,service_name,appointment_date,appointment_time,note)
    values(trim(p_name),p_phone,trim(p_service),p_date,p_time,trim(coalesce(p_note,''))) returning * into appointment;
  return jsonb_build_object('reference',appointment.reference,'status',appointment.status);
end;
$$;
revoke all on function public.irmao_salon_request_appointment(text,text,text,date,time,text,text,text) from public,anon,authenticated;
grant execute on function public.irmao_salon_request_appointment(text,text,text,date,time,text,text,text) to service_role;

commit;
