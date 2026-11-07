package funkin.online;

import flixel.FlxSprite;
import flixel.group.FlxGroup;
import flixel.text.FlxInputText;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import funkin.audio.FunkinSound;
import funkin.data.character.CharacterData.CharacterDataParser;
import funkin.data.song.SongRegistry;
import funkin.online.OnlineClient;
import funkin.online.OnlineProtocol;
import funkin.play.song.Song;
import funkin.ui.MusicBeatState;
import funkin.ui.mainmenu.MainMenuState;
import funkin.ui.transition.LoadingState;
import funkin.util.Constants;

private enum Screen
{
  Connect;
  Lobby;
}

/**
 * The online lobby. Two screens:
 * - Connect: type your name and the relay server, then create a room or join one with its code.
 * - Lobby: pick your character; the host picks the song and starts the match.
 *
 * Built only from text and plain rectangles so it works on any screen size and with touch.
 */
class OnlineMenuState extends MusicBeatState
{
  final client:OnlineClient = OnlineClient.instance;

  var screen:Screen = Connect;

  // Connect screen.
  var connectGroup:FlxGroup = new FlxGroup();
  var nameInput:FlxInputText;
  var serverInput:FlxInputText;
  var codeInput:FlxInputText;
  var createButton:OnlineButton;
  var joinButton:OnlineButton;

  // Lobby screen.
  var lobbyGroup:FlxGroup = new FlxGroup();
  var roomText:FlxText;
  var youText:FlxText;
  var opponentText:FlxText;
  var songText:FlxText;
  var latencyText:FlxText;
  var charButton:OnlineButton;
  var songButton:OnlineButton;
  var difficultyButton:OnlineButton;
  var startButton:OnlineButton;

  // Shared.
  var statusText:FlxText;
  var menuBackButton:OnlineButton;
  var busy:Bool = false;
  var launching:Bool = false;

  // Selection data.
  var characterIds:Array<String> = [];
  var songIds:Array<String> = [];
  var songIndex:Int = 0;
  var difficulties:Array<String> = [];
  var difficultyIndex:Int = 0;

  override public function create():Void
  {
    super.create();

    FlxG.mouse.visible = true;
    FlxG.keys.enabled = true;

    var bg:FlxSprite = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, 0xFF10131F);
    bg.scrollFactor.set(0, 0);
    add(bg);

    loadChoices();

    buildHeader();
    buildConnectScreen();
    buildLobbyScreen();

    add(connectGroup);
    add(lobbyGroup);

    statusText = makeText(0, FlxG.height - 120, FlxG.width, '', 26, FlxColor.YELLOW);
    statusText.alignment = CENTER;
    add(statusText);

    menuBackButton = new OnlineButton(30, FlxG.height - 80, 180, 56, 'BACK', onBack, 28);
    add(menuBackButton);

    // Coming back from a match: the connection and room are still there.
    if (client.state == Connected && client.inRoom) showScreen(Lobby);
    else
      showScreen(Connect);

    if (!OnlineClient.isSupported())
    {
      setStatus('Online play is not available in this build.', true);
      createButton.enabled = false;
      joinButton.enabled = false;
    }
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Building
  // -----------------------------------------------------------------------------------------------------------------

  function loadChoices():Void
  {
    characterIds = CharacterDataParser.listCharacterIds();
    characterIds.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
    if (characterIds.length == 0) characterIds = ['bf'];

    songIds = [];
    var allSongs:Array<String> = SongRegistry.instance.listEntryIds();
    allSongs.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
    for (id in allSongs)
    {
      var song:Null<Song> = SongRegistry.instance.fetchEntry(id);
      if (song != null && song.listDifficulties(Constants.DEFAULT_VARIATION).length > 0) songIds.push(id);
    }
    if (songIds.length > 0) refreshDifficulties();

    // Make sure the saved character still exists.
    if (!characterIds.contains(OnlineSettings.character)) OnlineSettings.character = characterIds.contains('bf') ? 'bf' : characterIds[0];
  }

  function buildHeader():Void
  {
    var title:FlxText = makeText(0, 24, FlxG.width, 'ONLINE', 64, FlxColor.WHITE);
    title.alignment = CENTER;
    add(title);
  }

