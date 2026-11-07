package funkin.online;

import haxe.crypto.Base64;
import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * What a WebSocket stream (RFC 6455) delivers to the client.
 */
enum WebSocketMessage
{
  /**
   * A complete text message.
   */
  Text(text:String);

  /**
   * The server pinged us: answer with `WebSocketCodec.encodeFrame(OP_PONG, payload)`.
   */
  Ping(payload:Bytes);

  /**
   * The server is closing the connection.
   */
  Close(code:Int);
}

/**
 * The client side of the WebSocket protocol, kept free of sockets so it can be tested on its own:
 * the opening handshake and the framing of messages.
 */
class WebSocketCodec
{
  public static inline var OP_CONTINUATION:Int = 0x0;
  public static inline var OP_TEXT:Int = 0x1;
  public static inline var OP_BINARY:Int = 0x2;
  public static inline var OP_CLOSE:Int = 0x8;
  public static inline var OP_PING:Int = 0x9;
  public static inline var OP_PONG:Int = 0xA;

  static inline var GUID:String = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  /**
   * A random `Sec-WebSocket-Key`.
   */
  public static function makeKey():String
  {
    final bytes:Bytes = Bytes.alloc(16);
    for (i in 0...16)
      bytes.set(i, Std.random(256));
    return Base64.encode(bytes);
  }

  /**
   * The `Sec-WebSocket-Accept` value the server must answer with for a key.
   */
  public static function acceptFor(key:String):String
  {
    return Base64.encode(Sha1.make(Bytes.ofString(key + GUID)));
  }

  /**
   * The HTTP request that asks the server to switch to WebSocket.
   * @param defaultPort The port that doesn't need to be written in the `Host` header (80, or 443 when secure).
   */
  public static function handshakeRequest(host:String, port:Int, path:String, key:String, defaultPort:Int):String
  {
    final hostHeader:String = port == defaultPort ? host : '$host:$port';
    return 'GET $path HTTP/1.1\r\n'
      + 'Host: $hostHeader\r\n'
      + 'Upgrade: websocket\r\n'
      + 'Connection: Upgrade\r\n'
      + 'Sec-WebSocket-Key: $key\r\n'
      + 'Sec-WebSocket-Version: 13\r\n'
      + '\r\n';
  }

  /**
   * Check the server's answer to the handshake.
   * @param statusLine The first line of the response, e.g. `HTTP/1.1 101 Switching Protocols`.
   * @param headers The other header lines.
   * @return `null` if it's a valid upgrade, otherwise what is wrong with it.
   */
  public static function checkHandshakeResponse(statusLine:String, headers:Array<String>, key:String):Null<String>
  {
    final parts:Array<String> = statusLine.split(' ');
    if (parts.length < 2 || parts[1] != '101') return 'The server answered "$statusLine" instead of upgrading to WebSocket.';

    var accept:Null<String> = null;
    for (line in headers)
    {
      final colon:Int = line.indexOf(':');
      if (colon > 0 && line.substr(0, colon).toLowerCase() == 'sec-websocket-accept') accept = StringTools.trim(line.substr(colon + 1));
    }

    if (accept != acceptFor(key)) return 'The server did not complete the WebSocket handshake correctly.';
    return null;
  }

  /**
   * Build one frame to send. Frames from a client must be masked.
   * @param mask Four bytes of mask, random for every frame.
   */
  public static function encodeFrame(opcode:Int, payload:Bytes, mask:Bytes):Bytes
  {
    final out:BytesBuffer = new BytesBuffer();
    out.addByte(0x80 | opcode); // FIN, not fragmented

    final length:Int = payload.length;
    if (length < 126)
    {
      out.addByte(0x80 | length);
    }
    else if (length < 65536)
    {
      out.addByte(0x80 | 126);
      out.addByte((length >> 8) & 0xFF);
      out.addByte(length & 0xFF);
    }
    else
    {
      out.addByte(0x80 | 127);
      for (i in 0...4)
        out.addByte(0);
      out.addByte((length >> 24) & 0xFF);
      out.addByte((length >> 16) & 0xFF);
      out.addByte((length >> 8) & 0xFF);
      out.addByte(length & 0xFF);
    }

    out.addBytes(mask, 0, 4);
    for (i in 0...length)
      out.addByte(payload.get(i) ^ mask.get(i & 3));

    return out.getBytes();
  }

  /**
   * A text message as a frame, with a fresh random mask.
   */
  public static function textFrame(text:String):Bytes
  {
    return encodeFrame(OP_TEXT, Bytes.ofString(text), randomMask());
  }

  /**
   * Four random bytes for masking a frame.
   */
  public static function randomMask():Bytes
  {
    final mask:Bytes = Bytes.alloc(4);
    for (i in 0...4)
      mask.set(i, Std.random(256));
    return mask;
  }

