package funkin.online;

import funkin.online.OnlineClient;
import funkin.online.OnlineProtocol;

/**
 * What the other player did.
 */
enum RemoteKind
{
  Press;
  Release;
  Hit;
  Miss;
}

/**
 * Something the other player did, stamped with THEIR song position when it happened.
 */
typedef RemoteEvent =
{
  var kind:RemoteKind;

  /**
   * Note direction, 0-3 (left, down, up, right).
   */
  var dir:Int;

  /**
   * The sender's song position (ms) when it happened.
   */
  var time:Float;

  /**
   * For hits and misses: the strum time of the note concerned.
   */
  var noteTime:Float;

  /**
   * For hits: `sick`, `good`, `bad` or `shit`.
   */
  var rating:String;
}

/**
 * What to do when a remote event comes due. Implemented by `PlayState`.
 */
typedef RemoteHandlers =
{
  var press:Int->Void;
  var release:Int->Void;
  var hit:(dir:Int, noteTime:Float, rating:String)->Void;
  var miss:(dir:Int, noteTime:Float)->Void;
}

/**
 * The state of an online match: who we're playing, what, and everything that flows between the two players while the song runs.
 *
 * Both players play the SAME chart (the player side) at the same time. Each one sees the other's presses and hits on the
 * opponent strumline, as they happen. Nothing here decides who wins, both sides just report their own score.
 *
 * Flow:
 * 1. The lobby calls `begin()` when the host's `start` message arrives (or is sent) and loads the `PlayState`.
 * 2. The `PlayState` calls `markLocalLoaded()` once everything is ready, then `update()` every frame
 *    until `update()` says to start the countdown.
 * 3. While playing: `sendPress/Release/Hit/Miss/Score` for local actions, `drain()` to apply the remote ones.
 * 4. At the end: `finishLocal()`.
 */
class OnlineMatch
{
  /**
   * The match in progress, or `null` when playing offline.
   */
  public static var current:Null<OnlineMatch> = null;

  /**
   * How long to wait for the other player to finish loading before starting anyway.
   */
  public static inline var LOAD_TIMEOUT_SECONDS:Float = 30.0;

  /**
   * Remote events further in the future than this (ms) are applied immediately. That only happens when the two
   * players' clocks are badly out of step, and holding them back for seconds would look broken.
   */
  public static inline var MAX_HOLD_MS:Float = 1500.0;

  public final songId:String;
  public final difficulty:String;
  public final variation:String;

  /**
   * The character we play as.
   */
  public final ownCharacter:String;

  /**
   * The character the other player picked. Shown on the opponent's side of the stage.
   */
  public final opponentCharacter:String;

  public final opponentName:String;

  public final client:OnlineClient;

  public var opponentScore(default, null):Int = 0;
  public var opponentCombo(default, null):Int = 0;

  /**
   * The other player reached the end of the song.
   */
  public var opponentFinished(default, null):Bool = false;

  /**
   * Whether the other player gave up (left mid-song) rather than finishing.
   */
  public var opponentAborted(default, null):Bool = false;

  /**
   * The relay connection dropped.
   */
  public var connectionLost(default, null):Bool = false;

  public var localLoaded(default, null):Bool = false;
  public var peerLoaded(default, null):Bool = false;
  public var localFinished(default, null):Bool = false;
  public var localScore(default, null):Int = 0;

  /**
   * Set once the countdown was released.
   */
  public var started(default, null):Bool = false;

  var queue:Array<RemoteEvent> = [];
  var peerWasLoadedWhenWeLoaded:Bool = false;
  var secondsWaiting:Float = 0;

  public function new(client:OnlineClient, songId:String, difficulty:String, variation:String, ownCharacter:String, opponentCharacter:String,
      opponentName:String)
  {
    this.client = client;
    this.songId = songId;
    this.difficulty = difficulty;
    this.variation = variation;
    this.ownCharacter = ownCharacter;
    this.opponentCharacter = opponentCharacter;
    this.opponentName = opponentName;
  }

  /**
   * Start a match. Replaces any previous one.
   */
  public static function begin(client:OnlineClient, songId:String, difficulty:String, variation:String, ownCharacter:String, opponentCharacter:String,
      opponentName:String):OnlineMatch
  {
    current = new OnlineMatch(client, songId, difficulty, variation, ownCharacter, opponentCharacter, opponentName);
    return current;
  }

