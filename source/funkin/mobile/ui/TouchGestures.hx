package funkin.mobile.ui;

import flixel.FlxG;
import flixel.input.touch.FlxTouch;

/**
 * Pure geometry used by `TouchGestures`. Kept free of Flixel so it can be unit tested.
 */
class GestureMath
{
  /**
   * Distance between two points.
   */
  public static function distance(x1:Float, y1:Float, x2:Float, y2:Float):Float
  {
    final dx:Float = x2 - x1;
    final dy:Float = y2 - y1;
    return Math.sqrt(dx * dx + dy * dy);
  }

  /**
   * How much the fingers moved apart (>1) or together (<1) between two frames.
   * @return `1.0` when there is nothing to compare (fingers on top of each other, or no previous distance).
   */
  public static function pinchRatio(previousDistance:Float, currentDistance:Float, minDistance:Float = 8.0):Float
  {
    if (previousDistance < minDistance || currentDistance < minDistance) return 1.0;
    return currentDistance / previousDistance;
  }
}

/**
 * Detects two-finger gestures: pinch (zoom) and drag (pan/scroll).
 * Call `update()` once per frame, then read the results. Single-finger input is left alone, since it already
 * arrives as mouse input and the editors handle it.
 *
 * Values are in screen pixels, in the game's coordinate space.
 */
class TouchGestures
{
  /**
   * Fingers further apart than this are not considered one gesture (guards against palm touches).
   */
  static inline var MIN_FINGER_DISTANCE:Float = 8.0;

  /**
   * Whether two fingers are currently down.
   */
  public var active(default, null):Bool = false;

  /**
   * Zoom factor since last frame: above 1 when the fingers spread, below 1 when they pinch. `1.0` when idle.
   */
  public var pinchRatio(default, null):Float = 1.0;

  /**
   * Movement of the midpoint between the fingers since last frame.
   */
  public var panX(default, null):Float = 0;

  public var panY(default, null):Float = 0;

  var lastDistance:Float = -1;
  var lastMidX:Float = 0;
  var lastMidY:Float = 0;

  public function new() {}

  // `screenX/screenY` are in screen pixels, which is what the pan needs (`viewX/viewY` depend on the camera's zoom).
  @:haxe.warning("-WDeprecated")
  public function update():Void
  {
    pinchRatio = 1.0;
    panX = 0;
    panY = 0;

    final first:Null<FlxTouch> = FlxG.touches.getFirst();
    var second:Null<FlxTouch> = null;

    for (touch in FlxG.touches.list)
    {
      if (touch.pressed && touch != first)
      {
        second = touch;
        break;
      }
    }

    if (first == null || second == null || !first.pressed)
    {
      reset();
      return;
    }

    final distance:Float = GestureMath.distance(first.screenX, first.screenY, second.screenX, second.screenY);
    final midX:Float = (first.screenX + second.screenX) / 2;
    final midY:Float = (first.screenY + second.screenY) / 2;

    if (active)
    {
      pinchRatio = GestureMath.pinchRatio(lastDistance, distance, MIN_FINGER_DISTANCE);
      panX = midX - lastMidX;
      panY = midY - lastMidY;
    }

    active = true;
    lastDistance = distance;
    lastMidX = midX;
    lastMidY = midY;
  }

  /**
   * Forget the current gesture (e.g. when switching screens).
   */
  public function reset():Void
  {
    active = false;
    lastDistance = -1;
    pinchRatio = 1.0;
    panX = 0;
    panY = 0;
  }
}
