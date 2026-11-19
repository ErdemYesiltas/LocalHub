export interface HubInvite {
  /** `https://host:port`, no path. */
  address: URL;
  /** Lowercase SHA-256 hex of the hub's DER certificate. */
  fingerprint: string;
  /** One-time six-digit pairing code. */
  code: string;
  version: 1 | 2;
  hubID?: string;
  hubName?: string;
}

export class InviteError extends Error {
  override name = 'InviteError';
}

export function normalizeFingerprint(value: string): string {
  const normalized = value.replace(/[:\s]/g, '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(normalized)) throw new InviteError('Expected a SHA-256 certificate fingerprint');
  return normalized;
}

export function hubAddress(value: string): URL {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new InviteError('Enter an HTTPS hub address');
  }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.search || url.hash ||
      (url.pathname !== '/' && url.pathname !== '')) {
    throw new InviteError('Enter an HTTPS hub address without a path or credentials');
  }
  return new URL(url.origin);
}

/**
 * Parses what the hub's QR carries. Scanning grants no more trust than typing
 * the same three values; the fingerprint is the only trust anchor.
 *
 * v2: `localhub://pair?v=2&u=<https url>&fp=<sha256>&c=<6 digits>&id=<hub id>&n=<name>`
 * v1: `artblend-companion://pair?v=1&u=…&fp=…&c=…` (ArtBlend Companion)
 */
export function parseInvite(raw: string): HubInvite {
  const text = raw.trim();
  if (text.length > 1024) throw new InviteError('Not a LocalHub pairing code');
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw new InviteError('Not a LocalHub pairing code');
  }
  const scheme = url.protocol.slice(0, -1);
  if ((scheme !== 'localhub' && scheme !== 'artblend-companion') || url.host !== 'pair' ||
      (url.pathname !== '' && url.pathname !== '/') || url.username || url.password || url.hash) {
    throw new InviteError('Not a LocalHub pairing code');
  }
  const single = (key: string, required = true): string | undefined => {
    const values = url.searchParams.getAll(key);
    if (values.length > 1 || (required && values.length === 0)) throw new InviteError('Incomplete pairing code');
    return values[0];
  };
  const version = single('v');
  if (!((scheme === 'localhub' && version === '2') || (scheme === 'artblend-companion' && version === '1'))) {
    throw new InviteError('Unsupported pairing code version');
  }
  const code = single('c')!;
  if (!/^\d{6}$/.test(code)) throw new InviteError('Invalid pairing code in QR');
  const invite: HubInvite = {
    address: hubAddress(single('u')!),
    fingerprint: normalizeFingerprint(single('fp')!),
    code,
    version: version === '2' ? 2 : 1,
  };
  if (invite.version === 2) {
    const id = single('id', false);
    const name = single('n', false);
    if (id !== undefined && /^[a-z0-9-]{1,64}$/.test(id)) invite.hubID = id;
    if (name !== undefined) invite.hubName = name.slice(0, 40);
  }
  return invite;
}
