# Barbearia do Irmão

Site público de agendamento e painel privado de agenda/contabilidade, isolados para o salão do Irmão.

## Site

- `site/index.html`: página pública com as fotos de Moabe, Miguel Oliveira e Eliezer Miranda Dias, serviços, preços de referência, horários, consulta e cancelamento.
- `site/contabilidade/`: agenda, catálogo, clientes, lançamentos, pagamentos e relatórios.
- A agenda aceita pedidos para hoje ou amanhã, de segunda a sábado. O período de almoço (12h–14h) é apenas um pedido e exige confirmação da equipe no grupo. Os períodos não representam confirmação automática.
- Pedidos incluem o profissional escolhido. A migration `202610090006` impede sobreposição de atendimentos do mesmo profissional e horário; outro profissional pode receber pedido naquele intervalo.
- Os preços iniciais foram lidos do HTML fornecido pelo proprietário e são cadastrados pela migration `202610090005`.

## Acesso e notificações

O painel exige telefone e senha, depois um código de uso único enviado ao grupo WhatsApp “2 Fatores”. A sessão expira em cinco horas. A função `irmao-salon` envia avisos de pedidos, cancelamentos e horários de almoço ao grupo. Ela não usa a API para mensagens de cobrança ou outros serviços.

Configure no Supabase os secrets `IRMAO_SALON_OTP_PEPPER`, `IRMAO_SALON_ADMIN_PASSWORD_HASH`, `IRMAO_SALON_GREEN_API_URL`, `IRMAO_SALON_GREEN_API_INSTANCE_ID` e `IRMAO_SALON_GREEN_API_TOKEN`. O token fica apenas no servidor, nunca no site público ou no repositório.

## Supabase

Aplicar as migrations `202610090001` a `202610090006` em ordem, implantar `supabase/functions/irmao-salon` e apontar `site/config.js` para a URL e a chave publicável do projeto. A função aplica rate limits aos pedidos, valida datas e períodos no fuso de São Paulo e verifica conflito de horário por profissional dentro de uma transação.
