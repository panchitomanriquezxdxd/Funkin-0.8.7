package funkin.online;

import funkin.online.OnlineProtocol;
import haxe.Timer;
#if FEATURE_ONLINE
import haxe.io.Bytes;
import haxe.io.Eof;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;
#end

/**
 * Things that happened on the connection, handed out by `OnlineClient.poll()`.
 */
enum OnlineEvent
{
  /**
   * The TCP connection to the relay is up.
   */
  Connected;

  /**
   * The connection is gone (closed by the server, network drop, or a failed attempt).
   */
  Disconnected(reason:String);

  /**
   * We created a room.
   */
  RoomCreated(code:String);

  /**
   * We joined someone's room.
   */
  RoomJoined(code:String, host:PlayerProfile);

  /**
   * Somebody joined our room.
   */
  PeerJoined(peer:PlayerProfile);

  /**
   * The other player left. If we were the guest we are the host now.
   */
  PeerLeft;

  /**
   * The other player changed their name/character.
   */
  PeerProfile(peer:PlayerProfile);

  /**
   * We left the room (we're still connected).
   */
  LeftRoom;

  /**
   * The relay refused something. `code` is machine readable, `message` is for the player.
   */
  Error(code:String, message:String);

  /**
   * A gameplay/lobby message from the other player (`ready`, `start`, `press`, `hit`...).
   * The sender's slot is in the `from` field.
   */
  Message(message:Dynamic);
}

enum ConnectionState
{
  Disconnected;
  Connecting;
  Connected;
}

#if FEATURE_ONLINE
private enum RawEvent
{
  SocketReady(socket:Socket);
  Line(line:String);
  Closed(reason:String);
}

private typedef QueuedEvent =
{
  var generation:Int;
  var event:RawEvent;
}
#end

/**
 * Connection to the relay server (`tools/online-server`).
 *
 * All the blocking socket work happens in background threads, the game thread only ever calls the
 * non-blocking `poll()`, `send()` and friends. Call `poll()` once per frame and react to what it returns.
 *
 * Typical use:
 * ```haxe
 * var client = OnlineClient.instance;
 * client.createRoom('relay.example.com:7777');
 * // every frame:
 * for (event in client.poll()) switch (event) { case RoomCreated(code): ...; default: }
 * ```
 */
class OnlineClient
{
  public static var instance(get, never):OnlineClient;
  static var _instance:Null<OnlineClient>;

  static function get_instance():OnlineClient
  {
    if (_instance == null) _instance = new OnlineClient();
    return _instance;
  }

  /**
   * Seconds to wait for the TCP connection before giving up.
   */
  public static inline var CONNECT_TIMEOUT_SECONDS:Float = 8.0;

  /**
   * Seconds between keep-alive pings to the relay (it drops connections that are silent for a minute).
   */
  public static inline var PING_INTERVAL_SECONDS:Float = 15.0;

  /**
   * Seconds between latency probes to the other player.
   */
  public static inline var RTT_INTERVAL_SECONDS:Float = 4.0;

  public var state(default, null):ConnectionState = Disconnected;

  /**
   * The code of the room we are in, or `null`.
   */
  public var roomCode(default, null):Null<String> = null;

  /**
   * Our slot in the room: `0` is the host, `1` the guest, `-1` when not in a room.
   */
  public var slot(default, null):Int = -1;

  public var isHost(get, never):Bool;
  public var inRoom(get, never):Bool;

  /**
   * The other player, if there is one.
   */
  public var peer(default, null):Null<PlayerProfile> = null;

  /**
   * Our own info, sent when creating/joining a room and whenever it changes.
   */
  public var profile(default, null):PlayerProfile = {name: 'Player', char: 'bf'};

  /**
   * Round trip time to the relay, in ms. `-1` until measured.
   */
  public var serverRttMs(default, null):Float = -1;

  /**
   * Round trip time to the other player (through the relay), in ms. `-1` until measured.
   */
  public var peerRttMs(default, null):Float = -1;

  /**
   * The server we last connected to, as typed by the player.
   */
  public var serverAddress(default, null):String = '';

  var generation:Int = 0;
  var pendingRequest:Null<Dynamic> = null;
  var connectStartedAt:Float = 0;
  var lastPingAt:Float = 0;
  var lastRttAt:Float = 0;
  var pingCounter:Int = 0;
  var sentPings:Map<Int, Float> = [];
  var sentRtts:Map<Int, Float> = [];
  var localEvents:Array<OnlineEvent> = [];

  #if FEATURE_ONLINE
  var socket:Null<Socket> = null;
  var inbox:Deque<QueuedEvent> = new Deque();
  var outbox:Null<Deque<Null<String>>> = null;
  #end

  public function new() {}

  function get_isHost():Bool return slot == 0;

  function get_inRoom():Bool return roomCode != null;

  /**
   * Whether online play exists in this build.
   */
  public static inline function isSupported():Bool
  {
    #if FEATURE_ONLINE
    return true;
    #else
    return false;
    #end
  }

