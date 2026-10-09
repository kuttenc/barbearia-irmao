begin;

-- Isolated accounting namespace for Irmão. No Gustavo/Talita/Tiago rows.
create table public.irmao_salon_allowed_phones (
  phone text primary key check (phone ~ '^55[0-9]{10,11}$'),
  role text not null check (role in ('owner','admin')),
  enabled boolean not null default true
);
insert into public.irmao_salon_allowed_phones(phone,role) values
  ('5512996597397','owner');

create table public.irmao_salon_otp_events (
  id bigint generated always as identity primary key,
  phone text not null,
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index irmao_salon_otp_rate_phone on public.irmao_salon_otp_events(phone,created_at desc);
create index irmao_salon_otp_rate_ip on public.irmao_salon_otp_events(ip_hash,created_at desc);
create table public.irmao_salon_otp_challenges (
  phone text primary key references public.irmao_salon_allowed_phones(phone),
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts between 0 and 5),
  consumed_at timestamptz,
  updated_at timestamptz not null default now()
);
create table public.irmao_salon_sessions (
  token_hash text primary key,
  phone text not null references public.irmao_salon_allowed_phones(phone),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index irmao_salon_sessions_phone on public.irmao_salon_sessions(phone,expires_at desc);

create table public.irmao_salon_catalog (
  id bigint generated always as identity primary key,
  name text not null check (length(name) between 2 and 60),
  kind text not null check (kind in ('servico','produto')),
  price_cents integer check (price_cents is null or price_cents between 1 and 100000000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(kind,name)
);
create table public.irmao_salon_entries (
  id bigint generated always as identity primary key,
  service_date date not null,
  period text not null check (period in ('manha','tarde','noite')),
  client_name text not null default '' check (length(client_name)<=80),
  payment text not null check (payment in ('recebido','pendente','nao_informado')),
  total_cents integer not null check (total_cents between 1 and 100000000),
  items jsonb not null check (jsonb_typeof(items)='array' and jsonb_array_length(items) between 1 and 20),
  created_by text not null references public.irmao_salon_allowed_phones(phone),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by text references public.irmao_salon_allowed_phones(phone)
);
create index irmao_salon_entries_date on public.irmao_salon_entries(service_date desc,id desc);

alter table public.irmao_salon_allowed_phones enable row level security;
alter table public.irmao_salon_otp_events enable row level security;
alter table public.irmao_salon_otp_challenges enable row level security;
alter table public.irmao_salon_sessions enable row level security;
alter table public.irmao_salon_catalog enable row level security;
alter table public.irmao_salon_entries enable row level security;
revoke all on public.irmao_salon_allowed_phones,public.irmao_salon_otp_events,
  public.irmao_salon_otp_challenges,public.irmao_salon_sessions,
  public.irmao_salon_catalog,public.irmao_salon_entries from public,anon,authenticated;
grant select,insert,update,delete on public.irmao_salon_allowed_phones,public.irmao_salon_otp_events,
  public.irmao_salon_otp_challenges,public.irmao_salon_sessions,
  public.irmao_salon_catalog,public.irmao_salon_entries to service_role;
grant usage,select on sequence public.irmao_salon_otp_events_id_seq,
  public.irmao_salon_catalog_id_seq,public.irmao_salon_entries_id_seq to service_role;

create function public.irmao_salon_issue_otp(p_phone text,p_ip_hash text,p_code_hash text)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare recent_phone integer; recent_ip integer;
begin
  if not exists(select 1 from public.irmao_salon_allowed_phones where phone=p_phone and enabled)
    then return 'not_allowed'; end if;
  delete from public.irmao_salon_otp_events where created_at<now()-interval '1 day';
  select count(*) into recent_phone from public.irmao_salon_otp_events
    where phone=p_phone and created_at>now()-interval '1 hour';
  select count(*) into recent_ip from public.irmao_salon_otp_events
    where ip_hash=p_ip_hash and created_at>now()-interval '1 hour';
  if recent_phone>=5 or recent_ip>=10 then return 'rate_limited'; end if;
  if exists(select 1 from public.irmao_salon_otp_events
      where phone=p_phone and created_at>now()-interval '60 seconds') then return 'cooldown'; end if;
  insert into public.irmao_salon_otp_events(phone,ip_hash) values(p_phone,p_ip_hash);
  insert into public.irmao_salon_otp_challenges(phone,code_hash,expires_at,attempts,consumed_at,updated_at)
    values(p_phone,p_code_hash,now()+interval '10 minutes',0,null,now())
    on conflict(phone) do update set code_hash=excluded.code_hash,expires_at=excluded.expires_at,
      attempts=0,consumed_at=null,updated_at=now();
  return 'sent';
end;
$$;
create function public.irmao_salon_verify_otp(p_phone text,p_code_hash text,p_token_hash text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare challenge public.irmao_salon_otp_challenges; session_expiry timestamptz;
begin
  select * into challenge from public.irmao_salon_otp_challenges where phone=p_phone for update;
  if not found or challenge.consumed_at is not null or challenge.expires_at<=now() or challenge.attempts>=5
    then return jsonb_build_object('ok',false,'reason','expired'); end if;
  if challenge.code_hash<>p_code_hash then
    update public.irmao_salon_otp_challenges set attempts=attempts+1,updated_at=now() where phone=p_phone;
    return jsonb_build_object('ok',false,'reason','invalid');
  end if;
  update public.irmao_salon_otp_challenges set consumed_at=now(),updated_at=now() where phone=p_phone;
  session_expiry:=now()+interval '5 hours';
  insert into public.irmao_salon_sessions(token_hash,phone,expires_at)
    values(p_token_hash,p_phone,session_expiry);
  return jsonb_build_object('ok',true,'expires_at',session_expiry);
end;
$$;
create function public.irmao_salon_create_entry(p_phone text,p_service_date date,p_period text,
  p_client_name text,p_payment text,p_items jsonb,p_total_cents integer)
returns public.irmao_salon_entries language plpgsql security definer set search_path=pg_catalog,public as $$
declare result public.irmao_salon_entries; calculated integer;
begin
  if not exists(select 1 from public.irmao_salon_allowed_phones where phone=p_phone and enabled)
    then raise exception 'unauthorized_actor'; end if;
  if p_service_date>(now() at time zone 'America/Sao_Paulo')::date or p_service_date<date '2020-01-01'
    or p_period not in ('manha','tarde','noite') or p_payment not in ('recebido','pendente','nao_informado')
    or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>20
    then raise exception 'invalid_entry'; end if;
  select sum((x->>'quantity')::integer*(x->>'unit_price_cents')::integer) into calculated
    from jsonb_array_elements(p_items) x;
  if calculated is null or calculated<>p_total_cents or calculated<=0 or calculated>100000000
    then raise exception 'invalid_total'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x where
      coalesce(length(x->>'name'),0)<2 or coalesce((x->>'quantity')::integer,0)<1
      or coalesce((x->>'unit_price_cents')::integer,0)<1) then raise exception 'invalid_item'; end if;
  insert into public.irmao_salon_entries(service_date,period,client_name,payment,total_cents,items,created_by)
    values(p_service_date,p_period,left(coalesce(p_client_name,''),80),p_payment,p_total_cents,p_items,p_phone)
    returning * into result;
  return result;
end;
$$;
revoke all on function public.irmao_salon_issue_otp(text,text,text),
  public.irmao_salon_verify_otp(text,text,text),
  public.irmao_salon_create_entry(text,date,text,text,text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.irmao_salon_issue_otp(text,text,text),
  public.irmao_salon_verify_otp(text,text,text),
  public.irmao_salon_create_entry(text,date,text,text,text,jsonb,integer) to service_role;
commit;
