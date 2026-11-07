package funkin.online;

import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.ui.MusicBeatState;

/**
 * Shown after an online song: both players' scores, and a button back to the lobby.
 * Waits for the other player to finish if they haven't yet.
 */
class OnlineResultsState extends MusicBeatState
{
  final match:Null<OnlineMatch>;
  var title:FlxText;
  var youText:FlxText;
  var themText:FlxText;
  var infoText:FlxText;
  var lobbyButton:OnlineButton;
  var shownFinal:Bool = false;

  public function new()
  {
    super();
    match = OnlineMatch.current;
  }

  override public function create():Void
  {
    super.create();
    FlxG.mouse.visible = true;

    var bg:FlxSprite = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, 0xFF10131F);
    bg.scrollFactor.set(0, 0);
    add(bg);

    title = text(0, 110, FlxG.width, '', 72, FlxColor.WHITE);
    title.alignment = CENTER;
    add(title);

    youText = text(0, 290, FlxG.width, '', 40, 0xFF9FFFB4);
    youText.alignment = CENTER;
    add(youText);

    themText = text(0, 350, FlxG.width, '', 40, 0xFFFF9F9F);
    themText.alignment = CENTER;
    add(themText);

    infoText = text(0, 450, FlxG.width, '', 28, FlxColor.YELLOW);
    infoText.alignment = CENTER;
    add(infoText);

    lobbyButton = new OnlineButton(FlxG.width / 2 - 200, FlxG.height - 140, 400, 64, 'BACK TO LOBBY', backToLobby);
    add(lobbyButton);

    refreshTexts();
  }

  function text(x:Float, y:Float, width:Float, value:String, size:Int, color:FlxColor):FlxText
  {
    var result:FlxText = new FlxText(x, y, width, value, size);
    result.setFormat(Paths.font('vcr.ttf'), size, color, LEFT, OUTLINE, FlxColor.BLACK);
    result.scrollFactor.set(0, 0);
    return result;
  }

  function refreshTexts():Void
  {
    if (match == null) return;

    youText.text = 'YOU: ${match.localScore}';
    themText.text = '${match.opponentName.toUpperCase()}: ${match.opponentScore}' + (match.opponentAborted ? '  (left)' : '');

    if (!match.opponentFinished)
    {
      title.text = 'WAITING...';
      infoText.text = '${match.opponentName} is still playing';
      return;
    }

    if (match.opponentAborted)
    {
      title.text = 'YOU FINISHED';
      infoText.text = match.connectionLost ? 'The connection was lost.' : '${match.opponentName} left the match.';
    }
    else if (match.localScore > match.opponentScore)
    {
      title.text = 'YOU WIN!';
      infoText.text = '';
    }
    else if (match.localScore < match.opponentScore)
    {
      title.text = 'YOU LOSE';
      infoText.text = '';
    }
    else
    {
      title.text = 'DRAW';
      infoText.text = '';
    }
  }

  function backToLobby():Void
  {
    OnlineMatch.end();
    FlxG.switchState(() -> new OnlineMenuState());
  }

  override public function update(elapsed:Float):Void
  {
    super.update(elapsed);

    // This is what keeps the connection serviced while we wait for the other player's final score.
    match?.update(elapsed);
    refreshTexts();

    if (controls.ACCEPT || controls.BACK) backToLobby();
  }
}
