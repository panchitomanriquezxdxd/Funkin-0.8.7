package funkin.online;

import flixel.FlxSprite;
import flixel.group.FlxSpriteGroup;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.util.TouchUtil;

/**
 * A plain rectangular button that works with both the mouse and touch. Needs no art assets.
 */
class OnlineButton extends FlxSpriteGroup
{
  public static inline var NORMAL_COLOR:FlxColor = 0xFF2B3A67;
  public static inline var PRESSED_COLOR:FlxColor = 0xFF4C6FFF;
  public static inline var DISABLED_COLOR:FlxColor = 0xFF3A3A3A;

  public var background(default, null):FlxSprite;
  public var label(default, null):FlxText;
  public var onTap:Null<Void->Void> = null;
  public var enabled(default, set):Bool = true;

  public function new(x:Float, y:Float, width:Int, height:Int, text:String, ?onTap:Void->Void, textSize:Int = 32)
  {
    super(x, y);
    this.onTap = onTap;

    background = new FlxSprite().makeGraphic(width, height, FlxColor.WHITE);
    background.color = NORMAL_COLOR;
    add(background);

    label = new FlxText(0, 0, width, text, textSize);
    label.setFormat(Paths.font('vcr.ttf'), textSize, FlxColor.WHITE, CENTER, OUTLINE, FlxColor.BLACK);
    label.y = (height - label.height) / 2;
    add(label);

    scrollFactor.set(0, 0);
  }

  function set_enabled(value:Bool):Bool
  {
    enabled = value;
    background.color = value ? NORMAL_COLOR : DISABLED_COLOR;
    label.alpha = value ? 1.0 : 0.5;
    return value;
  }

  public function setText(text:String):Void
  {
    label.text = text;
    label.y = background.y + (background.height - label.height) / 2;
  }

  override public function update(elapsed:Float):Void
  {
    super.update(elapsed);
    if (!visible || !alive) return;

    var touching:Bool = TouchUtil.pressed && TouchUtil.overlaps(background);
    if (enabled) background.color = touching ? PRESSED_COLOR : NORMAL_COLOR;

    // A tap is a quick press and release on the button.
    if (enabled && onTap != null && TouchUtil.pressAction(background, null, false))
    {
      onTap();
    }
  }
}
