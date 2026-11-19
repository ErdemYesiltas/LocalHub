// Pair with a running hub and generate one image through its default "create images" workflow.
//   node examples/generate-image.ts '<invite>' 'a watercolor fox' out.png
import { writeFile } from 'node:fs/promises';
import { HubClient, HubRequestError, MemorySessionStore, parseInvite } from '../src/index.ts';

const [raw, prompt = 'a watercolor fox, soft light', out = 'localhub-image.png'] = process.argv.slice(2);
if (!raw) {
  console.error('usage: node examples/generate-image.ts <invite> [prompt] [out.png]');
  process.exit(2);
}
const client = new HubClient(new MemorySessionStore());
await client.pair(parseInvite(raw), { deviceName: 'generate-image example', app: 'example' });
const models = (await client.models()).filter((m) => m.capabilities.includes('image.create'));
console.log(`image workflows: ${models.map((m) => m.id).join(', ') || 'none'}`);
try {
  const job = await client.generateImage({ prompt, size: '512x512', steps: 10 }, { async: true });
  console.log(`job ${job.id} ${job.status}`);
  let last = '';
  for await (const update of client.jobEvents(job.id)) {
    const line = `${update.status}${update.progress !== undefined ? ` ${Math.round(update.progress * 100)}%` : ''}`;
    if (line !== last) console.log(`  ${line}${update.error ? ` — ${update.error}` : ''}`);
    last = line;
    if (update.status === 'completed') {
      const data = await client.fileContent(update.output_file_ids[0]!);
      await writeFile(out, data);
      console.log(`saved ${out} (${data.length} bytes, file ${update.output_file_ids[0]})`);
    }
  }
} catch (error) {
  if (error instanceof HubRequestError) console.log(`${error.status} ${error.code}: ${error.message}`);
  else throw error;
}
await client.unpair();
