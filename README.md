<div align='center'><img src="docs/readme_images/FNF_logo.png" width="800">

<h2>Friday Night Funkin' is a rhythm game. Built using HaxeFlixel for <a href="https://ldjam.com/events/ludum-dare/47">Ludum Dare 47.</a></h2>

This game was made with love to Newgrounds and its community. Extra love to Tom Fulp.

</div>

- [Playable web demo on Newgrounds!](https://www.newgrounds.com/portal/view/770371)
- [Demo download builds for Windows, Mac, and Linux from Itch.io!](https://ninja-muffin24.itch.io/funkin)
- [Download Android builds from Google Play!](https://play.google.com/store/apps/details?id=me.funkin.fnf)
- [Download iOS builds from the App Store!](https://apps.apple.com/app/id6740428530)

<div align='center'>
<table>
  <tr>
    <td><img src="docs/readme_images/Title_Card.gif" alt="Title Screen" width="350"/></td>
    <td><img src="docs/readme_images/Menu.png" alt="Main Menu" width="350"/></td>
  </tr>
</table>
</div>

# Getting Started

**PLEASE USE THE LINKS ABOVE IF YOU JUST WANT TO PLAY THE GAME**

To learn how to install the necessary dependencies and compile the game from source, please follow our [Compiling Guide](/docs/COMPILING.md).

# Contributing

Check out our [Contributing Guide](/docs/CONTRIBUTING.md) to learn how you can actively contribute to the development of Friday Night Funkin'!

# Modding

Feel free to start learning to mod the game by reading our [documentation](https://funkincrew.github.io/funkin-modding-docs/) and guide to modding.

# Credits and Special Thanks

Full credits can be found in-game, or in the `credits.json` file which is located [here](https://github.com/FunkinCrew/funkin.assets/blob/main/exclude/data/credits.json).

## Programming
- [ninjamuffin99](https://twitter.com/ninja_muffin99) - Lead Programmer
- [EliteMasterEric](https://twitter.com/EliteMasterEric) - Programmer
- [MtH](https://twitter.com/emmnyaa) - Charting and Additional Programming
- [GeoKureli](https://twitter.com/Geokureli/) - Additional Programming
- [ZackDroid](https://x.com/ZackDroidCoder) - Lead Mobile Programmer
- [MAJigsaw77](https://github.com/MAJigsaw77) - Mobile Programmer
- [Karim-Akra](https://x.com/KarimAkra_0) - Mobile Programmer
- [Sector_5](https://github.com/sector-a) - Mobile Programmer
- [Luckydog7](https://github.com/luckydog7) - Mobile Programmer
- Our contributors on GitHub

## Art / Animation / UI
- [PhantomArcade3K](https://twitter.com/phantomarcade3k) - Artist and Animator
- [Evilsk8r](https://twitter.com/evilsk8r) - Art
- [Moawling](https://twitter.com/moawko) - Week 6 Pixel Art
- [IvanAlmighty](https://twitter.com/IvanA1mighty) - Misc UI Design

## Music
- [Kawaisprite](https://twitter.com/kawaisprite) - Musician
- [BassetFilms](https://twitter.com/Bassetfilms) - Music for "Monster", Additional Character Design

## Special Thanks
- [Tom Fulp](https://twitter.com/tomfulp) - For being a great guy and for Newgrounds
- [JohnnyUtah](https://twitter.com/JohnnyUtahNG/) - Voice of Tankman
- [L0Litsmonica](https://twitter.com/L0Litsmonica) - Voice of Mommy Mearest

## How to Play Online?

On a PC, you need to open a terminal and copy this command:

git clone https://github.com/panchitomanriquezxdxd/Funkin-0.8.7.git

cd Funkin-0.8.7

git checkout feature/online-android-v2

node tools/online-server/server.js 7777

And that's it.

[P.S.: This only works with the Wi-Fi IP address when you're online.]

## ¿Cómo jugar charts de Psych Engine?

V-Slice sigue funcionando igual; los charts de Psych se **añaden** a los de V-Slice.

1. Junto a la carpeta `mods` crea la carpeta `psych-songs` y, dentro, una carpeta por canción:

   ```
   psych-songs/Mi Cancion/mi-cancion.json        (chart, cualquier versión de Psych)
   psych-songs/Mi Cancion/mi-cancion-hard.json   (otras dificultades: -easy, -hard)
   psych-songs/Mi Cancion/Inst.ogg
   psych-songs/Mi Cancion/Voices.ogg             (opcional)
   ```

2. Abre el juego. Las canciones se convierten solas (a un mod generado en `mods/psych-songs`) y aparecen en **Freeplay** y en el lobby del **modo online**. Solo se reconvierten si cambias algo.

Los eventos y tipos de nota que V-Slice no tiene se ignoran (se tocan como notas normales). También puedes importar un chart suelto desde el Chart Editor.
