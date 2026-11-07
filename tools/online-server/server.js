'use strict';

/**
 * Relay server for the Funkin' online mode.
 *
 * Two players connect to this server over TCP, one creates a room (and gets a short room code),
 * the other joins with that code. After that the server just forwards a whitelist of messages between the two.
 * It never interprets gameplay data, so it needs no updates when the game changes.
 *
 * Two ways to connect, on the same port:
 *  - plain TCP: one JSON object per line ("\n" terminated, UTF-8);
 *  - WebSocket (`ws://` / `wss://` behind a proxy): one JSON object per text message.
 * Plain HTTP requests get a short status page, which is what hosting services use as a health check.
 * See README.md.
 *
 * Run:  node server.js [port]        (default port 7777, or $PORT)
 */

const net = require('net');
const { StringDecoder } = require('string_decoder');
const ws = require('./websocket');

const PROTOCOL_VERSION = 1;
const DEFAULT_PORT = 7777;
const MAX_LINE_BYTES = 4096; // a single message may not be bigger than this
const MAX_NAME_LENGTH = 20;
const MAX_ID_LENGTH = 48; // character ids
const CODE_LENGTH = 5;
// No 0/O/1/I so codes can be read out loud and typed on a phone without mistakes.
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const ROOM_SIZE = 2;
const IDLE_TIMEOUT_MS = 60 * 1000; // clients ping every ~15s, so a minute of silence means the connection is dead
const RATE_WINDOW_MS = 1000;
const RATE_SOFT_LIMIT = 400; // messages per window, extra ones are dropped
const RATE_HARD_LIMIT = 2000; // messages per window, the client is disconnected

/**
 * Message types that are forwarded to the other player. Everything else is rejected.
 * Keeping this a whitelist means a modified client can't use the relay for anything else.
 */
const RELAY_TYPES = new Set([
  'profile', // the player changed name / character
  'ready', // lobby ready toggle
  'start', // host starts the match (song, difficulty, ...)
  'press', // a key went down
  'release', // a key went up
  'hit', // a note was hit
  'miss', // a note was missed
  'score', // score / combo / health update
  'finish', // the song is over for this player
  'rtt', // latency probe...
  'rtt_ack', // ...and its answer
  'chat', // lobby text
]);

function randomCode() {
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return code;
}

function sanitizeText(value, maxLength, fallback) {
  if (typeof value !== 'string') return fallback;
  // Drop control characters, keep it single line.
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, maxLength);
  return cleaned.length > 0 ? cleaned : fallback;
}

