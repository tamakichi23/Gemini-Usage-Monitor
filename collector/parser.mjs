// Original implementation. Input consists only of the two usage cards' visible text.
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const JST = 9 * HOUR;

export class UsageError extends Error {
  constructor(code) { super(code); this.code = code; }
}

function validDate(year, month, day, hour, minute) {
  const local = new Date(Date.UTC(year, month - 1, day, hour, minute));
  if (local.getUTCFullYear() !== year || local.getUTCMonth() !== month - 1 ||
      local.getUTCDate() !== day || hour > 23 || minute > 59) return null;
  return local.getTime() - JST;
}

export function parseReset(text, capturedAt, kind) {
  // The collector explicitly sets Asia/Tokyo. Never let the host timezone interpret this text.
  const now = Date.parse(capturedAt);
  const local = new Date(now + JST);
  const dateMatch = text.match(/(?:(\d{4})年\s*)?(\d{1,2})月\s*(\d{1,2})日/);
  const timeMatch = text.match(/(\d{1,2}):(\d{2})\s*(AM|PM)?/i);
  if (!Number.isFinite(now) || !timeMatch) return null;
  if (kind === 'weekly' && !dateMatch) return null;
  let hour = Number(timeMatch[1]);
  const minute = Number(timeMatch[2]);
  const meridiem = timeMatch[3]?.toUpperCase();
  if (meridiem) {
    if (hour < 1 || hour > 12) return null;
    hour = hour % 12 + (meridiem === 'PM' ? 12 : 0);
  }
  let year = dateMatch?.[1] ? Number(dateMatch[1]) : local.getUTCFullYear();
  const month = dateMatch ? Number(dateMatch[2]) : local.getUTCMonth() + 1;
  const day = dateMatch ? Number(dateMatch[3]) : local.getUTCDate();
  let target = validDate(year, month, day, hour, minute);
  if (target === null) return null;
  if (target < now) {
    if (!dateMatch) target += DAY;
    else if (!dateMatch[1]) target = validDate(++year, month, day, hour, minute);
  }
  const horizon = kind === 'session' ? 5 * HOUR + 60_000 : 7 * DAY + 60_000;
  if (target === null || target < now || target - now > horizon) return null;
  return new Date(target).toISOString();
}

function parseCard(lines, capturedAt, kind) {
  if (!lines?.length) return null;
  const values = lines.flatMap(line => Array.from(line.matchAll(/(?<![\d.,-])(\d+(?:[.,]\d+)?)\s*[%％]\s*(?:使用中|used)/gi), m => Number(m[1].replace(',', '.'))));
  if (values.length !== 1 || !Number.isFinite(values[0]) || values[0] < 0 || values[0] > 100) {
    throw new UsageError('unexpected_response');
  }
  const resetLines = lines.filter(line => /リセット|\bresets?\b/i.test(line));
  const resetText = resetLines.length === 1 ? resetLines[0] : null;
  const resetsAt = resetText ? parseReset(resetText, capturedAt, kind) : null;
  return {
    used_percent: values[0],
    remaining_percent: Math.round((100 - values[0]) * 100) / 100,
    resets_at: resetsAt,
    reset_text: resetText,
    reset_precision: resetsAt ? 'minute' : null,
    reset_basis: resetsAt ? 'visible_local_time_inferred_date' : null,
  };
}

export function parseUsage(observation) {
  if (observation.timezone !== 'Asia/Tokyo' || !Number.isFinite(Date.parse(observation.captured_at))) {
    throw new UsageError('unexpected_response');
  }
  const session = parseCard(observation.session_lines, observation.captured_at, 'session');
  const weekly = parseCard(observation.weekly_lines, observation.captured_at, 'weekly');
  if (!session && !weekly) throw new UsageError('unexpected_response');
  return {
    schema_version: 1,
    provider: 'gemini_web',
    source: 'rendered_usage_dom',
    status: 'ok',
    stale: false,
    captured_at: observation.captured_at,
    last_success_at: observation.captured_at,
    timezone: observation.timezone,
    session,
    weekly,
  };
}

export function failureSnapshot(code, previous, at = new Date().toISOString()) {
  const usable = previous?.schema_version === 1 && previous?.provider === 'gemini_web';
  return {
    schema_version: 1, provider: 'gemini_web', source: 'rendered_usage_dom',
    status: code, stale: true, captured_at: at,
    last_success_at: usable ? previous.last_success_at ?? null : null,
    timezone: 'Asia/Tokyo',
    session: usable ? previous.session ?? null : null,
    weekly: usable ? previous.weekly ?? null : null,
  };
}

export function accountSwitchSnapshot(at = new Date().toISOString()) {
  return {
    schema_version: 1,
    provider: 'gemini_web',
    source: 'rendered_usage_dom',
    status: 'account_switching',
    stale: true,
    captured_at: at,
    last_success_at: null,
    timezone: 'Asia/Tokyo',
    session: null,
    weekly: null,
  };
}
