'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('net');
const crypto = require('crypto');
const { createRelayServer, PROTOCOL_VERSION } = require('../server.js');
const ws = require('../websocket.js');

async function withServer(fn) {
  const relay = createRelayServer();
  await new Promise((res) => relay.server.listen(0, '127.0.0.1', res));
  try {
    await fn(relay.server.address().port, relay);
  } finally {
    await relay.close();
  }
}

/** Build a masked client frame, like a real WebSocket client sends. */
function clientFrame(opcode, payload, { mask = true, fin = true } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  let header;
  const maskBit = mask ? 0x80 : 0;
  if (data.length < 126) header = Buffer.from([(fin ? 0x80 : 0) | opcode, maskBit | data.length]);
  else {
    header = Buffer.alloc(4);
    header[0] = (fin ? 0x80 : 0) | opcode;
    header[1] = maskBit | 126;
    header.writeUInt16BE(data.length, 2);
  }
  if (!mask) return Buffer.concat([header, data]);
  const key = crypto.randomBytes(4);
  const masked = Buffer.from(data.map((b, i) => b ^ key[i & 3]));
  return Buffer.concat([header, key, masked]);
}

/** A WebSocket test client: does the handshake, then gives back server messages. */
function wsConnect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    const key = crypto.randomBytes(16).toString('base64');
    let state = 'handshake';
    let raw = Buffer.alloc(0);
    const inbox = [];
    const waiters = [];
    let closeCode = null;
    let closed = false;

    socket.on('connect', () => {
      socket.write(
        'GET /relay HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
          `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`
      );
    });
    socket.on('error', () => {});
    socket.on('close', () => {
      closed = true;
    });
    socket.on('data', (chunk) => {
      raw = Buffer.concat([raw, chunk]);
      if (state === 'handshake') {
        const end = raw.indexOf('\r\n\r\n');
        if (end === -1) return;
        const head = raw.subarray(0, end).toString();
        assert.match(head, /^HTTP\/1\.1 101/);
        assert.ok(head.includes(`Sec-WebSocket-Accept: ${ws.acceptKey(key)}`));
        raw = raw.subarray(end + 4);
        state = 'open';
        resolve(client);
      }
      // Server frames are unmasked.
      while (state === 'open' && raw.length >= 2) {
        let length = raw[1] & 0x7f;
        let offset = 2;
        if (length === 126) {
          if (raw.length < 4) break;
          length = raw.readUInt16BE(2);
          offset = 4;
        }
        if (raw.length < offset + length) break;
        const opcode = raw[0] & 0x0f;
        const payload = raw.subarray(offset, offset + length);
        raw = raw.subarray(offset + length);
        if (opcode === ws.OP_TEXT) {
          const msg = JSON.parse(payload.toString());
          const waiter = waiters.shift();
          if (waiter) waiter(msg);
          else inbox.push(msg);
        } else if (opcode === ws.OP_CLOSE) {
          closeCode = payload.readUInt16BE(0);
        } else if (opcode === ws.OP_PONG) {
          const pong = { pong: payload.toString() };
          const waiter = waiters.shift();
          if (waiter) waiter(pong);
          else inbox.push(pong);
        }
      }
    });

    const client = {
      socket,
      send: (msg) => socket.write(clientFrame(ws.OP_TEXT, JSON.stringify(msg))),
      sendFrame: (frame) => socket.write(frame),
      next: (timeoutMs = 1000) =>
        new Promise((res, rej) => {
          if (inbox.length > 0) return res(inbox.shift());
          const timer = setTimeout(() => rej(new Error('timed out')), timeoutMs);
          waiters.push((m) => {
            clearTimeout(timer);
            res(m);
          });
        }),
      closeCode: () => closeCode,
      isClosed: () => closed,
      close: () => socket.destroy(),
    };
    setTimeout(() => reject(new Error('handshake timed out')), 2000);
  });
}

function tcpConnect(port) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1');
    socket.setEncoding('utf8');
    const waiters = [];
    const inbox = [];
    let buffer = '';
    socket.on('data', (c) => {
      buffer += c;
      let i;
      while ((i = buffer.indexOf('\n')) !== -1) {
        const msg = JSON.parse(buffer.slice(0, i));
        buffer = buffer.slice(i + 1);
        const w = waiters.shift();
        if (w) w(msg);
        else inbox.push(msg);
      }
    });
    socket.on('error', () => {});
    socket.on('connect', () =>
      resolve({
        send: (m) => socket.write(JSON.stringify(m) + '\n'),
        next: () =>
          new Promise((res, rej) => {
            if (inbox.length) return res(inbox.shift());
            const t = setTimeout(() => rej(new Error('timed out')), 1000);
            waiters.push((m) => {
              clearTimeout(t);
              res(m);
            });
          }),
        close: () => socket.destroy(),
      })
    );
  });
}

