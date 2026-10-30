package funkin.mobile.util;

/**
 * A rough performance class for a mobile device.
 */
enum abstract PerformanceTier(String) to String
{
  /**
   * Low memory / 32-bit devices. Keep memory use down and don't chase high refresh rates.
   */
  var LOW = 'low';

  /**
   * The middle of the road. Sensible defaults.
   */
  var MID = 'mid';

  /**
   * Plenty of memory. Favor fewer garbage collections.
   */
  var HIGH = 'high';
}

/**
 * Settings handed to the HXCPP (Immix) garbage collector.
 * A value of `0` means "leave the runtime's default alone".
 */
typedef GcTuning =
{
  /**
   * Heap size (in MB) below which the GC doesn't bother running a full collection.
   */
  var minimumWorkingMemoryMB:Int;

  /**
   * Minimum amount of headroom (in MB) left between a collection and the next one.
   */
  var minimumFreeSpaceMB:Int;
}

/**
 * Pure (dependency free) helpers that decide how aggressive a device can be.
 * Kept separate from `PerformanceProfile` so the decisions can be unit tested.
 */
class DeviceTier
{
  /**
   * `MemTotal` reports less than the marketed RAM (a "4 GB" phone usually shows ~3.6 GB),
   * so these limits sit in the gaps between the common sizes.
   * - below this: 3 GB class devices and smaller.
   */
  public static inline var LOW_MEMORY_LIMIT_KB:Int = 3400000;

  /**
   * - below this: 4 GB class devices. At or above: 6 GB and up.
   */
  public static inline var HIGH_MEMORY_LIMIT_KB:Int = 5000000;

  /**
   * The target framerate used for devices that shouldn't chase their screen's refresh rate.
   */
  public static inline var LOW_TIER_FRAMERATE:Int = 60;

  /**
   * Extract the `MemTotal` value (in kB) from the contents of `/proc/meminfo`.
   * @param meminfo The raw file contents.
   * @return The total memory in kB, or `0` if it couldn't be read.
   */
  public static function parseMemTotalKb(meminfo:Null<String>):Int
  {
    if (meminfo == null) return 0;

    final regex:EReg = ~/^MemTotal:\s+(\d+)\s+kB/m;
    if (!regex.match(meminfo)) return 0;

    final value:Null<Int> = Std.parseInt(regex.matched(1));
    return value ?? 0;
  }

  /**
   * Classify a device from its total RAM.
   * @param totalKb Total memory in kB. `0` or less means "unknown", which is treated as `MID` so nothing changes.
   * @param is32BitProcess Whether the game is running as a 32-bit process.
   *   Those only get ~3 GB of address space (shared with textures and audio) however much RAM the phone has,
   *   so they're treated as `LOW`.
   */
  public static function tierForMemory(totalKb:Int, is32BitProcess:Bool = false):PerformanceTier
  {
    if (is32BitProcess) return LOW;
    if (totalKb <= 0) return MID;
    if (totalKb < LOW_MEMORY_LIMIT_KB) return LOW;
    if (totalKb < HIGH_MEMORY_LIMIT_KB) return MID;
    return HIGH;
  }

  /**
   * GC settings for a tier, or `null` to keep the runtime's defaults.
   *
   * HXCPP's defaults on Android/iOS are 8 MB working memory / 4 MB free space
   * (versus 20 MB / 10 MB on desktop), which makes collections far more frequent while the heap is still small,
   * and every collection is a stop-the-world pause that can eat a 16.6 ms frame.
   * - `LOW`: keep the small defaults, the extra headroom would cost RAM that these devices don't have.
   * - `MID`: use the desktop defaults.
   * - `HIGH`: a bit more on top of that.
   */
  public static function gcTuningFor(tier:PerformanceTier):Null<GcTuning>
  {
    return switch (tier)
    {
      case LOW: null;
      case MID: {minimumWorkingMemoryMB: 20, minimumFreeSpaceMB: 10};
      case HIGH: {minimumWorkingMemoryMB: 32, minimumFreeSpaceMB: 16};
    }
  }

  /**
   * The highest framerate a tier should run at.
   * @return The cap in FPS, or `0` for "no cap" (follow the screen's refresh rate).
   */
  public static function framerateCapFor(tier:PerformanceTier):Int
  {
    return switch (tier)
    {
      case LOW: LOW_TIER_FRAMERATE;
      case MID | HIGH: 0;
    }
  }

  /**
   * Apply a tier's framerate cap to a refresh rate.
   * @param refreshRate The screen's refresh rate in Hz.
   * @param tier The device tier.
   * @param overrideCap An explicit cap (e.g. from a build flag). `0` or less means "use the tier's cap".
   * @return The framerate the game should target. Never below 60.
   */
  public static function capFramerate(refreshRate:Int, tier:PerformanceTier, overrideCap:Int = 0):Int
  {
    var rate:Int = refreshRate < 60 ? 60 : refreshRate;

    final cap:Int = overrideCap > 0 ? overrideCap : framerateCapFor(tier);
    if (cap > 0 && rate > cap) rate = cap;

    return rate < 60 ? 60 : rate;
  }
}
