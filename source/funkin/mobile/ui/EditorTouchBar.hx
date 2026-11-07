package funkin.mobile.ui;

import flixel.FlxCamera;
import flixel.FlxSprite;
import flixel.group.FlxSpriteGroup;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.util.TouchUtil;

/**
 * One button of an `EditorTouchBar`. Fires `onTap` on a tap, or repeatedly while held when `repeats` is set.
 */
class EditorTouchButton extends FlxSpriteGroup
{
  static inline var NORMAL_COLOR:FlxColor = 0xFF2B3A67;
  static inline var PRESSED_COLOR:FlxColor = 0xFF4C6FFF;

  /**
   * Seconds a repeating button waits before it starts repeating, then the time between repeats.
   */
  static inline var REPEAT_DELAY:Float = 0.35;

  static inline var REPEAT_INTERVAL:Float = 0.07;

  public var background(default, null):FlxSprite;
  public var label(default, null):FlxText;
  public var onTap:Null<Void->Void>;
  public var repeats:Bool;

  var holdTime:Float = 0;
  var wasPressed:Bool = false;
  var repeatTimer:Float = 0;

  public function new(width:Int, height:Int, text:String, onTap:Void->Void, repeats:Bool = false)
  {
    super(0, 0);
    this.onTap = onTap;
    this.repeats = repeats;

    background = new FlxSprite().makeGraphic(width, height, FlxColor.WHITE);
    background.color = NORMAL_COLOR;
    background.alpha = 0.8;
    add(background);

    label = new FlxText(0, 0, width, text, 28);
    label.setFormat(Paths.font('vcr.ttf'), 28, FlxColor.WHITE, CENTER, OUTLINE, FlxColor.BLACK);
    label.y = (height - label.height) / 2;
    add(label);

    scrollFactor.set(0, 0);
  }

  override public function update(elapsed:Float):Void
  {
    super.update(elapsed);
    if (!visible || !alive) return;

    final down:Bool = TouchUtil.pressed && TouchUtil.overlaps(background, cameras != null ? cameras[0] : null);
    background.color = down ? PRESSED_COLOR : NORMAL_COLOR;

    if (down && !wasPressed)
    {
      // Fire right away on press: in an editor, waiting for the release feels laggy.
      holdTime = 0;
      repeatTimer = REPEAT_DELAY;
      fire();
    }
    else if (down && repeats)
    {
      holdTime += elapsed;
      repeatTimer -= elapsed;
      while (repeatTimer <= 0)
      {
        repeatTimer += REPEAT_INTERVAL;
        fire();
      }
    }

    wasPressed = down;
  }

  function fire():Void
  {
    if (onTap != null) onTap();
  }
}

/**
 * A column of floating buttons for the editors, for the actions that normally live on keyboard shortcuts.
 * Add the bar to a camera that doesn't zoom or scroll (the editor's UI camera).
 */
class EditorTouchBar extends FlxSpriteGroup
{
  public static inline var BUTTON_WIDTH:Int = 96;
  public static inline var BUTTON_HEIGHT:Int = 64;
  static inline var SPACING:Int = 8;

  var nextY:Float = 0;

  /**
   * @param x Left edge of the bar.
   * @param y Top edge of the bar.
   */
  public function new(x:Float, y:Float)
  {
    super(x, y);
    scrollFactor.set(0, 0);
  }

  /**
   * Add a button under the previous ones.
   * @param text Short label, 1 to 4 characters fit.
   * @param onTap What the button does.
   * @param repeats Whether holding the button repeats the action.
   */
  public function addButton(text:String, onTap:Void->Void, repeats:Bool = false):EditorTouchButton
  {
    final button:EditorTouchButton = new EditorTouchButton(BUTTON_WIDTH, BUTTON_HEIGHT, text, onTap, repeats);
    button.setPosition(x, y + nextY);
    nextY += BUTTON_HEIGHT + SPACING;
    add(button);
    return button;
  }

  /**
   * Put the whole bar on a camera.
   */
  public function useCamera(camera:FlxCamera):Void
  {
    cameras = [camera];
    for (member in members)
    {
      member.cameras = [camera];
    }
  }
}
