package funkin.online;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Collects the raw chunks read from a socket and splits them into `\n` terminated lines.
 * Chunks can end in the middle of a line (or in the middle of a UTF-8 character), so the
 * bytes are kept until the newline arrives.
 */
class LineBuffer
{
  var pending:BytesBuffer = new BytesBuffer();
  var pendingLength:Int = 0;
  final maxLineBytes:Int;

  /**
   * Set when a line grew past the limit. The connection should be dropped.
   */
  public var overflowed(default, null):Bool = false;

  public function new(maxLineBytes:Int = 4096)
  {
    this.maxLineBytes = maxLineBytes;
  }

  /**
   * Feed received bytes in.
   * @param bytes The buffer the bytes were read into.
   * @param length How many bytes of `bytes` are valid.
   * @return The complete lines (without their terminator), oldest first. Empty lines are skipped.
   */
  public function push(bytes:Bytes, length:Int):Array<String>
  {
    var lines:Array<String> = [];
    var start:Int = 0;

    for (i in 0...length)
    {
      if (bytes.get(i) != 10) continue;

      pending.addBytes(bytes, start, i - start);
      pendingLength += i - start;
      start = i + 1;

      if (pendingLength > 0)
      {
        var line:String = pending.getBytes().toString();
        if (StringTools.endsWith(line, '\r')) line = line.substr(0, line.length - 1);
        if (line.length > 0) lines.push(line);
      }
      pending = new BytesBuffer();
      pendingLength = 0;
    }

    var rest:Int = length - start;
    if (rest > 0)
    {
      pending.addBytes(bytes, start, rest);
      pendingLength += rest;
    }

    if (pendingLength > maxLineBytes) overflowed = true;
    return lines;
  }
}
