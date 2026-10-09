# Barbearia do Irmão

Instância isolada criada para o telefone `+55 12 99659-7397`. A pasta não importa catálogo com preços, clientes, agenda, mensagens ou credenciais dos outros salões.

Página pública: https://kuttenc.github.io/barbearia-irmao/

## Site

`site/index.html` combina um formulário público de pedido de horário com a área privada do proprietário. A imagem enviada foi aplicada como logo no cabeçalho e na página de agendamento. O cliente registra nome, telefone, serviço, data e hora pretendidos, recebe uma referência e consulta o status pelo site. O pedido começa como **solicitado**; o horário só fica confirmado quando o proprietário o confirma na agenda. O sistema não presume horário de funcionamento, preços nem disponibilidade.

A área privada usa o painel de contabilidade do salão: catálogo sem preços preenchidos, lançamento de atendimentos, clientes, formas de pagamento, relatórios e impressão em PDF. O proprietário entra com senha e telefone autorizado; a sessão expira após cinco horas. Não há chatbot.

O telefone de acesso já está preparado como `5512996597397`. A página pública ainda precisa receber a URL e a chave publicável do projeto em `site/config.js`.

## Backend isolado

As migrations `202610090001` a `202610090004` criam tabelas próprias `irmao_salon_*`, com RLS e acesso direto revogado para `anon` e `authenticated`. A função `irmao-salon` valida sessões privadas e grava pedidos públicos com limites por telefone e IP. Ela usa os secrets `IRMAO_SALON_OTP_PEPPER` e `IRMAO_SALON_ADMIN_PASSWORD_HASH`; o hash da senha não fica no navegador nem no repositório. Para avisos de agendamento, prefere `IRMAO_SALON_NOTIFY_GREEN_API_URL`, `IRMAO_SALON_NOTIFY_GREEN_API_INSTANCE_ID` e `IRMAO_SALON_NOTIFY_GREEN_API_TOKEN`; se não forem definidos, usa os `GREEN_API_FALLBACK_*` do remetente da Validade PT260. O envio fica restrito a novo pedido para o Irmão e confirmação/cancelamento para o cliente; não chama cobrança nem outras rotinas da Validade.

Para configurar uma instalação, aplicar as quatro migrations em ordem, implantar a Edge Function e preencher `site/config.js` com URL e chave anon/publicável. O envio usa a instância Green API fallback da Validade PT260 configurada no projeto e só é disparado por eventos da agenda.
