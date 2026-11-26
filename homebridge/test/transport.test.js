'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createHash, X509Certificate } = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { parse, request, magicPacket } = require('../transport');

const valid = {
  host: '192.168.1.20',
  broadcast: '192.168.1.255',
  mac: 'A8-5E-45-01-02-03',
  fingerprint: 'ab'.repeat(32),
  powerToken: 'F8'.repeat(32),
};

test('parse normalises a config exported by Prilo', () => {
  const connection = parse(valid);
  assert.equal(connection.host, '192.168.1.20');
  assert.deepEqual([...connection.mac], [0xa8, 0x5e, 0x45, 0x01, 0x02, 0x03]);
  assert.equal(connection.fingerprint.length, 32);
  assert.equal(connection.token, 'f8'.repeat(32));
});

test('parse rejects unusable configs', () => {
  const broken = {
    'hostname instead of IPv4': { host: 'gaming-pc.local' },
    'IPv6 broadcast': { broadcast: 'ff02::1' },
    'short fingerprint': { fingerprint: 'ab'.repeat(31) },
    'input token instead of power token': { powerToken: '00112233445566778899aabbccddeeff' },
    'missing power token': { powerToken: undefined },
    'five-byte MAC': { mac: 'a8:5e:45:01:02' },
    'multicast MAC': { mac: '01:00:5e:00:00:01' },
    'zero MAC': { mac: '00:00:00:00:00:00' },
  };
  for (const [name, change] of Object.entries(broken)) {
    assert.throws(() => parse({ ...valid, ...change }), Error, name);
  }
});

test('magic packet is 6 x FF then the MAC 16 times', () => {
  const mac = Buffer.from('a85e45010203', 'hex');
  const packet = magicPacket(mac);
  assert.equal(packet.length, 102);
  assert.ok(packet.subarray(0, 6).every(byte => byte === 0xff));
  for (let i = 0; i < 16; i++) {
    assert.deepEqual(packet.subarray(6 + i * 6, 12 + i * 6), mac);
  }
});

function selfSignedCertificate(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prilo-hb-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const key = path.join(dir, 'key.pem');
  const cert = path.join(dir, 'cert.pem');
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-nodes', '-days', '1', '-subj', '/CN=prilo-test', '-keyout', key, '-out', cert], { stdio: 'ignore' });
  } catch {
    return null;
  }
  const pem = fs.readFileSync(cert);
  const fingerprint = createHash('sha256').update(new X509Certificate(pem).raw).digest('hex');
  return { key: fs.readFileSync(key), cert: pem, fingerprint };
}

// request() always dials port 43821, like the real receiver.
async function receiver(t, credentials) {
  const seen = [];
  const server = https.createServer({ key: credentials.key, cert: credentials.cert }, (req, res) => {
    seen.push({ method: req.method, url: req.url, authorization: req.headers.authorization });
    res.statusCode = req.url === '/power/lock' ? 202 : 204;
    res.end();
  });
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(43821, '127.0.0.1', resolve);
    });
  } catch (error) {
    if (error.code === 'EADDRINUSE') return null;
    throw error;
  }
  t.after(() => server.close());
  return seen;
}

test('request talks to a receiver with the pinned certificate', async t => {
  const credentials = selfSignedCertificate(t);
  if (!credentials) return t.skip('openssl is not available');
  const seen = await receiver(t, credentials);
  if (!seen) return t.skip('port 43821 is in use (is a receiver running?)');
  const connection = parse({ ...valid, host: '127.0.0.1', fingerprint: credentials.fingerprint });

  assert.equal(await request(connection, false), 204);
  assert.equal(await request(connection, true), 202);
  assert.deepEqual(seen, [
    { method: 'GET', url: '/power/status', authorization: `Bearer ${connection.token}` },
    { method: 'POST', url: '/power/lock', authorization: `Bearer ${connection.token}` },
  ]);
});

test('request never sends the token to a certificate that does not match', async t => {
  const credentials = selfSignedCertificate(t);
  if (!credentials) return t.skip('openssl is not available');
  const seen = await receiver(t, credentials);
  if (!seen) return t.skip('port 43821 is in use (is a receiver running?)');
  const connection = parse({ ...valid, host: '127.0.0.1', fingerprint: 'ab'.repeat(32) });

  await assert.rejects(request(connection, true), { code: 'PRILO_PIN' });
  assert.deepEqual(seen, [], 'the impostor must not receive any HTTP request');
});
