package funkin.online;

import flixel.FlxG;
import flixel.group.FlxSpriteGroup;
import flixel.text.FlxText;
import flixel.util.FlxColor;

/**
 * The little overlay shown during an online match: the opponent's live score and connection status messages.
 */
class OnlineHud extends FlxSpriteGroup
{
  var scoreText:FlxText;
  var statusText:FlxText;
  var lastLine:String = '';

  public function new()
  {
    super();

    scoreText = new FlxText(0, 6, FlxG.width, '', 24);
    scoreText.setFormat(Paths.font('vcr.ttf'), 24, FlxColor.WHITE, CENTER, OUTLINE, FlxColor.BLACK);
    scoreText.alpha = 0.9;
    add(scoreText);

    statusText = new FlxText(0, FlxG.height * 0.42, FlxG.width, '', 36);
    statusText.setFormat(Paths.font('vcr.ttf'), 36, FlxColor.WHITE, CENTER, OUTLINE, FlxColor.BLACK);
    add(statusText);

    scrollFactor.set(0, 0);
  }

  /**
   * The big message in the middle of the screen. Empty hides it.
   */
  public function setStatus(text:String):Void
  {
    if (statusText.text != text) statusText.text = text;
  }

  /**
   * Refresh the score line.
   */
  public function setOpponent(name:String, score:Int, combo:Int, finished:Bool, aborted:Bool):Void
  {
    var line:String = '$name: $score';
    if (combo > 1) line += '  x$combo';
    if (aborted) line += '  (left)';
    else if (finished) line += '  (finished)';
    if (line == lastLine) return;
    lastLine = line;
    scoreText.text = line;
  }
}
