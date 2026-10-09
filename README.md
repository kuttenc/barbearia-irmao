# Barbearia do Irmão

Site público de agendamento e painel privado de agenda/contabilidade, isolados para o salão do Irmão.

## Site

- `site/index.html`: página pública com as fotos de Moabe, Miguel Oliveira e Eliezer Miranda Dias, serviços, preços de referência, horários, consulta e cancelamento.
- `site/contabilidade/`: agenda, catálogo, clientes, lançamentos, pagamentos e relatórios.
- A agenda aceita pedidos para hoje ou amanhã, de segunda a sábado. O período de almoço (12h–14h) é apenas um pedido e exige confirmação da equipe no grupo. Os períodos não representam confirmação automática.
- Os horários públicos usam intervalos de 30 minutos. Sobrancelha não aparece como serviço de agendamento.
- Pedidos incluem o profissional escolhido. A migration `202610090006` impede sobreposição de atendimentos do mesmo profissional e horário; outro profissional pode receber pedido naquele intervalo.
- Os preços iniciais foram lidos do HTML fornecido pelo proprietário e são cadastrados pela migration `202610090005`.

## Acesso e notificações

No primeiro acesso, cada irmão informa seu próprio telefone e cria uma senha; a aprovação é confirmada com um código enviado ao grupo WhatsApp “2 Fatores”. Entradas seguintes usam telefone, senha e código. A sessão expira em cinco horas. O painel confere encaixes de corte emergente e permite registrá-los manualmente. Novos pedidos, cancelamentos e cortes emergentes notificam o grupo.

O catálogo guarda o preço cobrado e o custo de cada item. Os relatórios calculam o lucro líquido e mostram a divisão de 50% para cada irmão quando os custos foram preenchidos.

Configure no Supabase `IRMAO_SALON_OTP_PEPPER` e os secrets de conexão da Green API. A senha é criada por cada pessoa no primeiro acesso e guardada como hash por telefone. O token fica apenas no servidor, nunca no site público ou no repositório.

## Supabase

Aplicar as migrations `202610090001` a `202610090007` em ordem, implantar `supabase/functions/irmao-salon` e apontar `site/config.js` para a URL e a chave publicável do projeto. A função aplica rate limits aos pedidos, valida datas e períodos no fuso de São Paulo e verifica conflito de horário por profissional dentro de uma transação.
