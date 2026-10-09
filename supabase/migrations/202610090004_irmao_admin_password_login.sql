begin;

create table public.irmao_salon_admin_login_events (
  id bigint generated always as identity primary key,
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
create index irmao_salon_admin_login_rate on public.irmao_salon_admin_login_events(ip_hash,created_at desc);
alter table public.irmao_salon_admin_login_events enable row level security;
revoke all on public.irmao_salon_admin_login_events from public,anon,authenticated;
grant select,insert,delete on public.irmao_salon_admin_login_events to service_role;
grant usage,select on sequence public.irmao_salon_admin_login_events_id_seq to service_role;

create function public.irmao_salon_take_admin_login(p_ip_hash text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare recent integer;
begin
  if p_ip_hash !~ '^[0-9a-f]{64}$' then return false; end if;
  perform pg_advisory_xact_lock(hashtext(p_ip_hash));
  delete from public.irmao_salon_admin_login_events where created_at < now()-interval '1 day';
  select count(*) into recent from public.irmao_salon_admin_login_events
    where ip_hash=p_ip_hash and created_at>now()-interval '1 hour';
  if recent>=10 then return false; end if;
  insert into public.irmao_salon_admin_login_events(ip_hash) values(p_ip_hash);
  return true;
end;
$$;
revoke all on function public.irmao_salon_take_admin_login(text) from public,anon,authenticated;
grant execute on function public.irmao_salon_take_admin_login(text) to service_role;

commit;
