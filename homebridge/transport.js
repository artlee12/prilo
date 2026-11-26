'use strict';

const { createHash, timingSafeEqual } = require('node:crypto');
const dgram = require('node:dgram');
const https = require('node:https');
const { isIPv4 } = require('node:net');
const tls = require('node:tls');

const port = 43821;
const timeout = 2500;
const offlineCodes = new Set(['EHOSTUNREACH', 'EHOSTDOWN', 'ENETUNREACH', 'ECONNREFUSED', 'ETIMEDOUT']);

function parse(config) {
  if (!isIPv4(config.host) || !isIPv4(config.broadcast)) {
    throw new Error('Prilo PC requires IPv4 addresses for host and broadcast');
  }
  if (!/^[a-f0-9]{64}$/i.test(config.fingerprint ?? '') || !/^[a-f0-9]{64}$/i.test(config.powerToken ?? '')) {
    throw new Error('Prilo PC requires the fingerprint and scoped power token exported by Prilo');
  }
  const address = (config.mac ?? '').replace(/[:-]/g, '');
  if (!/^[a-f0-9]{12}$/i.test(address)) {
    throw new Error('Prilo PC requires a six-byte MAC address');
  }
  const mac = Buffer.from(address, 'hex');
  if ((mac[0] & 1) || mac.every(byte => byte === 0)) {
    throw new Error('Prilo PC requires a unicast MAC address');
  }
  return {
    host: config.host,
    broadcast: config.broadcast,
    mac,
    fingerprint: Buffer.from(config.fingerprint, 'hex'),
    token: config.powerToken.toLowerCase(),
  };
}

function pinnedAgent(connection) {
  const agent = new https.Agent({ keepAlive: false });
  // Hold the socket until the peer is pinned. The bearer request is written only after this callback.
  agent.createConnection = (_options, callback) => {
    const socket = tls.connect({ host: connection.host, port, rejectUnauthorized: false, minVersion: 'TLSv1.2' });
    const deadline = setTimeout(() => {
      const error = Object.assign(new Error('Prilo TLS connection timed out'), { code: 'ETIMEDOUT' });
      socket.destroy(error);
    }, timeout);
    const failed = error => {
      clearTimeout(deadline);
      callback(error);
    };
    socket.once('error', failed);
    socket.once('secureConnect', () => {
      const cert = socket.getPeerCertificate();
      const digest = cert.raw && createHash('sha256').update(cert.raw).digest();
      if (!digest || !timingSafeEqual(digest, connection.fingerprint)) {
        const error = Object.assign(new Error('Prilo PC certificate does not match'), { code: 'PRILO_PIN' });
        socket.destroy(error);
        return;
      }
      clearTimeout(deadline);
      socket.removeListener('error', failed);
      callback(null, socket);
    });
  };
  return agent;
}

function request(connection, lock) {
  return new Promise((resolve, reject) => {
    const agent = pinnedAgent(connection);
    const complete = (error, status) => {
      agent.destroy();
      if (error) reject(error);
      else resolve(status);
    };
    const req = https.request({
      host: connection.host,
      port,
      path: lock ? '/power/lock' : '/power/status',
      method: lock ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${connection.token}` },
      agent,
    }, res => {
      res.resume();
      res.once('end', () => complete(null, res.statusCode));
      res.once('error', complete);
    });
    req.setTimeout(timeout, () => {
      req.destroy(Object.assign(new Error('Prilo HTTP request timed out'), { code: 'ETIMEDOUT' }));
    });
    req.once('error', complete);
    req.end();
  });
}

function magicPacket(mac) {
  return Buffer.concat([Buffer.alloc(6, 0xff), ...Array(16).fill(mac)]);
}

function wake(connection) {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4');
    let completed = false;
    const finish = error => {
      if (completed) return;
      completed = true;
      socket.close();
      if (error) reject(error);
      else resolve();
    };
    socket.once('error', finish);
    socket.bind(0, () => {
      try {
        socket.setBroadcast(true);
        socket.send(magicPacket(connection.mac), 9, connection.broadcast, finish);
      } catch (error) {
        finish(error);
      }
    });
  });
}

module.exports = { parse, request, magicPacket, wake, offlineCodes };
