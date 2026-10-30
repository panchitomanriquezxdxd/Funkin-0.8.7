'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('net');
const { createRelayServer, PROTOCOL_VERSION, MAX_LINE_BYTES, CODE_ALPHABET } = require('../server.js');

/** A tiny test client that collects parsed JSON lines and lets you await the next one. */
function connect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    socket.setEncoding('utf8');
    const inbox = [];
    const waiters = [];
    let buffer = '';
    let closed = false;

    socket.on('data', (chunk) => {
      buffer += chunk;
      let i;
      while ((i = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, i);
        buffer = buffer.slice(i + 1);
        const msg = JSON.parse(line);
        const waiter = waiters.shift();
        if (waiter) waiter(msg);
        else inbox.push(msg);
      }
    });
    socket.on('close', () => {
      closed = true;
    });
    socket.on('error', () => {});

    const client = {
      socket,
      send: (msg) => socket.write(JSON.stringify(msg) + '\n'),
      sendRaw: (text) => socket.write(text),
      next: (timeoutMs = 1000) =>
        new Promise((res, rej) => {
          if (inbox.length > 0) return res(inbox.shift());
          const timer = setTimeout(() => rej(new Error('timed out waiting for a message')), timeoutMs);
          waiters.push((m) => {
            clearTimeout(timer);
            res(m);
          });
        }),
      expectSilence: (ms = 150) => new Promise((res, rej) => setTimeout(() => (inbox.length ? rej(new Error('unexpected: ' + JSON.stringify(inbox[0]))) : res()), ms)),
      isClosed: () => closed,
      close: () => socket.destroy(),
    };
    socket.on('connect', () => resolve(client));
    socket.on('error', reject);
  });
}

async function withServer(fn, options) {
  const relay = createRelayServer(options);
  await new Promise((res) => relay.server.listen(0, '127.0.0.1', res));
  const port = relay.server.address().port;
  try {
    await fn(port, relay);
  } finally {
    await relay.close();
  }
}

async function makeRoom(port) {
  const host = await connect(port);
  host.send({ t: 'create', v: PROTOCOL_VERSION, name: 'Host', char: 'bf' });
  const created = await host.next();
  const guest = await connect(port);
  guest.send({ t: 'join', v: PROTOCOL_VERSION, code: created.code, name: 'Guest', char: 'pico' });
  const joined = await guest.next();
  const peerJoined = await host.next();
  return { host, guest, created, joined, peerJoined };
}

test('create returns a well formed room code', () =>
  withServer(async (port) => {
    const host = await connect(port);
    host.send({ t: 'create', v: PROTOCOL_VERSION, name: 'Host', char: 'bf' });
    const created = await host.next();
    assert.equal(created.t, 'created');
    assert.equal(created.you, 0);
    assert.match(created.code, new RegExp(`^[${CODE_ALPHABET}]{5}$`));
    host.close();
  }));

test('join exchanges the profiles of both players', () =>
  withServer(async (port) => {
    const { host, guest, created, joined, peerJoined } = await makeRoom(port);
    assert.equal(joined.t, 'joined');
    assert.equal(joined.code, created.code);
    assert.equal(joined.you, 1);
    assert.deepEqual(joined.peer, { name: 'Host', char: 'bf' });
    assert.equal(peerJoined.t, 'peer_joined');
    assert.deepEqual(peerJoined.peer, { name: 'Guest', char: 'pico' });
    host.close();
    guest.close();
  }));

test('room codes are case and punctuation insensitive', () =>
  withServer(async (port) => {
    const host = await connect(port);
    host.send({ t: 'create', v: PROTOCOL_VERSION });
    const { code } = await host.next();
    const guest = await connect(port);
    guest.send({ t: 'join', v: PROTOCOL_VERSION, code: ` ${code.toLowerCase().slice(0, 2)}-${code.slice(2)} ` });
    assert.equal((await guest.next()).t, 'joined');
    host.close();
    guest.close();
  }));

test('unknown room and full room are rejected', () =>
  withServer(async (port) => {
    const lost = await connect(port);
    lost.send({ t: 'join', v: PROTOCOL_VERSION, code: 'ZZZZZ' });
    assert.equal((await lost.next()).code, 'room_not_found');

    const { host, guest, created } = await makeRoom(port);
    const third = await connect(port);
    third.send({ t: 'join', v: PROTOCOL_VERSION, code: created.code });
    assert.equal((await third.next()).code, 'room_full');
    for (const c of [lost, host, guest, third]) c.close();
  }));

test('a wrong protocol version is rejected', () =>
  withServer(async (port) => {
    const c = await connect(port);
    c.send({ t: 'create', v: PROTOCOL_VERSION + 1 });
    assert.equal((await c.next()).code, 'bad_version');
    c.close();
  }));

