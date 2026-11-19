// Pair with a running hub from its invite (the text inside the QR) and list models.
//   node examples/list-models.ts 'localhub://pair?v=2&u=…&fp=…&c=…'
import { HubClient, HubRequestError, MemorySessionStore, parseInvite } from '../src/index.ts';

const raw = process.argv[2];
if (!raw) {
  console.error('usage: node examples/list-models.ts <invite>');
  process.exit(2);
}
const client = new HubClient(new MemorySessionStore());
const session = await client.pair(parseInvite(raw), { deviceName: 'list-models example', app: 'example' });
console.log(`paired with ${session.hubName ?? session.address} as ${session.deviceID}; scopes: ${session.scopes.join(', ')}`);
for (const integration of await client.integrations()) {
  console.log(`integration ${integration.id.padEnd(9)} ${integration.state}${integration.detail ? ` — ${integration.detail}` : ''}`);
}
try {
  for (const model of await client.models()) console.log(`model    ${model.id}`);
} catch (error) {
  if (error instanceof HubRequestError) console.log(`models   ${error.status} ${error.code}: ${error.message}`);
  else throw error;
}
try {
  await client.chat({ model: 'ollama/llama3', messages: [{ role: 'user', content: 'hi' }] });
} catch (error) {
  if (error instanceof HubRequestError) console.log(`ollama   ${error.status} ${error.code}: ${error.message}`);
  else throw error;
}
await client.unpair();
console.log('unpaired');
