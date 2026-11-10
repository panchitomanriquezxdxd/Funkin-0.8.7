package funkin.data;

import json2object.Position;
import json2object.Position.Line;
import json2object.Error;

@:nullSafety
class DataError
{
  public static function printError(error:Error):Void
  {
    switch (error)
    {
      case IncorrectType(vari, expected, pos):
        trace(' ERROR '.error() + 'Expected field "$vari" to be of type "$expected".');
        printPos(pos);
      case IncorrectEnumValue(value, expected, pos):
        trace(' ERROR '.error() + 'Invalid enum value (expected "$expected", got "$value")');
        printPos(pos);
      case InvalidEnumConstructor(value, expected, pos):
        trace(' ERROR '.error() + 'Invalid enum constructor (epxected "$expected", got "$value")');
        printPos(pos);
      case UninitializedVariable(vari, pos):
        trace(' ERROR '.error() + 'Uninitialized variable "$vari"');
        printPos(pos);
      case UnknownVariable(vari, pos):
        trace(' ERROR '.error() + 'Unknown variable "$vari"');
        printPos(pos);
      case ParserError(message, pos):
        trace(' ERROR '.error() + 'Parsing error: ${message}');
        printPos(pos);
      case CustomFunctionException(e, pos):
        if (Std.isOfType(e, String))
        {
          trace(' ERROR '.error() + '${e}');
        }
        else
        {
          printUnknownError(e);
        }
        printPos(pos);
      default:
        printUnknownError(error);
    }
  }

  /**
   * A short, plain-text description of an error, for showing to the user (the colored `printError` output only goes to the log).
   */
  public static function describe(error:Error):String
  {
    switch (error)
    {
      case IncorrectType(vari, expected, pos):
        return 'Field "$vari" should be of type "$expected"${where(pos)}';
      case IncorrectEnumValue(value, expected, pos):
        return 'Invalid value "$value" (expected $expected)${where(pos)}';
      case InvalidEnumConstructor(value, expected, pos):
        return 'Invalid value "$value" (expected $expected)${where(pos)}';
      case UninitializedVariable(vari, pos):
        return 'Missing required field "$vari"${where(pos)}';
      case UnknownVariable(vari, pos):
        return 'Unknown field "$vari"${where(pos)}';
      case ParserError(message, pos):
        return 'JSON error: $message${where(pos)}';
      case CustomFunctionException(e, pos):
        return (Std.isOfType(e, String) ? '$e' : Std.string(e)) + where(pos);
      default:
        return Std.string(error);
    }
  }

  static function where(pos:Position):String
  {
    if (pos == null || pos.lines == null || pos.lines.length == 0) return '';
    var first:Int = pos.lines[0].number;
    var last:Int = pos.lines[pos.lines.length - 1].number;
    return first == last ? ' (line $first)' : ' (lines $first-$last)';
  }

  public static function printUnknownError(e:Dynamic):Void
  {
    switch (Type.typeof(e))
    {
      case TClass(c):
        trace(' ERROR '.error() + '(${Type.getClassName(c)}) ${e.toString()}');
      case TEnum(c):
        trace(' ERROR '.error() + '(${Type.getEnumName(c)}) ${e.toString()}');
      default:
        trace(' ERROR '.error() + '(${Type.typeof(e)}) ${Std.string(e)}');
    }
  }

  /**
   * TODO: Figure out the nicest way to print this.
   * Maybe look up how other JSON parsers format their errors?
   * @see https://github.com/elnabo/json2object/blob/master/src/json2object/Position.hx
   */
  static function printPos(pos:Position):Void
  {
    if (pos.lines[0].number == pos.lines[pos.lines.length - 1].number)
    {
      trace('   at ${(pos.file == '') ? 'line ' : '${pos.file}:'}${pos.lines[0].number}');
    }
    else
    {
      trace('   at ${(pos.file == '') ? 'line ' : '${pos.file}:'}${pos.lines[0].number}-${pos.lines[pos.lines.length - 1].number}');
    }
  }
}
