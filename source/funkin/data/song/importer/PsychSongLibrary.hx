package funkin.data.song.importer;

#if sys
import funkin.data.song.SongData.SongChartData;
import funkin.data.song.SongData.SongMetadata;
import funkin.data.song.importer.PsychEngineImporter.PsychImportResult;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * Lets Psych Engine songs be played as they are, next to the V-Slice ones (nothing of V-Slice is replaced).
 *
 * Put each song in its own folder inside `psych-songs/` (next to the `mods` folder):
 *
 *     psych-songs/My Song/my-song.json         (chart, any Psych version; `my-song-hard.json` etc. for other difficulties)
 *     psych-songs/My Song/Inst.ogg
 *     psych-songs/My Song/Voices.ogg           (optional)
 *
 * On startup the songs are converted into a generated mod (`mods/psych-songs`), which the game loads like any other mod,
 * so they show up in Freeplay and in the online lobby. Songs that haven't changed are not converted again.
 */
class PsychSongLibrary
{
  public static inline var SOURCE_FOLDER:String = 'psych-songs';
  static inline var MOD_ID:String = 'psych-songs';
  static inline var STAMP_FILE:String = '.psych-stamp';

  /**
   * Convert every song in `psych-songs/` into the generated mod inside `modRoot`. Never throws.
   * @return The ids of the songs that are available.
   */
  public static function sync(modRoot:String):Array<String>
  {
    var ids:Array<String> = [];
    try
    {
      if (!FileSystem.exists(SOURCE_FOLDER) || !FileSystem.isDirectory(SOURCE_FOLDER)) return ids;

      var modDir:String = Path.join([modRoot, MOD_ID]);
      var stamp:String = buildStamp();
      var stampPath:String = Path.join([modDir, STAMP_FILE]);

      var folders:Array<String> = [for (f in FileSystem.readDirectory(SOURCE_FOLDER)) if (FileSystem.isDirectory(Path.join([SOURCE_FOLDER, f]))) f];
      folders.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
      for (folder in folders)
        ids.push(songIdFor(folder));

      if (FileSystem.exists(stampPath) && File.getContent(stampPath) == stamp)
      {
        trace('[PsychSongLibrary] ${ids.length} Psych song(s), already converted.');
        return ids;
      }

      FileSystem.createDirectory(modRoot);
      createDirectories(modDir);

      var converted:Array<String> = [];
      for (folder in folders)
      {
        var id:String = songIdFor(folder);
        if (convertSong(Path.join([SOURCE_FOLDER, folder]), id, modDir)) converted.push(id);
      }

      File.saveContent(Path.join([modDir, '_polymod_meta.json']), haxe.Json.stringify({
        title: 'Psych Engine songs',
        description: 'Generated from the psych-songs folder. Do not edit: it is rebuilt when the folder changes.',
        author: 'Generated',
        api_version: funkin.modding.PolymodHandler.API_VERSION,
        mod_version: '1.0.0',
        license: 'Unknown'
      }, null, '  '));
      writeLevel(modDir, converted);
      File.saveContent(stampPath, stamp);
      trace('[PsychSongLibrary] Converted ${converted.length} Psych song(s).');
      return converted;
    }
    catch (e:Dynamic)
    {
      trace('[PsychSongLibrary] Could not prepare the Psych songs: $e');
      return ids;
    }
  }

  /**
   * A V-Slice song id for a folder name: lowercase, words joined by dashes.
   */
  public static function songIdFor(folder:String):String
  {
    var id:String = ~/[^a-z0-9]+/g.replace(folder.toLowerCase(), '-');
    id = ~/^-+|-+$/g.replace(id, '');
    return id == '' ? 'psych-song' : id;
  }

  static function convertSong(dir:String, id:String, modDir:String):Bool
  {
    var base:Null<PsychImportResult> = null;
    var all:Array<PsychImportResult> = [];

    var files:Array<String> = FileSystem.readDirectory(dir);
    files.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
    for (file in files)
    {
      var lower:String = file.toLowerCase();
      if (!StringTools.endsWith(lower, '.json') || lower == 'events.json') continue;
      var result:Null<PsychImportResult> = PsychEngineImporter.importChart(File.getContent(Path.join([dir, file])), file);
      if (result == null) continue;
      all.push(result);
      if (base == null || result.difficulty == 'normal') base = result;
    }

    if (base == null)
    {
      trace('[PsychSongLibrary] No Psych chart found in "$dir".');
      return false;
    }

    var metadata:SongMetadata = base.metadata;
    var chart:SongChartData = base.chart;
    metadata.playData.difficulties = [];

    for (result in all)
    {
      if (metadata.playData.difficulties.contains(result.difficulty)) continue;
      metadata.playData.difficulties.push(result.difficulty);
      chart.notes.set(result.difficulty, result.chart.notes.get(result.difficulty) ?? []);
      chart.scrollSpeed.set(result.difficulty, result.chart.scrollSpeed.get(result.difficulty) ?? 1.0);
    }
    var order:Array<String> = ['easy', 'normal', 'hard', 'erect', 'nightmare'];
    metadata.playData.difficulties.sort((a, b) ->
    {
      var ia:Int = order.indexOf(a);
      var ib:Int = order.indexOf(b);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    });
    // Events are shared by every difficulty in V-Slice, so the ones of the base chart are kept.

    var dataDir:String = Path.join([modDir, 'data', 'songs', id]);
    createDirectories(dataDir);
    File.saveContent(Path.join([dataDir, '$id-metadata.json']), metadata.serialize());
    File.saveContent(Path.join([dataDir, '$id-chart.json']), chart.serialize());

    var audioDir:String = Path.join([modDir, 'songs', id]);
    createDirectories(audioDir);
    for (file in files)
    {
      var lower:String = file.toLowerCase();
      if (StringTools.endsWith(lower, '.ogg') || StringTools.endsWith(lower, '.mp3') || StringTools.endsWith(lower, '.wav'))
      {
        File.copy(Path.join([dir, file]), Path.join([audioDir, file]));
      }
    }
    return true;
  }

  static function writeLevel(modDir:String, songIds:Array<String>):Void
  {
    var dir:String = Path.join([modDir, 'data', 'levels']);
    createDirectories(dir);
    File.saveContent(Path.join([dir, 'psychsongs.json']), haxe.Json.stringify({
      version: '1.0.0',
      name: 'PSYCH ENGINE',
      titleAsset: 'storymenu/titles/tutorial',
      props: [],
      background: '#4B3F72',
      visible: false,
      songs: songIds
    }, null, '  '));
  }

  /**
   * Describes the source folder (names, sizes, dates) so that unchanged songs are skipped.
   */
  static function buildStamp():String
  {
    var parts:Array<String> = ['v1'];
    var stack:Array<String> = [SOURCE_FOLDER];
    while (stack.length > 0)
    {
      var dir:String = stack.pop();
      var entries:Array<String> = FileSystem.readDirectory(dir);
      entries.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
      for (entry in entries)
      {
        var path:String = Path.join([dir, entry]);
        var stat:sys.FileStat = FileSystem.stat(path);
        if (FileSystem.isDirectory(path)) stack.push(path);
        else
          parts.push('$path:${stat.size}:${Std.int(stat.mtime.getTime() / 1000)}');
      }
    }
    return parts.join('|');
  }

  static function createDirectories(path:String):Void
  {
    var current:String = '';
    for (part in path.split('/'))
    {
      current = current == '' ? (part == '' ? '/' : part) : Path.join([current, part]);
      if (current != '/' && !FileSystem.exists(current)) FileSystem.createDirectory(current);
    }
  }
}
#end