  /**
   * Set our name and character. If we're in a room the other player is told.
   */
  public function setProfile(name:String, char:String):Void
  {
    profile = {name: OnlineProtocol.sanitizeName(name), char: char};
    if (inRoom) send({t: 'profile', name: profile.name, char: profile.char});
  }

  /**
   * Connect to a relay and create a room. Wait for `RoomCreated`.
   * @param address What the player typed: `host` or `host:port`.
   */
  public function createRoom(address:String):Void
  {
    request(address, {t: 'create', v: OnlineProtocol.VERSION, name: profile.name, char: profile.char});
  }

  /**
   * Connect to a relay and join a room. Wait for `RoomJoined`.
   */
  public function joinRoom(address:String, code:String):Void
  {
    var normalized:String = OnlineProtocol.normalizeRoomCode(code);
    if (!OnlineProtocol.isValidRoomCode(normalized))
    {
      localEvents.push(Error('bad_code', 'A room code has ${OnlineProtocol.ROOM_CODE_LENGTH} letters/numbers.'));
      return;
    }
    request(address, {t: 'join', v: OnlineProtocol.VERSION, code: normalized, name: profile.name, char: profile.char});
  }

  /**
   * Leave the room but stay connected to the relay.
   */
  public function leaveRoom():Void
  {
    if (state == Connected && inRoom) send({t: 'leave'});
  }

  /**
   * Drop everything: the room and the connection.
   */
  public function disconnect():Void
  {
    closeConnection();
    pendingRequest = null;
    state = Disconnected;
    clearRoom();
  }

  /**
   * Queue a message for the other player (or the relay). Never blocks.
   * Messages sent while not connected are dropped.
   */
  public function send(message:Dynamic):Void
  {
    #if FEATURE_ONLINE
    if (state != Connected || outbox == null) return;
    outbox.add(OnlineProtocol.encode(message));
    #end
  }

  /**
   * Collect everything that happened since the last call. Call once per frame from the game thread.
   */
  public function poll():Array<OnlineEvent>
  {
    var result:Array<OnlineEvent> = localEvents;
    localEvents = [];

    #if FEATURE_ONLINE
    var queued:Null<QueuedEvent>;
    while ((queued = inbox.pop(false)) != null)
    {
      // Anything from a connection we already abandoned is stale.
      if (queued.generation != generation) continue;
      handleRaw(queued.event, result);
    }

    var now:Float = Timer.stamp();

    if (state == Connecting && now - connectStartedAt > CONNECT_TIMEOUT_SECONDS)
    {
      closeConnection();
      state = Disconnected;
      pendingRequest = null;
      result.push(Disconnected('Could not reach the server (timed out).'));
    }

    if (state == Connected)
    {
      if (now - lastPingAt >= PING_INTERVAL_SECONDS)
      {
        lastPingAt = now;
        var n:Int = ++pingCounter;
        sentPings.set(n, now);
        send({t: 'ping', n: n});
      }

      if (inRoom && peer != null && now - lastRttAt >= RTT_INTERVAL_SECONDS)
      {
        lastRttAt = now;
        var n:Int = ++pingCounter;
        sentRtts.set(n, now);
        send({t: 'rtt', n: n});
      }
    }
    #end

    return result;
  }

  function request(address:String, message:Dynamic):Void
  {
    var parsed:Null<ServerAddress> = OnlineProtocol.parseServerAddress(address);
    if (parsed == null)
    {
      localEvents.push(Error('bad_address', 'That server address is not valid. Use host or host:port.'));
      return;
    }

    #if FEATURE_ONLINE
    // Start from a clean slate if there was an old connection.
    disconnect();

    serverAddress = address;
    pendingRequest = message;
    state = Connecting;
    connectStartedAt = Timer.stamp();

    var myGeneration:Int = ++generation;
    var queue:Deque<QueuedEvent> = inbox;
    var host:String = parsed.host;
    var port:Int = parsed.port;

    Thread.create(function()
    {
      var newSocket:Socket = new Socket();
      try
      {
        newSocket.connect(new Host(host), port);
        newSocket.setFastSend(true); // Tiny realtime messages: don't wait to batch them (TCP_NODELAY).
      }
      catch (e:Dynamic)
      {
        try
        {
          newSocket.close();
        }
        catch (_:Dynamic) {}
        queue.add({generation: myGeneration, event: Closed('Could not connect to $host:$port.')});
        return;
      }

      queue.add({generation: myGeneration, event: SocketReady(newSocket)});
      readLoop(newSocket, myGeneration, queue);
    });
    #else
    localEvents.push(Disconnected('Online play is not available in this build.'));
    #end
  }

