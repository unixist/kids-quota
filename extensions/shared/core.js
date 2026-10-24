// Browser adapters report state. The native service alone owns elapsed time.
export const HOST_NAME = 'com.kidsquota.bridge';
export const STALE_AFTER_MS = 15000;
export const MAX_DOMAINS = 1000;

export function normalizeHostname(input) {
  if (typeof input !== 'string' || input.length > 4096) return null;
  try {
    const raw = input.trim();
    if (!raw) return null;
    const url = new URL(raw.includes('://') ? raw : `https://${raw}`);
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    const host = url.hostname.toLowerCase().replace(/\.$/, '');
    if (host.length > 253 || !host.includes('.') || /^[\d.]+$/.test(host) || host.includes(':')) return null;
    if (!host.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return null;
    return host;
  } catch { return null; }
}

export function hostnameFromURL(input) {
  if (typeof input !== 'string' || !/^https?:\/\//i.test(input)) return null;
  return normalizeHostname(input);
}

export function matchesDomain(host, domain) {
  const normalized = normalizeHostname(host);
  return normalized !== null && (normalized === domain.hostname ||
    (domain.includeSubdomains && normalized.endsWith(`.${domain.hostname}`)));
}

export function matchingRule(urlOrHost, rules) {
  const host = normalizeHostname(urlOrHost);
  if (!host) return null;
  return rules.find(rule => rule.domains.some(domain => matchesDomain(host, domain))) || null;
}

export function normalizePolicy(message) {
  if (!message || message.type !== 'policy' || !Number.isSafeInteger(message.revision) || message.revision < 0 ||
      typeof message.configured !== 'boolean' || !Array.isArray(message.rules) || message.rules.length > 500) return null;
  if (message.error) return null; // Temporary errors must not clear known restrictions.
  if (message.requestSequence !== undefined && (!Number.isSafeInteger(message.requestSequence) || message.requestSequence < 0)) return null;
  const rules = [], ids = new Set();
  let domainCount = 0;
  for (const rule of message.rules) {
    if (!rule || typeof rule.serviceId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(rule.serviceId) || ids.has(rule.serviceId) ||
        !Array.isArray(rule.domains) || typeof rule.blocked !== 'boolean' || typeof rule.remainingSeconds !== 'number' ||
        !Number.isFinite(rule.remainingSeconds) || rule.remainingSeconds < 0 || typeof rule.resetAt !== 'string' ||
        !Number.isFinite(Date.parse(rule.resetAt))) return null;
    const domains = [];
    for (const domain of rule.domains) {
      if (!domain || typeof domain.hostname !== 'string' || typeof domain.includeSubdomains !== 'boolean') return null;
      const canonical = normalizeHostname(domain.hostname);
      // The service must send hostnames, not URLs or suffix-match expressions.
      if (!canonical || canonical !== domain.hostname || domain.hostname.includes('/') || domain.hostname.includes('@')) return null;
      if (++domainCount > MAX_DOMAINS) return null;
      domains.push({hostname: canonical, includeSubdomains: domain.includeSubdomains});
    }
    ids.add(rule.serviceId);
    rules.push({serviceId: rule.serviceId, name: typeof rule.name === 'string' ? rule.name.slice(0,100) : rule.serviceId,
      domains, blocked: rule.blocked || rule.remainingSeconds === 0,
      remainingSeconds: rule.remainingSeconds, resetAt: new Date(rule.resetAt).toISOString()});
  }
  return {type:'policy', revision:message.revision, requestSequence:message.requestSequence,
    configured:message.configured, coverage:message.coverage === 'complete' ? 'complete' : 'incomplete', rules};
}

export class PolicyState {
  constructor({staleAfterMs = STALE_AFTER_MS} = {}) {
    this.policy = null;
    this.lastContact = null;
    this.lastSequence = -1;
    this.staleAfterMs = staleAfterMs;
  }
  restore(saved) {
    const policy = normalizePolicy(saved?.policy);
    if (!policy) return false;
    this.policy = policy;
    // A new worker/session starts disconnected. Revalidate before trusting allows.
    this.lastContact = null;
    this.lastSequence = -1;
    return true;
  }
  accept(message, now) {
    const policy = normalizePolicy(message);
    if (!policy || !Number.isFinite(now)) return false;
    if (this.policy && policy.revision < this.policy.revision) return false;
    if (policy.requestSequence !== undefined && policy.requestSequence < this.lastSequence) return false;
    if (this.policy && policy.revision === this.policy.revision) {
      for (const rule of policy.rules) {
        const previous = this.policy.rules.find(item => item.serviceId === rule.serviceId);
        if (previous && Date.parse(rule.resetAt) < Date.parse(previous.resetAt)) return false;
      }
    }
    this.policy = policy;
    this.lastContact = now;
    if (policy.requestSequence !== undefined) this.lastSequence = policy.requestSequence;
    return true;
  }
  isStale(now) {
    return this.lastContact === null || now < this.lastContact || now - this.lastContact >= this.staleAfterMs;
  }
  rules(now) {
    const stale = this.isStale(now);
    return (this.policy?.rules || []).map(rule => ({...rule, blocked:rule.blocked || stale,
      reason: stale ? 'unavailable' : rule.blocked ? 'exhausted' : 'available'}));
  }
  snapshot(now, enforcementError = null) {
    return {configured:this.policy?.configured || false, connected:!this.isStale(now),
      revision:this.policy?.revision ?? 0, coverage:enforcementError ? 'incomplete' : this.policy?.coverage || 'incomplete',
      enforcementError, rules:this.rules(now)};
  }
}

export function makeBrowserState({browser, sessionId, sequence, window, tab}) {
  const focused = Boolean(window?.focused && tab?.active && tab.windowId === window.id);
  const hostname = focused ? hostnameFromURL(tab?.url) : null;
  return {type:'browserState', browser, sessionId, sequence, hostname,
    focused:focused && hostname !== null, tabId:Number.isInteger(tab?.id) ? tab.id : null};
}

export function makeBlockingRules(rules, blockedPageURL) {
  const output = [];
  let id = 1;
  for (const rule of rules) {
    if (!rule.blocked) continue;
    for (const domain of rule.domains) {
      const host = domain.hostname.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      output.push({id:id++, priority:1,
        action:{type:'redirect', redirect:{url:`${blockedPageURL}?service=${encodeURIComponent(rule.serviceId)}`}},
        condition:{regexFilter:`^https?://(?:[^/@]+@)?${domain.includeSubdomains ? '(?:[^./@]+\\.)*' : ''}${host}\\.?(?::[0-9]+)?(?:[/?#]|$)`,
          isUrlFilterCaseSensitive:false, resourceTypes:['main_frame','sub_frame']}});
    }
  }
  return output;
}

export function describeSeconds(seconds) {
  const minutes = Math.max(0, Math.ceil(seconds / 60));
  return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} min` : `${minutes} min`;
}
