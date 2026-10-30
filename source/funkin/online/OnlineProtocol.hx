package funkin.online;

import haxe.Json;

using StringTools;

/**
 * A player's public info, shown in the lobby.
 */
typedef PlayerProfile =
{
  var name:String;
  var char:String;
}

/**
 * The server address, split up.
 */
typedef ServerAddress =
{
  var host:String;
  var port:Int;
}

/**
 * Pure helpers for the wire format shared with `tools/online-server/server.js`.
 * One JSON object per line, UTF-8, `\n` terminated.
 */
class OnlineProtocol
{
  /**
   * Must match `PROTOCOL_VERSION` in the relay server.
   */
  public static inline var VERSION:Int = 1;

  public static inline var DEFAULT_PORT:Int = 7777;
  public static inline var ROOM_CODE_LENGTH:Int = 5;
  public static inline var MAX_NAME_LENGTH:Int = 20;

  /**
   * Turn a message into the line that gets sent over the wire.
   */
  public static function encode(message:Dynamic):String
  {
    return Json.stringify(message) + '\n';
  }

  /**
   * Parse a received line.
   * @return The message, or `null` if it isn't a JSON object with a string `t` field.
   */
  public static function decode(line:String):Null<Dynamic>
  {
    var parsed:Dynamic;
    try
    {
      parsed = Json.parse(line);
    }
    catch (e:Dynamic)
    {
      return null;
    }

    if (parsed == null || !Reflect.isObject(parsed) || Std.isOfType(parsed, Array)) return null;
    if (!Std.isOfType(Reflect.field(parsed, 't'), String)) return null;
    return parsed;
  }

  /**
   * Same normalization the server applies: upper case, letters and digits only.
   */
  public static function normalizeRoomCode(text:Null<String>):String
  {
    if (text == null) return '';
    return ~/[^A-Z0-9]/g.replace(text.toUpperCase(), '');
  }

  public static function isValidRoomCode(text:Null<String>):Bool
  {
    return normalizeRoomCode(text).length == ROOM_CODE_LENGTH;
  }

  /**
   * Parse what a player types in the server field: `host`, `host:port` or `tcp://host:port`.
   * IPv6 literals aren't supported.
   * @return The address, or `null` if it isn't valid.
   */
  public static function parseServerAddress(text:Null<String>):Null<ServerAddress>
  {
    if (text == null) return null;

    var value:String = text.trim();
    if (value.startsWith('tcp://')) value = value.substr(6);
    if (value.endsWith('/')) value = value.substr(0, value.length - 1);
    if (value.length == 0) return null;

    var host:String = value;
    var port:Int = DEFAULT_PORT;

    var colon:Int = value.indexOf(':');
    if (colon != -1)
    {
      if (value.indexOf(':', colon + 1) != -1) return null; // More than one colon.
      host = value.substr(0, colon);
      var parsedPort:Null<Int> = ~/^[0-9]+$/.match(value.substr(colon + 1)) ? Std.parseInt(value.substr(colon + 1)) : null;
      if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) return null;
      port = parsedPort;
    }

    if (host.length == 0 || host.length > 253 || !~/^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/.match(host)) return null;

    return {host: host, port: port};
  }

  /**
   * Make a player name safe to show and send.
   */
  public static function sanitizeName(text:Null<String>, fallback:String = 'Player'):String
  {
    if (text == null) return fallback;
    var cleaned:String = ~/[\x00-\x1f\x7f]/g.replace(text, '').trim();
    if (cleaned.length > MAX_NAME_LENGTH) cleaned = cleaned.substr(0, MAX_NAME_LENGTH);
    return cleaned.length > 0 ? cleaned : fallback;
  }
}