  function buildConnectScreen():Void
  {
    var x:Float = FlxG.width / 2 - 320;

    connectGroup.add(makeText(x, 130, 640, 'YOUR NAME', 24, 0xFF9FB4FF));
    nameInput = makeInput(x, 162, 640, OnlineSettings.playerName, OnlineProtocol.MAX_NAME_LENGTH);
    connectGroup.add(nameInput);

    connectGroup.add(makeText(x, 236, 640, 'SERVER (host or host:port)', 24, 0xFF9FB4FF));
    serverInput = makeInput(x, 268, 640, OnlineSettings.serverAddress, 80);
    connectGroup.add(serverInput);

    createButton = new OnlineButton(x, 350, 640, 64, 'CREATE ROOM', onCreateRoom);
    connectGroup.add(createButton);

    connectGroup.add(makeText(x, 440, 640, 'OR JOIN WITH A ROOM CODE', 24, 0xFF9FB4FF));
    codeInput = makeInput(x, 472, 300, '', OnlineProtocol.ROOM_CODE_LENGTH + 2);
    codeInput.filterMode = ALPHANUMERIC;
    connectGroup.add(codeInput);

    joinButton = new OnlineButton(x + 330, 472, 310, 48, 'JOIN ROOM', onJoinRoom, 28);
    connectGroup.add(joinButton);
  }

  function buildLobbyScreen():Void
  {
    var x:Float = FlxG.width / 2 - 360;

    roomText = makeText(0, 110, FlxG.width, '', 48, FlxColor.WHITE);
    roomText.alignment = CENTER;
    lobbyGroup.add(roomText);

    var shareText:FlxText = makeText(0, 172, FlxG.width, 'Share this code with your friend', 22, 0xFF9FB4FF);
    shareText.alignment = CENTER;
    lobbyGroup.add(shareText);

    youText = makeText(x, 230, 720, '', 28, FlxColor.WHITE);
    lobbyGroup.add(youText);

    charButton = new OnlineButton(x, 268, 720, 56, '', onNextCharacter, 26);
    lobbyGroup.add(charButton);

    opponentText = makeText(x, 350, 720, '', 28, FlxColor.WHITE);
    lobbyGroup.add(opponentText);

    songText = makeText(x, 396, 720, '', 24, 0xFF9FB4FF);
    lobbyGroup.add(songText);

    songButton = new OnlineButton(x, 436, 720, 52, '', onNextSong, 24);
    lobbyGroup.add(songButton);

    difficultyButton = new OnlineButton(x, 496, 720, 52, '', onNextDifficulty, 24);
    lobbyGroup.add(difficultyButton);

    startButton = new OnlineButton(x, 560, 720, 64, 'START', onStart);
    lobbyGroup.add(startButton);

    latencyText = makeText(FlxG.width - 330, FlxG.height - 70, 300, '', 20, 0xFF9FB4FF);
    latencyText.alignment = RIGHT;
    lobbyGroup.add(latencyText);
  }

  function makeText(x:Float, y:Float, width:Float, text:String, size:Int, color:FlxColor):FlxText
  {
    var result:FlxText = new FlxText(x, y, width, text, size);
    result.setFormat(Paths.font('vcr.ttf'), size, color, LEFT, OUTLINE, FlxColor.BLACK);
    result.scrollFactor.set(0, 0);
    return result;
  }