test('accept key matches the RFC 6455 example', () => {
  assert.equal(ws.acceptKey('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
});

test('plain HTTP gets a status page (health check)', async () => {
  await withServer(async (port) => {
    const response = await new Promise((resolve) => {
      const socket = net.connect(port, '127.0.0.1');
      let data = '';
      socket.setEncoding('utf8');
      socket.on('connect', () => socket.write('GET / HTTP/1.1\r\nHost: x\r\n\r\n'));
      socket.on('data', (c) => (data += c));
      socket.on('close', () => resolve(data));
    });
    assert.match(response, /^HTTP\/1\.1 200 OK/);
    assert.match(response, /online relay/);
  });
});

test('a WebSocket client can create a room and a TCP client can join it', async () => {
  await withServer(async (port) => {
    const host = await wsConnect(port);
    host.send({ t: 'create', v: PROTOCOL_VERSION, name: 'Web', char: 'bf' });
    const created = await host.next();
    assert.equal(created.t, 'created');

    const guest = await tcpConnect(port);
    guest.send({ t: 'join', v: PROTOCOL_VERSION, code: created.code, name: 'Tcp', char: 'pico' });
    assert.equal((await guest.next()).t, 'joined');
    assert.equal((await host.next()).t, 'peer_joined');

    // Both directions relay.
    host.send({ t: 'press', d: 2, ms: 1234 });
    const pressed = await guest.next();
    assert.deepEqual([pressed.t, pressed.d, pressed.ms, pressed.from], ['press', 2, 1234, 0]);

    guest.send({ t: 'hit', d: 1, ms: 99, nt: 100, r: 'sick' });
    const hit = await host.next();
    assert.deepEqual([hit.t, hit.d, hit.from], ['hit', 1, 1]);

    host.close();
    guest.close();
  });
});

test('two WebSocket clients can play together, with a long message split into fragments', async () => {
  await withServer(async (port) => {
    const a = await wsConnect(port);
    a.send({ t: 'create', v: PROTOCOL_VERSION, name: 'A', char: 'bf' });
    const { code } = await a.next();
    const b = await wsConnect(port);
    b.send({ t: 'join', v: PROTOCOL_VERSION, code, name: 'B', char: 'bf' });
    await b.next();
    await a.next();

    // The same message sent as two fragments.
    const text = JSON.stringify({ t: 'chat', text: 'hello ' + 'x'.repeat(200) });
    const half = Math.floor(text.length / 2);
    a.sendFrame(clientFrame(ws.OP_TEXT, text.slice(0, half), { fin: false }));
    a.sendFrame(clientFrame(0x0, text.slice(half)));
    const chat = await b.next();
    assert.equal(chat.t, 'chat');
    assert.ok(chat.text.startsWith('hello '));

    a.close();
    b.close();
  });
});

test('pings are answered with the same payload', async () => {
  await withServer(async (port) => {
    const client = await wsConnect(port);
    client.sendFrame(clientFrame(ws.OP_PING, 'abc'));
    assert.deepEqual(await client.next(), { pong: 'abc' });
    client.close();
  });
});

test('unmasked frames, binary frames and oversized messages close the connection', async () => {
  await withServer(async (port) => {
    const unmasked = await wsConnect(port);
    unmasked.sendFrame(clientFrame(ws.OP_TEXT, '{}', { mask: false }));
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(unmasked.closeCode(), 1002);

    const binary = await wsConnect(port);
    binary.sendFrame(clientFrame(ws.OP_BINARY, Buffer.from([1, 2, 3])));
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(binary.closeCode(), 1003);

    const big = await wsConnect(port);
    big.sendFrame(clientFrame(ws.OP_TEXT, 'y'.repeat(5000)));
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(big.closeCode(), 1009);
  });
});

test('a WebSocket client leaving tells the other player', async () => {
  await withServer(async (port) => {
    const a = await wsConnect(port);
    a.send({ t: 'create', v: PROTOCOL_VERSION, name: 'A', char: 'bf' });
    const { code } = await a.next();
    const b = await tcpConnect(port);
    b.send({ t: 'join', v: PROTOCOL_VERSION, code, name: 'B', char: 'bf' });
    await b.next();
    await a.next();
    a.close();
    assert.equal((await b.next()).t, 'peer_left');
    b.close();
  });
});