  #if FEATURE_ONLINE
  /**
   * Runs on the reader thread: blocks on the socket and turns what arrives into lines.
   */
  static function readLoop(socket:Socket, myGeneration:Int, queue:Deque<QueuedEvent>):Void
  {
    var buffer:Bytes = Bytes.alloc(2048);
    var lines:LineBuffer = new LineBuffer(4096);
    var reason:String = 'The connection was closed.';

    try
    {
      while (true)
      {
        var count:Int = socket.input.readBytes(buffer, 0, buffer.length);
        if (count <= 0) break;

        for (line in lines.push(buffer, count))
        {
          queue.add({generation: myGeneration, event: Line(line)});
        }

        if (lines.overflowed)
        {
          reason = 'The server sent invalid data.';
          break;
        }
      }
    }
    catch (e:Eof) {}
    catch (e:Dynamic) {}

    try
    {
      socket.close();
    }
    catch (_:Dynamic) {}

    queue.add({generation: myGeneration, event: Closed(reason)});
  }

  /**
   * Runs on the writer thread: sends queued lines until it gets the `null` stop signal.
   */
  static function writeLoop(socket:Socket, queue:Deque<Null<String>>):Void
  {
    while (true)
    {
      var line:Null<String> = queue.pop(true);
      if (line == null) break;

      try
      {
        socket.output.writeString(line);
        socket.output.flush();
      }
      catch (e:Dynamic)
      {
        // The reader notices the dead connection and reports it.
        break;
      }
    }
  }

  function handleRaw(raw:RawEvent, result:Array<OnlineEvent>):Void
  {
    switch (raw)
    {
      case SocketReady(readySocket):
        socket = readySocket;
        var queue:Deque<Null<String>> = new Deque();
        outbox = queue;
        Thread.create(function() writeLoop(readySocket, queue));

        state = Connected;
        lastPingAt = Timer.stamp();
        lastRttAt = lastPingAt;
        result.push(Connected);

        if (pendingRequest != null)
        {
          var message:Dynamic = pendingRequest;
          pendingRequest = null;
          send(message);
        }

      case Closed(reason):
        closeConnection();
        state = Disconnected;
        pendingRequest = null;
        clearRoom();
        result.push(Disconnected(reason));

      case Line(line):
        var message:Null<Dynamic> = OnlineProtocol.decode(line);
        if (message != null) handleMessage(message, result);
    }
  }
  #end

  function handleMessage(message:Dynamic, result:Array<OnlineEvent>):Void
  {
    var type:String = message.t;

    switch (type)
    {
      case 'created':
        roomCode = message.code;
        slot = message.you;
        peer = null;
        result.push(RoomCreated(message.code));

      case 'joined':
        roomCode = message.code;
        slot = message.you;
        peer = readProfile(message.peer);
        result.push(RoomJoined(message.code, peer ?? {name: 'Host', char: 'bf'}));

      case 'peer_joined':
        peer = readProfile(message.peer);
        peerRttMs = -1;
        result.push(PeerJoined(peer ?? {name: 'Player', char: 'bf'}));

      case 'peer_left':
        peer = null;
        peerRttMs = -1;
        if (Std.isOfType(message.you, Int)) slot = message.you;
        result.push(PeerLeft);

      case 'left':
        clearRoom();
        result.push(LeftRoom);

      case 'error':
        result.push(Error(Std.string(message.code), Std.string(message.msg)));

      case 'pong':
        var sentAt:Null<Float> = sentPings.get(message.n);
        if (sentAt != null)
        {
          sentPings.remove(message.n);
          serverRttMs = smooth(serverRttMs, (Timer.stamp() - sentAt) * 1000);
        }

      case 'rtt':
        // Answer right away, the other side measures how long that takes.
        send({t: 'rtt_ack', n: message.n});

      case 'rtt_ack':
        var sentAt:Null<Float> = sentRtts.get(message.n);
        if (sentAt != null)
        {
          sentRtts.remove(message.n);
          peerRttMs = smooth(peerRttMs, (Timer.stamp() - sentAt) * 1000);
        }

      case 'profile':
        var updated:Null<PlayerProfile> = readProfile(message);
        if (updated != null)
        {
          peer = updated;
          result.push(PeerProfile(updated));
        }

      default:
        result.push(Message(message));
    }
  }

  static function smooth(previous:Float, sample:Float):Float
  {
    return previous < 0 ? sample : previous * 0.7 + sample * 0.3;
  }

  static function readProfile(raw:Null<Dynamic>):Null<PlayerProfile>
  {
    if (raw == null || !Reflect.isObject(raw)) return null;
    var name:Dynamic = Reflect.field(raw, 'name');
    var char:Dynamic = Reflect.field(raw, 'char');
    return {
      name: Std.isOfType(name, String) ? name : 'Player',
      char: Std.isOfType(char, String) ? char : 'bf',
    };
  }

  function clearRoom():Void
  {
    roomCode = null;
    slot = -1;
    peer = null;
    peerRttMs = -1;
    sentRtts = [];
  }

  function closeConnection():Void
  {
    generation++; // Everything the old threads report from now on is ignored.

    #if FEATURE_ONLINE
    if (outbox != null)
    {
      outbox.add(null); // Stop the writer thread.
      outbox = null;
    }

    if (socket != null)
    {
      try
      {
        socket.close(); // Unblocks the reader thread.
      }
      catch (_:Dynamic) {}
      socket = null;
    }
    #end

    sentPings = [];
    serverRttMs = -1;
  }
}