  function makeInput(x:Float, y:Float, width:Float, text:String, maxLength:Int):FlxInputText
  {
    var input:FlxInputText = new FlxInputText(x, y, Std.int(width), text, 28, FlxColor.WHITE, 0xFF222A44);
    input.caretColor = FlxColor.WHITE;
    input.fieldBorderColor = 0xFF4C6FFF;
    input.fieldBorderThickness = 2;
    input.maxChars = maxLength;
    input.scrollFactor.set(0, 0);
    return input;
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Screens
  // -----------------------------------------------------------------------------------------------------------------

  function showScreen(next:Screen):Void
  {
    screen = next;
    connectGroup.visible = connectGroup.active = (next == Connect);
    lobbyGroup.visible = lobbyGroup.active = (next == Lobby);
    busy = false;
    refreshUi();
  }

  function refreshUi():Void
  {
    createButton.enabled = !busy && OnlineClient.isSupported();
    joinButton.enabled = !busy && OnlineClient.isSupported();

    if (screen != Lobby) return;

    var host:Bool = client.isHost;
    var opponent:Null<PlayerProfile> = client.peer;

    roomText.text = client.roomCode ?? '-----';
    youText.text = 'YOU: ${client.profile.name}' + (host ? ' (host)' : '');
    charButton.setText('< ${client.profile.char} >   tap to change character');

    opponentText.text = opponent == null ? 'Waiting for a friend to join...' : 'OPPONENT: ${opponent.name}  as  ${opponent.char}';

    var songId:String = songIds.length > 0 ? songIds[songIndex] : '(no songs)';
    var difficulty:String = difficulties.length > 0 ? difficulties[difficultyIndex] : '-';

    songText.text = host ? 'SONG (you choose)' : 'SONG (the host chooses)';
    songButton.setText(host ? '< $songId >' : songId);
    difficultyButton.setText(host ? '< $difficulty >' : difficulty);
    songButton.enabled = host && songIds.length > 0;
    difficultyButton.enabled = host && difficulties.length > 1;

    startButton.visible = host;
    startButton.enabled = host && opponent != null && songIds.length > 0 && !launching;
    startButton.setText(opponent == null ? 'WAITING FOR PLAYER' : 'START');
  }

  function setStatus(text:String, isError:Bool = false):Void
  {
    statusText.text = text;
    statusText.color = isError ? 0xFFFF6B6B : FlxColor.YELLOW;
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------------------------------------------------

  function applyProfileFromInputs():Void
  {
    OnlineSettings.playerName = nameInput.text;
    OnlineSettings.serverAddress = serverInput.text;
    client.setProfile(OnlineSettings.playerName, OnlineSettings.character);
  }

  function onCreateRoom():Void
  {
    if (busy) return;
    applyProfileFromInputs();
    busy = true;
    setStatus('Connecting to ${serverInput.text}...');
    refreshUi();
    client.createRoom(serverInput.text);
  }

  function onJoinRoom():Void
  {
    if (busy) return;
    applyProfileFromInputs();
    busy = true;
    setStatus('Connecting to ${serverInput.text}...');
    refreshUi();
    client.joinRoom(serverInput.text, codeInput.text);
  }

  function onBack():Void
  {
    if (launching) return;

    if (screen == Lobby)
    {
      client.leaveRoom();
      client.disconnect();
      showScreen(Connect);
      setStatus('');
    }
    else
    {
      FunkinSound.playOnce(Paths.sound('cancelMenu'));
      FlxG.switchState(() -> new MainMenuState());
    }
  }

  function onNextCharacter():Void
  {
    var index:Int = characterIds.indexOf(client.profile.char);
    var next:String = characterIds[(index + 1) % characterIds.length];
    OnlineSettings.character = next;
    client.setProfile(client.profile.name, next);
    refreshUi();
  }

  function onNextSong():Void
  {
    if (songIds.length == 0 || !client.isHost) return;
    songIndex = (songIndex + 1) % songIds.length;
    refreshDifficulties();
    syncSelection();
    refreshUi();
  }

  function onNextDifficulty():Void
  {
    if (difficulties.length == 0 || !client.isHost) return;
    difficultyIndex = (difficultyIndex + 1) % difficulties.length;
    syncSelection();
    refreshUi();
  }

  function refreshDifficulties():Void
  {
    var song:Null<Song> = SongRegistry.instance.fetchEntry(songIds[songIndex]);
    difficulties = song?.listDifficulties(Constants.DEFAULT_VARIATION) ?? [];
    // Prefer the default difficulty when there is one.
    var preferred:Int = difficulties.indexOf(Constants.DEFAULT_DIFFICULTY);
    difficultyIndex = preferred >= 0 ? preferred : 0;
  }

  /**
   * Tell the guest what the host currently has selected.
   */
  function syncSelection():Void
  {
    if (!client.isHost || client.peer == null || songIds.length == 0) return;
    client.send({
      t: 'ready',
      phase: 'song',
      song: songIds[songIndex],
      diff: difficulties.length > 0 ? difficulties[difficultyIndex] : Constants.DEFAULT_DIFFICULTY
    });
  }

  function onStart():Void
  {
    var opponent:Null<PlayerProfile> = client.peer;
    if (!client.isHost || opponent == null || songIds.length == 0 || launching) return;

    var songId:String = songIds[songIndex];
    var difficulty:String = difficulties.length > 0 ? difficulties[difficultyIndex] : Constants.DEFAULT_DIFFICULTY;

    // The start message is the single source of truth for who plays as what.
    client.send({
      t: 'start',
      song: songId,
      diff: difficulty,
      variation: Constants.DEFAULT_VARIATION,
      hc: client.profile.char,
      gc: opponent.char,
      hn: client.profile.name,
      gn: opponent.name
    });

    launch(songId, difficulty, Constants.DEFAULT_VARIATION, client.profile.char, opponent.char, opponent.name);
  }

  function onRemoteStart(message:Dynamic):Void
  {
    var songId:String = Std.string(message.song);
    var difficulty:String = Std.string(message.diff);
    var variation:String = Std.isOfType(message.variation, String) ? message.variation : Constants.DEFAULT_VARIATION;

    var song:Null<Song> = SongRegistry.instance.fetchEntry(songId);
    if (song == null || !song.hasDifficulty(difficulty, variation))
    {
      setStatus('You don\'t have the song "$songId" ($difficulty).', true);
      client.send({t: 'ready', phase: 'cannot_start', reason: 'missing song $songId'});
      return;
    }

    launch(songId, difficulty, variation, Std.string(message.gc), Std.string(message.hc), Std.string(message.hn));
  }

  function launch(songId:String, difficulty:String, variation:String, ownChar:String, opponentChar:String, opponentName:String):Void
  {
    var song:Null<Song> = SongRegistry.instance.fetchEntry(songId);
    if (song == null)
    {
      setStatus('Could not load the song "$songId".', true);
      return;
    }

    launching = true;
    OnlineMatch.begin(client, songId, difficulty, variation, ownChar, opponentChar, opponentName);
    setStatus('Loading...');
    refreshUi();

    LoadingState.loadPlayState({
      targetSong: song,
      targetDifficulty: difficulty,
      targetVariation: variation,
      practiceMode: true, // Nobody dies in a versus match, and it keeps the match out of the saved scores.
      minimalMode: false,
      botPlayMode: false,
      mirrored: false
    }, true);
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Update
  // -----------------------------------------------------------------------------------------------------------------

  var syncTimer:Float = 0;

  override public function update(elapsed:Float):Void
  {
    super.update(elapsed);

    for (event in client.poll())
    {
      handleEvent(event);
    }

    if (screen == Lobby)
    {
      latencyText.text = client.peerRttMs >= 0 ? 'ping: ${Std.int(client.peerRttMs)} ms' : '';

      // Keep the guest's view fresh even if a message got lost around a reconnect.
      syncTimer += elapsed;
      if (syncTimer >= 3.0)
      {
        syncTimer = 0;
        syncSelection();
      }
      refreshUi();
    }

    var typing:Bool = nameInput.hasFocus || serverInput.hasFocus || codeInput.hasFocus;
    if (!typing && !launching && controls.BACK)
    {
      onBack();
    }
  }

  function handleEvent(event:OnlineEvent):Void
  {
    switch (event)
    {
      case Connected:
        setStatus('Connected.');

      case RoomCreated(code):
        showScreen(Lobby);
        setStatus('Room $code created. Waiting for a friend...');

      case RoomJoined(code, host):
        showScreen(Lobby);
        setStatus('Joined $code, hosted by ${host.name}.');

      case PeerJoined(peer):
        setStatus('${peer.name} joined!');
        syncSelection();

      case PeerLeft:
        setStatus(client.isHost ? 'Your friend left.' : 'The host left, you are the host now.');
        launching = false;

      case PeerProfile(_):

      case LeftRoom:

      case Error(code, message):
        busy = false;
        setStatus(message, true);

      case Disconnected(reason):
        launching = false;
        OnlineMatch.end();
        showScreen(Connect);
        setStatus(reason, true);

      case Message(message):
        handleMessage(message);
    }
  }

  function handleMessage(message:Dynamic):Void
  {
    switch (Std.string(message.t))
    {
      case 'start':
        if (!client.isHost) onRemoteStart(message);

      case 'ready':
        switch (Std.string(message.phase))
        {
          case 'song':
            if (!client.isHost)
            {
              var index:Int = songIds.indexOf(Std.string(message.song));
              if (index >= 0)
              {
                songIndex = index;
                refreshDifficulties();
                var diffIndex:Int = difficulties.indexOf(Std.string(message.diff));
                if (diffIndex >= 0) difficultyIndex = diffIndex;
              }
              else
              {
                // Show it anyway so the player knows why starting will fail.
                songText.text = 'SONG (the host chooses): ${message.song} - you don\'t have it';
              }
            }
          case 'cannot_start':
            launching = false;
            OnlineMatch.end();
            setStatus('Your friend can\'t start: ${message.reason}', true);
          default:
        }

      default:
    }
  }

  override public function destroy():Void
  {
    // A match that is about to load keeps using the connection, so don't close it here.
    super.destroy();
  }
}
