begin;

insert into public.irmao_salon_catalog(name,kind,price_cents)
values
  ('Corte - Pix ou Débito','servico',3500),
  ('Corte - Dinheiro','servico',3000),
  ('Barba','servico',2000),
  ('Corte + Barba - Pix ou Débito','servico',5000),
  ('Corte + Barba - Dinheiro','servico',4500),
  ('Corte + Barba + Limpeza de Pele','servico',6000),
  ('Pigmentação','servico',1500),
  ('Pezinho','servico',1000),
  ('Corte + Pigmentação','servico',5000),
  ('Limpeza de Pele','servico',1000),
  ('Corte + Limpeza de Pele','servico',4500),
  ('Corte + Limpeza Nasal','servico',4000),
  ('Pezinho + Barba','servico',2500)
on conflict(kind,name) do nothing;

commit;
