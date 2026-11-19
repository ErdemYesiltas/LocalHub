import assert from 'node:assert/strict';
import { test } from 'node:test';
import { InviteError, parseInvite } from '../src/index.ts';

const fp = 'ab'.repeat(32);

test('parses a v2 invite with hub identity', () => {
  const invite = parseInvite(
    `localhub://pair?v=2&u=https%3A%2F%2F192.168.1.20%3A8790&fp=${fp}&c=012345&id=4f1c-aa&n=Studio%20Mac%20%26%20Co`);
  assert.equal(invite.version, 2);
  assert.equal(invite.address.href, 'https://192.168.1.20:8790/');
  assert.equal(invite.fingerprint, fp);
  assert.equal(invite.code, '012345');
  assert.equal(invite.hubID, '4f1c-aa');
  assert.equal(invite.hubName, 'Studio Mac & Co');
});

test('accepts the ArtBlend Companion v1 invite and colon fingerprints', () => {
  const colon = fp.match(/../g)!.join(':').toUpperCase();
  const invite = parseInvite(`artblend-companion://pair?v=1&u=https%3A%2F%2F10.0.0.2%3A8765&fp=${colon}&c=999999`);
  assert.equal(invite.version, 1);
  assert.equal(invite.fingerprint, fp);
  assert.equal(invite.hubID, undefined);
});

test('rejects anything that is not a well-formed invite', () => {
  const bad = [
    'https://evil.example/pair?v=2',
    `localhub://pair?v=1&u=https%3A%2F%2Fa%3A1&fp=${fp}&c=123456`,
    `artblend-companion://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${fp}&c=123456`,
    `localhub://pair?v=2&u=http%3A%2F%2Fa%3A1&fp=${fp}&c=123456`,
    `localhub://pair?v=2&u=https%3A%2F%2Fa%3A1%2Fpath&fp=${fp}&c=123456`,
    `localhub://pair?v=2&u=https%3A%2F%2Fuser%40a%3A1&fp=${fp}&c=123456`,
    `localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=abcd&c=123456`,
    `localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${fp}&c=12345`,
    `localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${fp}&c=123456&c=654321`,
    `localhub://other?v=2&u=https%3A%2F%2Fa%3A1&fp=${fp}&c=123456`,
    'x'.repeat(2000),
  ];
  for (const raw of bad) assert.throws(() => parseInvite(raw), InviteError, raw);
});
