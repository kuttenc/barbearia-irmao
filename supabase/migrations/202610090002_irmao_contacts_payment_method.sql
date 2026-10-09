begin;

-- Contacts and package notes start empty in the Irmão salon.
create table public.irmao_salon_customers (
  id bigint generated always as identity primary key,
  name text not null check (length(name) between 2 and 100),
  phone_suffix text not null default '' check (phone_suffix = '' or phone_suffix ~ '^[0-9]{4}$'),
  frequency text not null default 'nenhuma' check (frequency in ('nenhuma','semanal','mensal')),
  fixed_day smallint,
  package_note text not null default '' check (length(package_note) <= 180),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (name, phone_suffix),
  check ((frequency = 'nenhuma' and fixed_day is null) or
         (frequency = 'semanal' and fixed_day between 1 and 7) or
         (frequency = 'mensal' and fixed_day between 1 and 31))
);

alter table public.irmao_salon_entries
  add column payment_method text not null default 'nao_informado'
    check (payment_method in ('cartao','pix','dinheiro','nao_informado')),
  add column customer_id bigint references public.irmao_salon_customers(id) on delete set null;

alter table public.irmao_salon_customers enable row level security;
revoke all on public.irmao_salon_customers from public,anon,authenticated;
grant select,insert,update,delete on public.irmao_salon_customers to service_role;
grant usage,select on sequence public.irmao_salon_customers_id_seq to service_role;

drop function public.irmao_salon_create_entry(text,date,text,text,text,jsonb,integer);
create function public.irmao_salon_create_entry(
  p_phone text, p_service_date date, p_period text, p_client_name text,
  p_payment text, p_payment_method text, p_customer_id bigint,
  p_items jsonb, p_total_cents integer
) returns public.irmao_salon_entries
language plpgsql security definer set search_path=pg_catalog,public as $$
declare result public.irmao_salon_entries; calculated integer;
begin
  if not exists(select 1 from public.irmao_salon_allowed_phones where phone=p_phone and enabled)
    then raise exception 'unauthorized_actor'; end if;
  if p_service_date>(now() at time zone 'America/Sao_Paulo')::date or p_service_date<date '2020-01-01'
    or p_period not in ('manha','tarde','noite')
    or p_payment not in ('recebido','pendente','nao_informado')
    or p_payment_method not in ('cartao','pix','dinheiro','nao_informado')
    or (p_payment<>'recebido' and p_payment_method<>'nao_informado')
    or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>20
    then raise exception 'invalid_entry'; end if;
  if p_customer_id is not null and not exists(
    select 1 from public.irmao_salon_customers where id=p_customer_id and active
  ) then raise exception 'invalid_customer'; end if;
  select sum((x->>'quantity')::integer*(x->>'unit_price_cents')::integer) into calculated
    from jsonb_array_elements(p_items) x;
  if calculated is null or calculated<>p_total_cents or calculated<=0 or calculated>100000000
    then raise exception 'invalid_total'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x where
      coalesce(length(x->>'name'),0)<2 or coalesce((x->>'quantity')::integer,0)<1
      or coalesce((x->>'unit_price_cents')::integer,0)<1)
    then raise exception 'invalid_item'; end if;
  insert into public.irmao_salon_entries(
    service_date,period,client_name,payment,payment_method,customer_id,total_cents,items,created_by
  ) values (
    p_service_date,p_period,left(coalesce(p_client_name,''),80),p_payment,p_payment_method,
    p_customer_id,p_total_cents,p_items,p_phone
  ) returning * into result;
  return result;
end;
$$;

revoke all on function public.irmao_salon_create_entry(text,date,text,text,text,text,bigint,jsonb,integer)
  from public,anon,authenticated;
grant execute on function public.irmao_salon_create_entry(text,date,text,text,text,text,bigint,jsonb,integer)
  to service_role;

commit;