  /**
   * Forget the current match. Doesn't touch the connection, the players stay in their room.
   */
  public static function end():Void
  {
    current = null;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Start handshake
  // ---------------------------------------------------------------------------------------------------------------

  /**
   * Tell the other player our `PlayState` is loaded and ready for the countdown.
   */
  public function markLocalLoaded():Void
  {
    if (localLoaded) return;
    localLoaded = true;
    peerWasLoadedWhenWeLoaded = peerLoaded;
    client.send({t: 'ready', phase: 'loaded'});
  }

  /**
   * How long (ms) to wait before releasing the countdown, so both players start together.
   *
   * Whoever finishes loading LAST has already received the other's "loaded" message, which was sent a
   * half round trip ago. Delaying by half a round trip makes up for the time the message took to arrive for the other
   * player, who started the moment they heard from us.
   */
  public function startDelayMs():Float
  {
    if (!peerWasLoadedWhenWeLoaded || client.peerRttMs < 0) return 0;
    return Math.min(client.peerRttMs / 2, 500);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------------------------------------------

  public function sendPress(dir:Int, songPosition:Float):Void
  {
    client.send({t: 'press', d: dir, ms: round(songPosition)});
  }

  public function sendRelease(dir:Int, songPosition:Float):Void
  {
    client.send({t: 'release', d: dir, ms: round(songPosition)});
  }

  public function sendHit(dir:Int, songPosition:Float, noteTime:Float, rating:String):Void
  {
    client.send({t: 'hit', d: dir, ms: round(songPosition), nt: round(noteTime), r: rating});
  }

  public function sendMiss(dir:Int, songPosition:Float, noteTime:Float):Void
  {
    client.send({t: 'miss', d: dir, ms: round(songPosition), nt: round(noteTime)});
  }

  public function sendScore(score:Int, combo:Int):Void
  {
    localScore = score;
    client.send({t: 'score', s: score, c: combo});
  }

  /**
   * We reached the end of the song (or left early, with `aborted`).
   */
  public function finishLocal(score:Int, aborted:Bool = false):Void
  {
    if (localFinished) return;
    localFinished = true;
    localScore = score;
    client.send({t: 'finish', s: score, aborted: aborted});
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------------------------------------------

  /**
   * Process what arrived on the connection. Call every frame while the match exists (the `PlayState` or the results
   * screen), it is what drives `OnlineClient.poll()` then.
   *
   * @param elapsed Seconds since the last call.
   * @return `true` exactly once: the moment the countdown should be released.
   */
  public function update(elapsed:Float):Bool
  {
    for (event in client.poll())
    {
      switch (event)
      {
        case Message(message):
          handleMessage(message);
        case PeerLeft:
          // Leaving the room mid-song counts as giving up.
          if (!opponentFinished) opponentAborted = true;
          opponentFinished = true;
        case Disconnected(_):
          connectionLost = true;
          if (!opponentFinished) opponentAborted = true;
          opponentFinished = true;
        default:
      }
    }

    if (started) return false;

    if (!localLoaded)
    {
      return false;
    }

    secondsWaiting += elapsed;

    var timedOut:Bool = secondsWaiting >= LOAD_TIMEOUT_SECONDS;
    if (peerLoaded || timedOut || opponentFinished)
    {
      started = true;
      return true;
    }

    return false;
  }

  function handleMessage(message:Dynamic):Void
  {
    var type:String = message.t;

    switch (type)
    {
      case 'ready':
        if (message.phase == 'loaded') peerLoaded = true;
        if (message.phase == 'cannot_start')
        {
          // The other player couldn't load the song (they don't have it), they are never going to play.
          opponentFinished = true;
          opponentAborted = true;
        }

      case 'press':
        enqueue({kind: Press, dir: dirOf(message), time: num(message.ms), noteTime: 0, rating: ''});

      case 'release':
        enqueue({kind: Release, dir: dirOf(message), time: num(message.ms), noteTime: 0, rating: ''});

      case 'hit':
        enqueue({
          kind: Hit,
          dir: dirOf(message),
          time: num(message.ms),
          noteTime: num(message.nt),
          rating: Std.isOfType(message.r, String) ? message.r : 'sick'
        });

      case 'miss':
        enqueue({kind: Miss, dir: dirOf(message), time: num(message.ms), noteTime: num(message.nt), rating: ''});

      case 'score':
        opponentScore = Std.int(num(message.s));
        opponentCombo = Std.int(num(message.c));

      case 'finish':
        opponentFinished = true;
        opponentAborted = message.aborted == true;
        opponentScore = Std.int(num(message.s));

      default:
    }
  }

  function enqueue(event:RemoteEvent):Void
  {
    // Keep it ordered by time so draining can stop at the first event that isn't due yet.
    var index:Int = queue.length;
    while (index > 0 && queue[index - 1].time > event.time)
      index--;
    queue.insert(index, event);
  }

  /**
   * Apply the remote events that are due.
   * @param songPosition Our current song position in ms.
   * @return How many events were applied.
   */
  public function drain(songPosition:Float, handlers:RemoteHandlers):Int
  {
    var applied:Int = 0;

    while (queue.length > 0)
    {
      var next:RemoteEvent = queue[0];
      // Not due yet, unless it's absurdly far ahead (clocks out of step).
      if (next.time > songPosition && next.time - songPosition <= MAX_HOLD_MS) break;

      queue.shift();
      applied++;

      switch (next.kind)
      {
        case Press:
          handlers.press(next.dir);
        case Release:
          handlers.release(next.dir);
        case Hit:
          handlers.hit(next.dir, next.noteTime, next.rating);
        case Miss:
          handlers.miss(next.dir, next.noteTime);
      }
    }

    return applied;
  }

  /**
   * How many remote events are waiting for their time to come.
   */
  public var pendingEvents(get, never):Int;

  function get_pendingEvents():Int return queue.length;

  // ---------------------------------------------------------------------------------------------------------------

  static function dirOf(message:Dynamic):Int
  {
    var d:Int = Std.int(num(message.d));
    return d < 0 ? 0 : (d > 3 ? 3 : d); // Never trust the network: only 4 lanes exist.
  }

  static function num(value:Dynamic):Float
  {
    if (Std.isOfType(value, Float) || Std.isOfType(value, Int))
    {
      var f:Float = value;
      return Math.isNaN(f) || !Math.isFinite(f) ? 0 : f;
    }
    return 0;
  }

  static inline function round(value:Float):Float
  {
    return Math.round(value * 10) / 10;
  }
}
