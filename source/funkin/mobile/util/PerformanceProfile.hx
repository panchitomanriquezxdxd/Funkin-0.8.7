package funkin.mobile.util;

import funkin.mobile.util.DeviceTier;

/**
 * Detects how capable the current mobile device is and tunes the game accordingly:
 * - garbage collector thresholds (fewer mid-song collection pauses),
 * - the target framerate (don't chase 90/120 Hz on devices that can't hold it),
 * - how much of the UI gets pinned in memory at startup (see `FunkinMemory.initialCache`).
 *
 * Build flags:
 * - `-DMOBILE_FRAMERATE_CAP=60` forces a framerate cap on every mobile device.
 * - `-DPERFORMANCE_TIER=low|mid|high` skips the detection and forces a tier (handy for testing).
 */
@:nullSafety
class PerformanceProfile
{
  static var detectedTier:Null<PerformanceTier> = null;

  /**
   * The performance class of this device. Detected once, then cached.
   */
  public static var tier(get, never):PerformanceTier;

  /**
   * Whether this is a device that should save memory wherever it can.
   */
  public static var isLowEnd(get, never):Bool;

  /**
   * Tune the runtime for this device. Call once, early at startup.
   */
  public static function apply():Void
  {
    #if cpp
    final tuning:Null<GcTuning> = DeviceTier.gcTuningFor(tier);
    if (tuning != null)
    {
      cpp.vm.Gc.setMinimumWorkingMemory(tuning.minimumWorkingMemoryMB * 1024 * 1024);
      cpp.vm.Gc.setMinimumFreeSpace(tuning.minimumFreeSpaceMB * 1024 * 1024);
    }
    #end

    trace(' PERFORMANCE '.bold().bg_bright_lilac() + ' Device tier: ${tier}, memory: ${Math.round(getTotalMemoryKb() / 1024)} MB');
  }

  /**
   * Apply this device's framerate cap to a screen refresh rate.
   * @param refreshRate The screen's refresh rate in Hz.
   * @return The framerate the game should target.
   */
  public static function capFramerate(refreshRate:Int):Int
  {
    return DeviceTier.capFramerate(refreshRate, tier, getBuildFramerateCap());
  }

  /**
   * Run a major garbage collection at a moment where a pause is harmless (e.g. during the countdown),
   * so the heap is as empty as it can be when notes start falling.
   */
  public static function collectBeforeGameplay():Void
  {
    #if cpp
    funkin.util.MemoryUtil.collect(true);
    #end
  }

  /**
   * Total physical memory of the device in kB, or `0` if it couldn't be determined.
   */
  public static function getTotalMemoryKb():Int
  {
    #if (android || linux)
    // `/proc` files report a size of 0, so `File.getContent` can come back empty. Read line by line instead
    // (same approach as `MemoryUtil.getTaskMemory`). `MemTotal` is the first line of the file.
    var result:Int = 0;

    try
    {
      final input:sys.io.FileInput = sys.io.File.read('/proc/meminfo', false);

      try
      {
        while (true)
        {
          final line:String = input.readLine();
          if (StringTools.startsWith(line, 'MemTotal:'))
          {
            result = DeviceTier.parseMemTotalKb(line);
            break;
          }
        }
      }
      catch (e:haxe.io.Eof) {}

      input.close();
    }
    catch (e:Dynamic) {}

    return result;
    #else
    return 0;
    #end
  }

  static function get_tier():PerformanceTier
  {
    if (detectedTier == null)
    {
      detectedTier = detectTier();
    }

    return detectedTier ?? MID;
  }

  static function get_isLowEnd():Bool
  {
    return tier == LOW;
  }

  static function detectTier():PerformanceTier
  {
    #if PERFORMANCE_TIER
    switch (haxe.macro.Compiler.getDefine('PERFORMANCE_TIER'))
    {
      case 'low':
        return LOW;
      case 'mid':
        return MID;
      case 'high':
        return HIGH;
      default:
    }
    #end

    #if HXCPP_ARMV7
    final is32Bit:Bool = true;
    #else
    final is32Bit:Bool = false;
    #end

    return DeviceTier.tierForMemory(getTotalMemoryKb(), is32Bit);
  }

  static function getBuildFramerateCap():Int
  {
    #if MOBILE_FRAMERATE_CAP
    return Std.parseInt(haxe.macro.Compiler.getDefine('MOBILE_FRAMERATE_CAP') ?? '') ?? 0;
    #else
    return 0;
    #end
  }
}
