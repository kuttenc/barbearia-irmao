const encoder = new TextEncoder();
const allowedPhones = new Set(['5512996597397']);
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}
function normalizePhone(value: unknown): string | null {
  let phone = String(value ?? '').replace(/\D/g, '');
  if (phone.length === 10 || phone.length === 11) phone = `55${phone}`;
  return /^55\d{10,11}$/.test(phone) ? phone : null;
}
function hex(bytes: Uint8Array) { return [...bytes].map(v => v.toString(16).padStart(2, '0')).join(''); }
async function sha256(value: string) { return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)))); }
function secret(name: string) { return Deno.env.get(name) || ''; }
async function sendAppointmentMessage(destination: string, message: string): Promise<boolean> {
  // Prefer dedicated values; fallback names are the sender already used by Validade PT260.
  const base = (secret('IRMAO_SALON_NOTIFY_GREEN_API_URL') || secret('GREEN_API_FALLBACK_URL') || secret('GREEN_API_URL')).replace(/\/$/, '');
  const instance = secret('IRMAO_SALON_NOTIFY_GREEN_API_INSTANCE_ID') || secret('GREEN_API_FALLBACK_INSTANCE_ID') || secret('GREEN_API_INSTANCE_ID');
  const token = secret('IRMAO_SALON_NOTIFY_GREEN_API_TOKEN') || secret('GREEN_API_FALLBACK_TOKEN') || secret('GREEN_API_TOKEN');
  if (!/^https:\/\/[a-z0-9.-]+\.api\.greenapi\.com$/i.test(base) || !/^\d{6,20}$/.test(instance) || token.length < 20)
    return false;
  try {
    const response = await fetch(`${base}/waInstance${instance}/sendMessage/${token}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chatId: `${destination}@c.us`, message }), signal: AbortSignal.timeout(12000),
    });
    if (!response.ok) return false;
    const receipt = await response.json();
    return /^[A-Za-z0-9_-]{5,160}$/.test(String(receipt?.idMessage || ''));
  } catch { return false; }
}
function appointmentWhen(date: string, time: string) {
  const [year, month, day] = date.split('-');
  return `${day}/${month}/${year} às ${time.slice(0, 5)}`;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  try {
    if (Number(request.headers.get('content-length') || 0) > 32768) return json({ error: 'too_large' }, 413);
    const body = await request.json();
    if (!body || typeof body !== 'object' || JSON.stringify(body).length > 32768) return json({ error: 'invalid_request' }, 400);
    const supabaseUrl = secret('SUPABASE_URL').replace(/\/$/, '');
    const serviceKey = secret('SUPABASE_SERVICE_ROLE_KEY') || secret('SUPABASE_SECRET_KEY');
    const pepper = secret('IRMAO_SALON_OTP_PEPPER');
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(supabaseUrl) || !serviceKey || !pepper)
      return json({ error: 'service_not_configured' }, 503);
    const rest = async (path: string, data?: unknown, method = 'POST', prefer = 'return=representation') => {
      const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
        method, headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`,
          'Content-Type': 'application/json', Prefer: prefer },
        ...(data === undefined ? {} : { body: JSON.stringify(data) }),
      });
      const text = await response.text();
      if (!response.ok) throw new Error(`database_${response.status}`);
      return text ? JSON.parse(text) : null;
    };
    const action = String(body.action || '');

    if (action === 'appointment_services') {
      const items = await rest('irmao_salon_catalog?select=name,kind,price_cents,active&active=eq.true&order=kind.asc,name.asc', undefined, 'GET');
      return json({ items: items || [] });
    }

    if (action === 'appointment_request') {
      const phone = normalizePhone(body.phone);
      const name = String(body.name || '').trim().replace(/\s+/g, ' ');
      const service = String(body.service || '').trim().replace(/\s+/g, ' ');
      const date = String(body.date || '');
      const time = String(body.time || '');
      const note = String(body.note || '').trim();
      if (!phone || name.length < 2 || name.length > 80 || service.length < 2 || service.length > 60 ||
          !/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^\d{2}:\d{2}$/.test(time) || note.length > 240)
        return json({ error: 'invalid_appointment' }, 400);
      const ip = request.headers.get('cf-connecting-ip') || request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';
      const result = await rest('rpc/irmao_salon_request_appointment', {
        p_name: name, p_phone: phone, p_service: service, p_date: date, p_time: time,
        p_note: note, p_phone_hash: await sha256(`${pepper}:appointment-phone:${phone}`),
        p_ip_hash: await sha256(`${pepper}:appointment-ip:${ip}`),
      });
      if (result?.error === 'appointment_rate_limited') return json({ error: result.error }, 429);
      if (result?.error === 'invalid_appointment') return json({ error: result.error }, 400);
      const sent = result?.reference ? await sendAppointmentMessage('5512996597397',
        `Barbearia do Irmão — novo pedido de agendamento\n${name}\n${service}\n${appointmentWhen(date, time)}\nWhatsApp: +${phone}\nReferência: ${result.reference}`) : false;
      return json({ appointment: result, owner_notified: sent });
    }
    if (action === 'appointment_status') {
      const phone = normalizePhone(body.phone);
      const reference = String(body.reference || '').trim();
      if (!phone || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(reference))
        return json({ error: 'appointment_not_found' }, 404);
      const rows = await rest(`irmao_salon_appointments?select=reference,service_name,appointment_date,appointment_time,status&reference=eq.${reference}&client_phone=eq.${phone}&limit=1`, undefined, 'GET');
      if (!rows?.length) return json({ error: 'appointment_not_found' }, 404);
      return json({ appointment: rows[0] });
    }
    if (action === 'appointment_cancel_by_client') {
      const phone = normalizePhone(body.phone);
      const reference = String(body.reference || '').trim();
      if (!phone || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(reference))
        return json({ error: 'appointment_not_found' }, 404);
      const found = await rest(`irmao_salon_appointments?select=id,client_name,client_phone,service_name,appointment_date,appointment_time,status&reference=eq.${reference}&client_phone=eq.${phone}&status=in.(solicitado,confirmado)&limit=1`, undefined, 'GET');
      if (!found?.length) return json({ error: 'appointment_not_found' }, 404);
      const item = found[0];
      const updated = await rest(`irmao_salon_appointments?id=eq.${item.id}&client_phone=eq.${phone}&status=eq.${item.status}`,
        { status: 'cancelado', updated_at: new Date().toISOString() }, 'PATCH');
      if (!Array.isArray(updated) || updated.length !== 1) return json({ error: 'appointment_not_found' }, 404);
      const notified = await sendAppointmentMessage('5512996597397',
        `Barbearia do Irmão — cliente cancelou um pedido de horário\n${item.client_name}\n${item.service_name}\n${appointmentWhen(item.appointment_date, item.appointment_time)}\nWhatsApp: +${phone}`);
      return json({ cancelled: true, owner_notified: notified });
    }

    if (action === 'admin_login') {
      const phone = normalizePhone(body.phone);
      const password = String(body.password || '');
      if (!phone || !allowedPhones.has(phone) || password.length < 8 || password.length > 128)
        return json({ error: 'invalid_credentials' }, 401);
      const ip = request.headers.get('cf-connecting-ip') || request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';
      const ipHash = await sha256(`${pepper}:admin-login-ip:${ip}`);
      if (!await rest('rpc/irmao_salon_take_admin_login', { p_ip_hash: ipHash }))
        return json({ error: 'try_later' }, 429);
      const expected = secret('IRMAO_SALON_ADMIN_PASSWORD_HASH');
      if (!/^[0-9a-f]{64}$/i.test(expected) || await sha256(`${pepper}:admin-password:${phone}:${password}`) !== expected.toLowerCase())
        return json({ error: 'invalid_credentials' }, 401);
      const rawToken = hex(crypto.getRandomValues(new Uint8Array(32)));
      const expiresAt = new Date(Date.now() + 5 * 60 * 60 * 1000).toISOString();
      await rest('irmao_salon_sessions', { token_hash: await sha256(rawToken), phone, expires_at: expiresAt });
      return json({ token: rawToken, phone, role: 'owner', expires_at: expiresAt });
    }

    if (action === 'send_code') {
      const phone = normalizePhone(body.phone);
      if (!phone || !allowedPhones.has(phone)) return json({ error: 'phone_not_allowed' }, 403);
      const greenUrl = secret('IRMAO_SALON_GREEN_API_URL');
      const instance = secret('IRMAO_SALON_GREEN_API_INSTANCE_ID');
      const token = secret('IRMAO_SALON_GREEN_API_TOKEN');
      if (!/^https:\/\/[a-z0-9.-]+\.api\.greenapi\.com$/i.test(greenUrl) || !/^\d{6,20}$/.test(instance) || token.length < 20)
        return json({ error: 'whatsapp_not_configured' }, 503);
      const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, '0');
      const codeHash = await sha256(`${pepper}:${phone}:${code}`);
      const ip = request.headers.get('cf-connecting-ip') || request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';
      const ipHash = await sha256(`${pepper}:ip:${ip}`);
      const issued = await rest('rpc/irmao_salon_issue_otp', { p_phone: phone, p_ip_hash: ipHash, p_code_hash: codeHash });
      if (issued !== 'sent') return json({ error: issued === 'cooldown' ? 'please_wait' :
        issued === 'rate_limited' ? 'try_later' : 'phone_not_allowed' }, issued === 'not_allowed' ? 403 : 429);
      const response = await fetch(`${greenUrl}/waInstance${instance}/sendMessage/${token}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chatId: `${phone}@c.us`, message: `Código de acesso ao painel da Barbearia do Irmão: ${code}. Ele vence em 10 minutos. Não compartilhe este código. A sessão termina 5 horas após a confirmação.` }),
      });
      if (!response.ok) return json({ error: 'whatsapp_delivery_failed' }, 503);
      const sent = await response.json();
      if (!/^[A-Za-z0-9_-]{5,160}$/.test(String(sent?.idMessage || ''))) return json({ error: 'whatsapp_delivery_failed' }, 503);
      return json({ sent: true, destination: phone.slice(-4) });
    }

    if (action === 'verify_code') {
      const phone = normalizePhone(body.phone);
      const code = String(body.code || '').trim();
      if (!phone || !allowedPhones.has(phone) || !/^\d{6}$/.test(code)) return json({ error: 'invalid_code' }, 400);
      const rawToken = hex(crypto.getRandomValues(new Uint8Array(32)));
      const result = await rest('rpc/irmao_salon_verify_otp', {
        p_phone: phone, p_code_hash: await sha256(`${pepper}:${phone}:${code}`), p_token_hash: await sha256(rawToken),
      });
      if (!result?.ok) return json({ error: result?.reason === 'expired' ? 'code_expired' : 'invalid_code' }, 401);
      return json({ token: rawToken, phone, role: 'owner', expires_at: result.expires_at });
    }

    const bearer = request.headers.get('authorization') || '';
    const rawToken = bearer.startsWith('Bearer ') ? bearer.slice(7) : '';
    if (!/^[0-9a-f]{64}$/.test(rawToken)) return json({ error: 'unauthorized' }, 401);
    const tokenHash = await sha256(rawToken);
    const sessionRows = await rest(`irmao_salon_sessions?select=phone,expires_at&token_hash=eq.${tokenHash}&revoked_at=is.null&expires_at=gt.${encodeURIComponent(new Date().toISOString())}`, undefined, 'GET');
    const session = sessionRows?.[0];
    if (!session || !allowedPhones.has(session.phone)) return json({ error: 'session_expired' }, 401);

    if (action === 'logout') {
      await rest(`irmao_salon_sessions?token_hash=eq.${tokenHash}&revoked_at=is.null`, { revoked_at: new Date().toISOString() }, 'PATCH');
      return json({ ok: true });
    }
    if (action === 'appointment_list') {
      const rows = await rest('irmao_salon_appointments?select=id,reference,client_name,client_phone,service_name,appointment_date,appointment_time,note,status,created_at&order=appointment_date.asc,appointment_time.asc&limit=300', undefined, 'GET');
      return json({ appointments: rows || [] });
    }
    if (action === 'appointment_update') {
      const id = Number(body.id);
      const status = String(body.status || '');
      if (!Number.isSafeInteger(id) || !['confirmado','cancelado','concluido'].includes(status))
        return json({ error: 'invalid_appointment_update' }, 400);
      const before = await rest(`irmao_salon_appointments?select=id,client_name,client_phone,service_name,appointment_date,appointment_time,status&id=eq.${id}&limit=1`, undefined, 'GET');
      if (!before?.length) return json({ ok: false });
      const rows = await rest(`irmao_salon_appointments?id=eq.${id}&status=neq.cancelado`,
        { status, updated_at: new Date().toISOString(), updated_by: session.phone }, 'PATCH');
      const changed = Array.isArray(rows) && rows.length === 1 && before[0].status !== status;
      let clientNotified: boolean | null = null;
      if (changed && ['confirmado','cancelado'].includes(status)) {
        const item = before[0];
        const verb = status === 'confirmado' ? 'confirmado' : 'cancelado';
        clientNotified = await sendAppointmentMessage(item.client_phone,
          `Barbearia do Irmão — seu horário foi ${verb}.\n${item.service_name}\n${appointmentWhen(item.appointment_date, item.appointment_time)}\nSe precisar, fale com a barbearia pelo WhatsApp +5512996597397.`);
      }
      return json({ ok: Array.isArray(rows) && rows.length === 1, client_notified: clientNotified });
    }
    if (action === 'catalog_list') {
      const items = await rest('irmao_salon_catalog?select=id,name,kind,price_cents,active,updated_at&order=kind.asc,name.asc', undefined, 'GET');
      return json({ items: items || [], role: 'owner', expires_at: session.expires_at });
    }
    if (action === 'catalog_save') {
      const id = body.item?.id ? Number(body.item.id) : null;
      const name = String(body.item?.name || '').trim().replace(/\s+/g, ' ');
      const kind = String(body.item?.kind || '');
      const price = Number(body.item?.price_cents);
      if (name.length < 2 || name.length > 60 || !['servico','produto'].includes(kind) ||
          !Number.isSafeInteger(price) || price < 1 || price > 100_000_000 || (id !== null && !Number.isSafeInteger(id)))
        return json({ error: 'invalid_catalog_item' }, 400);
      const saved = await rest(id ? `irmao_salon_catalog?id=eq.${id}` : 'irmao_salon_catalog',
        { name, kind, price_cents: price, active: true, updated_at: new Date().toISOString() },
        id ? 'PATCH' : 'POST');
      return json({ item: Array.isArray(saved) ? saved[0] : saved });
    }
    if (action === 'catalog_deactivate') {
      const id = Number(body.id);
      if (!Number.isSafeInteger(id)) return json({ error: 'invalid_item' }, 400);
      await rest(`irmao_salon_catalog?id=eq.${id}`, { active: false, updated_at: new Date().toISOString() }, 'PATCH');
      return json({ ok: true });
    }
    if (action === 'customer_list') {
      const customers = await rest('irmao_salon_customers?select=id,name,phone_suffix,frequency,fixed_day,package_note,active&active=eq.true&order=name.asc', undefined, 'GET');
      return json({ customers: customers || [] });
    }
    if (action === 'customer_save') {
      const customer = body.customer || {};
      const name = String(customer.name || '').trim().replace(/\s+/g, ' ');
      const suffix = String(customer.phone_suffix || '').replace(/\D/g, '');
      const frequency = String(customer.frequency || 'nenhuma');
      const day = customer.fixed_day === '' || customer.fixed_day == null ? null : Number(customer.fixed_day);
      const note = String(customer.package_note || '').trim().slice(0, 180);
      const id = customer.id ? Number(customer.id) : null;
      if (name.length < 2 || name.length > 100 || (suffix && !/^\d{4}$/.test(suffix)) ||
          !['nenhuma','semanal','mensal'].includes(frequency) ||
          (frequency === 'semanal' && (!Number.isInteger(day) || day < 1 || day > 7)) ||
          (frequency === 'mensal' && (!Number.isInteger(day) || day < 1 || day > 31)) ||
          (frequency === 'nenhuma' && day !== null) || (id !== null && !Number.isSafeInteger(id)))
        return json({ error: 'invalid_customer' }, 400);
      const data = { name, phone_suffix: suffix, frequency, fixed_day: day, package_note: note, active: true, updated_at: new Date().toISOString() };
      const saved = await rest(id ? `irmao_salon_customers?id=eq.${id}` : 'irmao_salon_customers?on_conflict=name,phone_suffix',
        data, id ? 'PATCH' : 'POST', id ? 'return=representation' : 'resolution=merge-duplicates,return=representation');
      return json({ customer: Array.isArray(saved) ? saved[0] : saved });
    }
    if (action === 'entry_list') {
      const start = String(body.start || ''), end = String(body.end || '');
      if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end) || start > end || end < '2020-01-01')
        return json({ error: 'invalid_period' }, 400);
      const rows = await rest(`irmao_salon_entries?select=*&service_date=gte.${start}&service_date=lte.${end}&order=service_date.desc,id.desc`, undefined, 'GET');
      return json({ entries: rows || [] });
    }
    if (action === 'entry_create') {
      const e = body.entry || {};
      const items = Array.isArray(e.items) ? e.items : [];
      const total = items.reduce((sum: number, x: any) => sum + Number(x.quantity) * Number(x.unit_price_cents), 0);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(String(e.service_date || '')) ||
          !['manha','tarde','noite'].includes(e.period) || !['recebido','pendente','nao_informado'].includes(e.payment) ||
          !['cartao','pix','dinheiro','nao_informado'].includes(e.payment_method) ||
          (e.payment !== 'recebido' && e.payment_method !== 'nao_informado') ||
          (e.customer_id != null && (!Number.isSafeInteger(Number(e.customer_id)) || Number(e.customer_id) < 1)) ||
          items.length < 1 || items.length > 20 || !Number.isSafeInteger(total) || total <= 0 || total > 100_000_000 ||
          items.some((x: any) => typeof x.name !== 'string' || x.name.trim().length < 2 || x.name.length > 60 ||
            !['servico','produto'].includes(x.kind) || !Number.isSafeInteger(Number(x.quantity)) || Number(x.quantity) < 1 ||
            !Number.isSafeInteger(Number(x.unit_price_cents)) || Number(x.unit_price_cents) < 1))
        return json({ error: 'invalid_entry' }, 400);
      const saved = await rest('rpc/irmao_salon_create_entry', { p_phone: session.phone,
        p_service_date: e.service_date, p_period: e.period, p_client_name: String(e.client_name || '').slice(0, 80),
        p_payment: e.payment, p_payment_method: e.payment_method, p_customer_id: e.customer_id == null ? null : Number(e.customer_id),
        p_items: items, p_total_cents: total });
      return json({ entry: saved });
    }
    if (action === 'entry_cancel') {
      const id = Number(body.id);
      if (!Number.isSafeInteger(id)) return json({ error: 'invalid_entry' }, 400);
      const updated = await rest(`irmao_salon_entries?id=eq.${id}&cancelled_at=is.null`,
        { cancelled_at: new Date().toISOString(), cancelled_by: session.phone, updated_at: new Date().toISOString() }, 'PATCH');
      return json({ ok: Array.isArray(updated) && updated.length === 1 });
    }
    return json({ error: 'unknown_action' }, 400);
  } catch {
    return json({ error: 'request_failed' }, 503);
  }
});
