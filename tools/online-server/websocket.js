'use strict';

/**
 * A minimal WebSocket (RFC 6455) server side: just enough for the relay, with no dependencies.
 * Only text frames carry data. Pings are answered, fragmented messages are reassembled, and the size is capped.
 */

const crypto = require('crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const OP_CONTINUATION = 0x0;
const OP_TEXT = 0x1;
const OP_BINARY = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

/** The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`. */
function acceptKey(key) {
  return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

/** The response that switches an HTTP connection to WebSocket. */
function handshakeResponse(key) {
  return (
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n` +
    '\r\n'
  );
}

/** Build one unmasked (server to client) frame. */
function encodeFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  let header;
  if (data.length < 126) {
    header = Buffer.from([0x80 | opcode, data.length]);
  } else if (data.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(data.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(data.length), 2);
  }
  return Buffer.concat([header, data]);
}

/** Close frame with a status code (1000 normal, 1002 protocol error, 1009 too big). */
function closeFrame(code) {
  const payload = Buffer.alloc(2);
  payload.writeUInt16BE(code, 0);
  return encodeFrame(OP_CLOSE, payload);
}

class ProtocolError extends Error {
  constructor(message, code) {
    super(message);
    this.closeCode = code;
  }
}

/**
 * Turns the bytes of a client's WebSocket stream into messages.
 * `push(chunk)` returns `[{opcode, payload}]` for every complete message (text, binary, close, ping, pong).
 * Throws `ProtocolError` (with the close code to answer with) on a bad stream.
 */
class FrameDecoder {
  constructor(maxPayloadBytes) {
    this.maxPayload = maxPayloadBytes;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentOpcode = 0;
    this.fragmentBytes = 0;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const messages = [];

    for (;;) {
      if (this.buffer.length < 2) break;

      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let length = b1 & 0x7f;
      let offset = 2;

      if ((b0 & 0x70) !== 0) throw new ProtocolError('reserved bits set', 1002);
      if (!masked) throw new ProtocolError('client frames must be masked', 1002);

      if (length === 126) {
        if (this.buffer.length < 4) break;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) break;
        const big = this.buffer.readBigUInt64BE(2);
        if (big > BigInt(this.maxPayload)) throw new ProtocolError('frame too large', 1009);
        length = Number(big);
        offset = 10;
      }

      if (length > this.maxPayload) throw new ProtocolError('frame too large', 1009);
      const isControl = (opcode & 0x8) !== 0;
      if (isControl && (!fin || length > 125)) throw new ProtocolError('bad control frame', 1002);

      if (this.buffer.length < offset + 4 + length) break;

      const mask = this.buffer.subarray(offset, offset + 4);
      const payload = Buffer.alloc(length);
      for (let i = 0; i < length; i++) {
        payload[i] = this.buffer[offset + 4 + i] ^ mask[i & 3];
      }
      this.buffer = this.buffer.subarray(offset + 4 + length);

      if (isControl) {
        messages.push({ opcode, payload });
        continue;
      }

      if (opcode === OP_CONTINUATION) {
        if (this.fragments.length === 0) throw new ProtocolError('unexpected continuation', 1002);
      } else if (this.fragments.length > 0) {
        throw new ProtocolError('new message inside a fragmented one', 1002);
      } else {
        this.fragmentOpcode = opcode;
      }

      this.fragments.push(payload);
      this.fragmentBytes += length;
      if (this.fragmentBytes > this.maxPayload) throw new ProtocolError('message too large', 1009);

      if (fin) {
        messages.push({ opcode: this.fragmentOpcode, payload: Buffer.concat(this.fragments) });
        this.fragments = [];
        this.fragmentBytes = 0;
      }
    }

    return messages;
  }
}

module.exports = {
  acceptKey,
  handshakeResponse,
  encodeFrame,
  closeFrame,
  FrameDecoder,
  ProtocolError,
  OP_TEXT,
  OP_BINARY,
  OP_CLOSE,
  OP_PING,
  OP_PONG,
};