  /**
   * A close frame, for a clean goodbye.
   */
  public static function closeFrame(code:Int = 1000):Bytes
  {
    final payload:Bytes = Bytes.alloc(2);
    payload.set(0, (code >> 8) & 0xFF);
    payload.set(1, code & 0xFF);
    return encodeFrame(OP_CLOSE, payload, randomMask());
  }
}

/**
 * Turns the bytes the server sends into messages. Feed it whatever the socket returns, in chunks of any size.
 */
class WebSocketFrameParser
{
  var buffer:Bytes = Bytes.alloc(0);
  var fragments:BytesBuffer = new BytesBuffer();
  var fragmentCount:Int = 0;
  var fragmentBytes:Int = 0;
  final maxPayload:Int;

  /**
   * Set when the stream is not valid WebSocket (or too big). The connection should be dropped.
   */
  public var error(default, null):Null<String> = null;

  public function new(maxPayload:Int = 65536)
  {
    this.maxPayload = maxPayload;
  }

  /**
   * @param chunk The bytes received.
   * @param length How many bytes of `chunk` are valid.
   * @return The messages completed by this data.
   */
  public function push(chunk:Bytes, length:Int):Array<WebSocketMessage>
  {
    final messages:Array<WebSocketMessage> = [];
    if (error != null) return messages;

    // Append the new data to what was left over.
    final joined:Bytes = Bytes.alloc(buffer.length + length);
    joined.blit(0, buffer, 0, buffer.length);
    joined.blit(buffer.length, chunk, 0, length);
    buffer = joined;

    var position:Int = 0;

    while (buffer.length - position >= 2)
    {
      final b0:Int = buffer.get(position);
      final b1:Int = buffer.get(position + 1);
      final fin:Bool = (b0 & 0x80) != 0;
      final opcode:Int = b0 & 0x0F;
      final masked:Bool = (b1 & 0x80) != 0;
      var payloadLength:Int = b1 & 0x7F;
      var headerLength:Int = 2;

      if ((b0 & 0x70) != 0)
      {
        error = 'Reserved bits set.';
        break;
      }

      if (payloadLength == 126)
      {
        if (buffer.length - position < 4) break;
        payloadLength = (buffer.get(position + 2) << 8) | buffer.get(position + 3);
        headerLength = 4;
      }
      else if (payloadLength == 127)
      {
        if (buffer.length - position < 10) break;
        // Anything above 4 GB is far beyond the limit anyway.
        if (buffer.get(position + 2) != 0 || buffer.get(position + 3) != 0 || buffer.get(position + 4) != 0 || buffer.get(position + 5) != 0)
        {
          error = 'Frame too large.';
          break;
        }
        payloadLength = (buffer.get(position + 6) << 24) | (buffer.get(position + 7) << 16) | (buffer.get(position + 8) << 8) | buffer.get(position + 9);
        headerLength = 10;
      }

      if (payloadLength < 0 || payloadLength > maxPayload)
      {
        error = 'Frame too large.';
        break;
      }

      final maskLength:Int = masked ? 4 : 0;
      if (buffer.length - position < headerLength + maskLength + payloadLength) break;

      final payload:Bytes = Bytes.alloc(payloadLength);
      final dataStart:Int = position + headerLength + maskLength;
      for (i in 0...payloadLength)
      {
        final value:Int = buffer.get(dataStart + i);
        payload.set(i, masked ? value ^ buffer.get(position + headerLength + (i & 3)) : value);
      }
      position += headerLength + maskLength + payloadLength;

      final isControl:Bool = (opcode & 0x8) != 0;
      if (isControl)
      {
        if (!fin || payloadLength > 125)
        {
          error = 'Bad control frame.';
          break;
        }

        switch (opcode)
        {
          case WebSocketCodec.OP_PING:
            messages.push(Ping(payload));
          case WebSocketCodec.OP_CLOSE:
            messages.push(Close(payloadLength >= 2 ? (payload.get(0) << 8) | payload.get(1) : 1005));
          default: // Pongs are not interesting.
        }
        continue;
      }

      if (opcode == WebSocketCodec.OP_CONTINUATION)
      {
        if (fragmentCount == 0)
        {
          error = 'Unexpected continuation.';
          break;
        }
      }
      else if (fragmentCount > 0)
      {
        error = 'New message inside a fragmented one.';
        break;
      }
      else if (opcode != WebSocketCodec.OP_TEXT)
      {
        // Only text is used by the relay. Skip anything else, but keep the stream in sync.
        if (!fin)
        {
          error = 'Fragmented non-text message.';
          break;
        }
        continue;
      }

      fragments.add(payload);
      fragmentCount++;
      fragmentBytes += payloadLength;

      if (fragmentBytes > maxPayload)
      {
        error = 'Message too large.';
        break;
      }

      if (fin)
      {
        final whole:Bytes = fragments.getBytes();
        fragments = new BytesBuffer();
        fragmentCount = 0;
        fragmentBytes = 0;
        messages.push(Text(whole.toString()));
      }
    }

    // Keep what's left (an incomplete frame).
    buffer = buffer.sub(position, buffer.length - position);
    return messages;
  }
}