test('gameplay messages are relayed to the other player only, and stamped with the sender', () =>
  withServer(async (port) => {
    const { host, guest } = await makeRoom(port);
    host.send({ t: 'hit', time: 1234.5, dir: 2, from: 1 /* spoofing attempt */ });
    const got = await guest.next();
    assert.deepEqual(got, { t: 'hit', time: 1234.5, dir: 2, from: 0 });
    await host.expectSilence(); // not echoed back
    guest.send({ t: 'press', dir: 3, time: 99 });
    assert.deepEqual(await host.next(), { t: 'press', dir: 3, time: 99, from: 1 });
    host.close();
    guest.close();
  }));

test('profile changes are sanitized and relayed', () =>
  withServer(async (port) => {
    const { host, guest } = await makeRoom(port);
    guest.send({ t: 'profile', name: '  Ev\u0000il\nName that is far too long for the limit  ', char: 'dad' });
    const got = await host.next();
    assert.equal(got.t, 'profile');
    assert.equal(got.char, 'dad');
    assert.ok(got.name.length <= 20);
    assert.ok(!/[\u0000-\u001f]/.test(got.name));
    host.close();
    guest.close();
  }));

test('types outside the whitelist are rejected, not relayed', () =>
  withServer(async (port) => {
    const { host, guest } = await makeRoom(port);
    host.send({ t: 'rm -rf', payload: 1 });
    assert.equal((await host.next()).code, 'bad_request');
    await guest.expectSilence();
    host.close();
    guest.close();
  }));

test('relaying without a room is an error', () =>
  withServer(async (port) => {
    const c = await connect(port);
    c.send({ t: 'hit', time: 1 });
    assert.equal((await c.next()).code, 'not_in_room');
    c.close();
  }));

test('garbage input gets an error and the connection survives', () =>
  withServer(async (port) => {
    const c = await connect(port);
    c.sendRaw('this is not json\n');
    assert.equal((await c.next()).code, 'bad_request');
    c.sendRaw('[1,2,3]\n');
    assert.equal((await c.next()).code, 'bad_request');
    c.send({ t: 'ping', n: 7 });
    assert.deepEqual(await c.next(), { t: 'pong', n: 7 });
    c.close();
  }));

test('an oversized message disconnects the client', () =>
  withServer(async (port) => {
    const c = await connect(port);
    c.sendRaw('x'.repeat(MAX_LINE_BYTES + 10));
    assert.equal((await c.next()).code, 'too_large');
    await new Promise((r) => setTimeout(r, 100));
    assert.ok(c.isClosed());
  }));

test('when the host leaves, the guest becomes host and is told', () =>
  withServer(async (port, relay) => {
    const { host, guest, created } = await makeRoom(port);
    host.close();
    const left = await guest.next();
    assert.deepEqual(left, { t: 'peer_left', you: 0 });
    assert.equal(relay.rooms.get(created.code).players.length, 1);

    // The room is reusable: someone new can join the new host.
    const newcomer = await connect(port);
    newcomer.send({ t: 'join', v: PROTOCOL_VERSION, code: created.code, name: 'New' });
    assert.equal((await newcomer.next()).t, 'joined');
    guest.close();
    newcomer.close();
  }));

test('empty rooms are deleted', () =>
  withServer(async (port, relay) => {
    const { host, guest, created } = await makeRoom(port);
    host.close();
    await guest.next();
    guest.close();
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(relay.rooms.has(created.code), false);
  }));

test('an explicit leave frees the slot', () =>
  withServer(async (port) => {
    const { host, guest, created } = await makeRoom(port);
    guest.send({ t: 'leave' });
    assert.deepEqual(await guest.next(), { t: 'left' });
    assert.equal((await host.next()).t, 'peer_left');
    guest.send({ t: 'join', v: PROTOCOL_VERSION, code: created.code });
    assert.equal((await guest.next()).t, 'joined');
    host.close();
    guest.close();
  }));

test('idle connections are dropped', () =>
  withServer(
    async (port) => {
      const c = await connect(port);
      await new Promise((r) => setTimeout(r, 400));
      assert.ok(c.isClosed());
    },
    { idleTimeoutMs: 150 },
  ));

test('flooding is rate limited', () =>
  withServer(async (port) => {
    const c = await connect(port);
    let burst = '';
    for (let i = 0; i < 450; i++) burst += JSON.stringify({ t: 'ping', n: i }) + '\n';
    c.sendRaw(burst);
    let pongs = 0;
    let limited = false;
    for (let i = 0; i < 401; i++) {
      const m = await c.next();
      if (m.t === 'pong') pongs++;
      if (m.t === 'error' && m.code === 'rate_limited') limited = true;
    }
    assert.ok(limited, 'expected a rate_limited warning');
    assert.ok(pongs <= 400);
    c.close();
  }));