function normalizeCode(value) {
  if (typeof value !== 'string') return '';
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

/**
 * Create (but don't start) the relay server.
 * @param {{log?: (msg: string) => void, idleTimeoutMs?: number}} [options]
 * @returns {{server: net.Server, rooms: Map<string, object>, close: () => Promise<void>}}
 */
function createRelayServer(options = {}) {
  const log = options.log || (() => {});
  const idleTimeoutMs = options.idleTimeoutMs || IDLE_TIMEOUT_MS;

  /** @type {Map<string, {code: string, players: Array<object>}>} */
  const rooms = new Map();

  function send(client, message) {
    if (client.socket.destroyed || !client.socket.writable) return;
    const text = JSON.stringify(message);
    client.socket.write(client.webSocket ? ws.encodeFrame(ws.OP_TEXT, text) : text + '\n');
  }

  function sendError(client, code, msg) {
    send(client, { t: 'error', code, msg });
  }

  function uniqueRoomCode() {
    for (let attempt = 0; attempt < 50; attempt++) {
      const code = randomCode();
      if (!rooms.has(code)) return code;
    }
    return null;
  }

  function profileOf(client) {
    return { name: client.name, char: client.char };
  }

  function leaveRoom(client) {
    const room = client.room;
    if (!room) return;
    client.room = null;

    room.players = room.players.filter((p) => p !== client);
    if (room.players.length === 0) {
      rooms.delete(room.code);
      log(`room ${room.code} closed`);
      return;
    }

    // The remaining player becomes the host (slot 0) so the room stays usable.
    room.players.forEach((p, index) => {
      p.slot = index;
    });
    for (const other of room.players) {
      send(other, { t: 'peer_left', you: other.slot });
    }
    log(`room ${room.code}: a player left, ${room.players.length} remaining`);
  }

  function handleCreate(client, msg) {
    if (client.room) return sendError(client, 'already_in_room', 'Leave your current room first.');

    const code = uniqueRoomCode();
    if (code === null) return sendError(client, 'server_busy', 'Could not allocate a room, try again.');

    client.name = sanitizeText(msg.name, MAX_NAME_LENGTH, 'Player');
    client.char = sanitizeText(msg.char, MAX_ID_LENGTH, 'bf');

    const room = { code, players: [client] };
    rooms.set(code, room);
    client.room = room;
    client.slot = 0;

    send(client, { t: 'created', code, you: 0 });
    log(`room ${code} created by "${client.name}"`);
  }

  function handleJoin(client, msg) {
    if (client.room) return sendError(client, 'already_in_room', 'Leave your current room first.');

    const code = normalizeCode(msg.code);
    const room = rooms.get(code);
    if (!room) return sendError(client, 'room_not_found', `There is no room "${code}".`);
    if (room.players.length >= ROOM_SIZE) return sendError(client, 'room_full', 'That room is full.');

    client.name = sanitizeText(msg.name, MAX_NAME_LENGTH, 'Player');
    client.char = sanitizeText(msg.char, MAX_ID_LENGTH, 'bf');

    const host = room.players[0];
    room.players.push(client);
    client.room = room;
    client.slot = room.players.length - 1;

    send(client, { t: 'joined', code, you: client.slot, peer: profileOf(host) });
    send(host, { t: 'peer_joined', peer: profileOf(client) });
    log(`room ${code}: "${client.name}" joined`);
  }

  function handleRelay(client, msg) {
    const room = client.room;
    if (!room) return sendError(client, 'not_in_room', 'Join or create a room first.');

    // Keep the server's idea of the profile fresh so late joiners see the right data.
    if (msg.t === 'profile') {
      client.name = sanitizeText(msg.name, MAX_NAME_LENGTH, client.name);
      client.char = sanitizeText(msg.char, MAX_ID_LENGTH, client.char);
      msg.name = client.name;
      msg.char = client.char;
    }

    // The sender can't fake who it is.
    msg.from = client.slot;

    for (const other of room.players) {
      if (other !== client) send(other, msg);
    }
  }

  function handleMessage(client, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      return sendError(client, 'bad_request', 'Messages must be JSON.');
    }
    if (typeof msg !== 'object' || msg === null || Array.isArray(msg) || typeof msg.t !== 'string') {
      return sendError(client, 'bad_request', 'Messages must be objects with a "t" field.');
    }

    if (msg.t === 'ping') {
      return send(client, { t: 'pong', n: msg.n });
    }

    if (msg.t === 'create' || msg.t === 'join') {
      if (msg.v !== PROTOCOL_VERSION) {
        return sendError(client, 'bad_version', `This server speaks protocol ${PROTOCOL_VERSION}, you sent ${msg.v}.`);
      }
      return msg.t === 'create' ? handleCreate(client, msg) : handleJoin(client, msg);
    }

    if (msg.t === 'leave') {
      leaveRoom(client);
      return send(client, { t: 'left' });
    }

    if (RELAY_TYPES.has(msg.t)) {
      return handleRelay(client, msg);
    }

    return sendError(client, 'bad_request', `Unknown message type "${msg.t}".`);
  }

  /**
   * One message from a client (a line over TCP, a text frame over WebSocket): size check, rate limit, then handle it.
   * @returns {boolean} false if the client was disconnected.
   */
  function ingest(client, line) {
    if (Buffer.byteLength(line) > MAX_LINE_BYTES) {
      sendError(client, 'too_large', 'Message too large.');
      client.socket.destroy();
      return false;
    }

    const now = Date.now();
    if (now - client.rateWindowStart >= RATE_WINDOW_MS) {
      client.rateWindowStart = now;
      client.rateCount = 0;
      client.rateWarned = false;
    }
    client.rateCount++;
    if (client.rateCount > RATE_HARD_LIMIT) {
      client.socket.destroy();
      return false;
    }
    if (client.rateCount > RATE_SOFT_LIMIT) {
      if (!client.rateWarned) {
        client.rateWarned = true;
        sendError(client, 'rate_limited', 'Slow down.');
      }
      return true;
    }

    handleMessage(client, line);
    return true;
  }

  const HEADER_LIMIT_BYTES = 8192;
  const sockets = new Set(); // every open connection, so close() can drop them all

  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.setNoDelay(true); // small realtime messages, don't wait to batch them
    socket.setTimeout(idleTimeoutMs);

    const client = {
      socket,
      webSocket: false,
      room: null,
      slot: 0,
      name: 'Player',
      char: 'bf',
      rateWindowStart: Date.now(),
      rateCount: 0,
      rateWarned: false,
    };

    // What the connection turned out to be, decided from its first bytes: 'tcp', 'http' or 'ws'.
    let mode = null;
    let pending = Buffer.alloc(0); // not yet classified, or an incomplete HTTP request
    const decoder = new StringDecoder('utf8');
    let buffer = '';
    let frames = null;

    socket.on('timeout', () => socket.destroy());
    socket.on('error', () => socket.destroy());
    socket.on('close', () => leaveRoom(client));

    function onTcpData(chunk) {
      buffer += decoder.write(chunk);

      let newline;
      while ((newline = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line.length === 0) continue;
        if (!ingest(client, line)) return;
      }

      // A "line" that never ends is either a bug or an attack.
      if (buffer.length > MAX_LINE_BYTES) {
        sendError(client, 'too_large', 'Message too large.');
        socket.destroy();
      }
    }

    function onWebSocketData(chunk) {
      let messages;
      try {
        messages = frames.push(chunk);
      } catch (e) {
        socket.end(ws.closeFrame(e.closeCode || 1002));
        return;
      }

      for (const message of messages) {
        if (socket.destroyed) return;
        if (message.opcode === ws.OP_TEXT) {
          const line = message.payload.toString('utf8').trim();
          if (line.length > 0 && !ingest(client, line)) return;
        } else if (message.opcode === ws.OP_PING) {
          socket.write(ws.encodeFrame(ws.OP_PONG, message.payload));
        } else if (message.opcode === ws.OP_CLOSE) {
          socket.end(ws.closeFrame(1000));
          return;
        } else if (message.opcode === ws.OP_BINARY) {
          socket.end(ws.closeFrame(1003)); // only text is supported
          return;
        }
      }
    }

    function onHttpData(chunk) {
      pending = Buffer.concat([pending, chunk]);
      const end = pending.indexOf('\r\n\r\n');
      if (end === -1) {
        if (pending.length > HEADER_LIMIT_BYTES) socket.destroy();
        return;
      }

      const head = pending.subarray(0, end).toString('latin1').split('\r\n');
      const rest = pending.subarray(end + 4);
      const headers = {};
      for (const headerLine of head.slice(1)) {
        const colon = headerLine.indexOf(':');
        if (colon > 0) headers[headerLine.slice(0, colon).trim().toLowerCase()] = headerLine.slice(colon + 1).trim();
      }

      const wantsUpgrade = (headers['upgrade'] || '').toLowerCase() === 'websocket';
      if (wantsUpgrade && headers['sec-websocket-key'] && headers['sec-websocket-version'] === '13') {
        mode = 'ws';
        client.webSocket = true;
        frames = new ws.FrameDecoder(MAX_LINE_BYTES);
        socket.write(ws.handshakeResponse(headers['sec-websocket-key']));
        pending = Buffer.alloc(0);
        if (rest.length > 0) onWebSocketData(rest);
        return;
      }

      // Anything else: a status page. Hosting services poll this to see if the app is up.
      const body = `Funkin' online relay (protocol v${PROTOCOL_VERSION}), ${rooms.size} room(s).\n`;
      socket.end(
        'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n' +
          `Content-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`
      );
    }

    socket.on('data', (chunk) => {
      if (mode === null) {
        pending = Buffer.concat([pending, chunk]);
        if (pending.length < 4) return; // too short to tell
        // TCP clients open with a JSON object, never with an HTTP verb.
        mode = pending.subarray(0, 4).toString('latin1') === 'GET ' ? 'http' : 'tcp';
        chunk = pending;
        pending = Buffer.alloc(0);
      }

      if (mode === 'tcp') onTcpData(chunk);
      else if (mode === 'ws') onWebSocketData(chunk);
      else onHttpData(chunk);
    });
  });

  return {
    server,
    rooms,
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
  };
}

module.exports = {
  createRelayServer,
  PROTOCOL_VERSION,
  RELAY_TYPES,
  CODE_ALPHABET,
  CODE_LENGTH,
  MAX_LINE_BYTES,
};

if (require.main === module) {
  const port = Number(process.argv[2] || process.env.PORT || DEFAULT_PORT);
  const relay = createRelayServer({ log: (m) => console.log(`[${new Date().toISOString()}] ${m}`) });
  relay.server.listen(port, '0.0.0.0', () => {
    console.log(`Funkin' online relay listening on port ${port} (protocol v${PROTOCOL_VERSION})`);
  });
  const shutdown = () => relay.close().then(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
