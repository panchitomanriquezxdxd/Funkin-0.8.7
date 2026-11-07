package funkin.online;

import flixel.util.FlxSave;

/**
 * Remembers what the player typed in the online menu (name, server, character).
 * Kept in its own small save so it doesn't touch the game's main save format.
 */
class OnlineSettings
{
  static var save:Null<FlxSave> = null;

  public static var playerName(get, set):String;
  public static var serverAddress(get, set):String;
  public static var character(get, set):String;

  static function get_playerName():String return read('playerName', 'Player');

  static function set_playerName(value:String):String return write('playerName', OnlineProtocol.sanitizeName(value));

  static function get_serverAddress():String return read('serverAddress', '127.0.0.1:${OnlineProtocol.DEFAULT_PORT}');

  static function set_serverAddress(value:String):String return write('serverAddress', value);

  static function get_character():String return read('character', 'bf');

  static function set_character(value:String):String return write('character', value);

  static function open():Null<FlxSave>
  {
    if (save != null) return save;

    try
    {
      var newSave:FlxSave = new FlxSave();
      if (newSave.bind('onlineSettings', 'funkin-online')) save = newSave;
    }
    catch (e:Dynamic)
    {
      trace('Could not open the online settings save: $e');
    }

    return save;
  }

  static function read(field:String, fallback:String):String
  {
    var opened:Null<FlxSave> = open();
    if (opened == null) return fallback;

    var value:Dynamic = Reflect.field(opened.data, field);
    return Std.isOfType(value, String) && (value : String).length > 0 ? value : fallback;
  }

  static function write(field:String, value:String):String
  {
    var opened:Null<FlxSave> = open();
    if (opened != null)
    {
      try
      {
        Reflect.setField(opened.data, field, value);
        opened.flush();
      }
      catch (e:Dynamic) {}
    }
    return value;
  }
}
