import { isIP } from 'node:net';
import makeMdns from 'multicast-dns';
import { normalizeFingerprint } from './invite.ts';

export interface DiscoveredHub {
  /** The hub's stable id (same as the invite's `id`). */
  id: string;
  name: string;
  /** Advertised certificate fingerprint. Only used to pick the right hub; the pin you stored is what you trust. */
  fingerprint: string;
  host: string;
  port: number;
}

const SERVICE = '_localhub._tcp.local';

function isPrivateIPv4(ip: string): boolean {
  const [a = 0, b = 0] = ip.split('.').map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a === 127;
}

/** Finds LocalHub instances on the local network via Bonjour (`_localhub._tcp`). */
export function discoverHubs(options: { timeoutMs?: number } = {}): Promise<DiscoveredHub[]> {
  const mdns = makeMdns();
  const instances = new Map<string, { txt: Record<string, string>; target?: string; port?: number }>();
  const addresses = new Map<string, string[]>();

  return new Promise((resolve) => {
    mdns.on('response', (response) => {
      for (const record of [...response.answers, ...(response.additionals ?? [])]) {
        if (record.type === 'PTR' && record.name === SERVICE && typeof record.data === 'string') {
          if (!instances.has(record.data)) {
            instances.set(record.data, { txt: {} });
            mdns.query([{ name: record.data, type: 'SRV' }, { name: record.data, type: 'TXT' }]);
          }
        } else if (record.type === 'SRV' && record.name.endsWith(SERVICE)) {
          const entry = instances.get(record.name) ?? { txt: {} };
          entry.target = record.data.target;
          entry.port = record.data.port;
          instances.set(record.name, entry);
          if (!addresses.has(record.data.target)) mdns.query([{ name: record.data.target, type: 'A' }]);
        } else if (record.type === 'TXT' && record.name.endsWith(SERVICE)) {
          const entry = instances.get(record.name) ?? { txt: {} };
          for (const item of (Array.isArray(record.data) ? record.data : [record.data]) as (Buffer | string)[]) {
            const text = item.toString();
            const split = text.indexOf('=');
            if (split > 0) entry.txt[text.slice(0, split)] = text.slice(split + 1);
          }
          instances.set(record.name, entry);
        } else if (record.type === 'A' && typeof record.data === 'string') {
          addresses.set(record.name, [...(addresses.get(record.name) ?? []), record.data]);
        }
      }
    });
    mdns.query([{ name: SERVICE, type: 'PTR' }]);
    setTimeout(() => {
      mdns.destroy();
      const hubs: DiscoveredHub[] = [];
      for (const [instance, entry] of instances) {
        const ips = (entry.target ? addresses.get(entry.target) : undefined) ?? [];
        const host = ips.find(isPrivateIPv4) ?? ips[0];
        if (!host || !entry.port || entry.txt.v !== '2' || !entry.txt.id || isIP(host) === 0) continue;
        let fingerprint: string;
        try {
          fingerprint = normalizeFingerprint(entry.txt.fp ?? '');
        } catch {
          continue;
        }
        hubs.push({ id: entry.txt.id, name: entry.txt.n ?? instance.replace(`.${SERVICE}`, ''), fingerprint, host, port: entry.port });
      }
      resolve(hubs);
    }, options.timeoutMs ?? 2000);
  });
}
