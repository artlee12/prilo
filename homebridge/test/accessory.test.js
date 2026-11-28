'use strict';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

// Replace the network layer before index.js destructures it.
const transportPath = path.join(__dirname, '..', 'transport.js');
const stub = { status: 204, error: null, calls: [] };
const fail = code => Object.assign(new Error(code), { code });
require.cache[transportPath] = {
  id: transportPath, filename: transportPath, loaded: true,
  exports: {
    offlineCodes: new Set(['EHOSTUNREACH', 'ECONNREFUSED', 'ETIMEDOUT']),
    parse: config => ({ host: config.host }),
    request: async (_connection, lock) => {
      stub.calls.push(lock ? 'lock' : 'status');
      if (stub.error) throw stub.error;
      return stub.status;
    },
    wake: async () => {
      stub.calls.push('wake');
      if (stub.error) throw stub.error;
    },
  },
};

let PriloPC;
require('../index.js')({
  hap: {
    Service: { Switch: class { getCharacteristic() { return { onGet() { return this; }, onSet() { return this; } }; } } },
    Characteristic: { On: 'On' },
  },
  registerAccessory: (_name, constructor) => { PriloPC = constructor; },
});

const log = { warnings: [], warn(message) { this.warnings.push(message); } };
const accessory = () => new PriloPC(log, { name: 'PC', host: '192.168.1.20' });

beforeEach(() => {
  stub.status = 204;
  stub.error = null;
  stub.calls = [];
  log.warnings = [];
});

test('reachable receiver reports the PC as on', async () => {
  assert.equal(await accessory().isOn(), true);
});

test('unreachable receiver reports the PC as off', async () => {
  stub.error = fail('EHOSTUNREACH');
  assert.equal(await accessory().isOn(), false);
});

test('after wake the switch stays on while the PC boots', async () => {
  const pc = accessory();
  await pc.setOn(true);
  assert.deepEqual(stub.calls, ['wake']);
  stub.error = fail('ECONNREFUSED');
  assert.equal(await pc.isOn(), true);
  pc.wakingUntil = Date.now() - 1;
  assert.equal(await pc.isOn(), false, 'the boot window must expire');
});

test('unexpected status or error is surfaced to HomeKit', async () => {
  stub.status = 401;
  await assert.rejects(accessory().isOn(), /HTTP 401/);
  stub.status = 204;
  stub.error = fail('PRILO_PIN');
  await assert.rejects(accessory().isOn(), { code: 'PRILO_PIN' });
  assert.equal(log.warnings.length, 2);
});

test('turning off requests a lock and requires 202', async () => {
  const pc = accessory();
  pc.wakingUntil = Date.now() + 45000;
  stub.status = 202;
  await pc.setOn(false);
  assert.deepEqual(stub.calls, ['lock']);
  assert.equal(pc.wakingUntil, 0);
  stub.status = 204;
  await assert.rejects(pc.setOn(false), /HTTP 204/);
});
